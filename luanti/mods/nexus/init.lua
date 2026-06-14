-- nexus/init.lua
-- Cross-server zone travel for Luanti.
--
-- This mod provides the Lua-side API for the nexus transfer system.
-- It runs on each galaxy server behind mt-multiserver-proxy and
-- communicates with the nexus_proxy Go plugin via HTTP.
--
-- Game code interacts with this mod through the `nexus` global table:
--   nexus.travel(player, destination)
--   nexus.on_arrive(function(player, origin) ... end)
--   nexus.state.register_handler("my_mod", { capture = fn, restore = fn })

-- Create the nexus global table
nexus = {}

-- Load submodules
local modpath = core.get_modpath(core.get_current_modname())
dofile(modpath .. "/serialize.lua")
-- =============================================================================
-- Configuration
-- =============================================================================

local PROXY_URL = core.settings:get("nexus.proxy_url") or "http://127.0.0.1:8080"
local GALAXY_NAME = core.settings:get("nexus.galaxy_name") or "alpha"
local GALAXY_LABEL = core.settings:get("nexus.galaxy_label") or GALAXY_NAME
local GALAXY_TIER = tonumber(core.settings:get("nexus.galaxy_tier") or "1")
local WORLD_NAME = core.settings:get("nexus.world_name") or GALAXY_NAME
local ALLOW_SAME_WORLD = core.settings:get_bool("nexus.allow_same_world_travel", true)
local HTTP_TIMEOUT = tonumber(core.settings:get("nexus.timeout") or "10")

-- Shared API secret — must match the proxy plugin's NEXUS_API_SECRET.
-- Sent as a Bearer token on every request so the proxy can verify we're
-- a trusted galaxy server, not an arbitrary caller.
local API_TOKEN = core.settings:get("nexus.api_secret") or ""

-- HTTP API handle (requires secure.http_mods = nexus in minetest.conf)
local http = core.request_http_api()
if not http then
    core.log("error", "[nexus] HTTP API not available! " ..
        "Add 'secure.http_mods = nexus' to minetest.conf")
end

-- Authenticated HTTP request — injects the shared API secret into every
-- request so the proxy plugin can verify the caller is a trusted galaxy server.
local function nexus_http(opts, callback)
    opts.extra_headers = opts.extra_headers or {}
    table.insert(opts.extra_headers, "Authorization: Bearer " .. API_TOKEN)
    return http.fetch(opts, callback)
end

-- Expose internals needed by submodules (gates.lua, etc.)
nexus._http = nexus_http
nexus._config = {
    proxy_url = PROXY_URL,
    galaxy_name = GALAXY_NAME,
    galaxy_label = GALAXY_LABEL,
    galaxy_tier = GALAXY_TIER,
    world_name = WORLD_NAME,
    allow_same_world = ALLOW_SAME_WORLD,
    http_timeout = HTTP_TIMEOUT,
}

-- Track players who just arrived (anti-loop / restore-in-progress flag)
local pending_arrival = {}

-- Track players whose departure is in progress (inventory frozen to prevent dupes)
local departing = {}

-- =============================================================================
-- Anti-Cheat: Inventory Freeze During Transfer
-- =============================================================================
-- When a player triggers travel, their inventory is captured server-side and
-- sent to the proxy. But the hop is async — there's a window between capture
-- and the actual server switch. During that window, a player could drop items
-- into the world, then arrive on the destination with the captured copy —
-- duplicating items.
--
-- To prevent this, we freeze ALL inventory interactions the instant departure
-- begins. The freeze is lifted if the transfer fails (player keeps their
-- items) or naturally cleared when the player leaves on a successful hop.
--
-- Uses core.register_allow_player_inventory_action — a built-in engine
-- callback available in ALL Luanti games (not devtest-specific).

-- The freeze covers BOTH sides of a transfer:
--   departing[pname]  — set during capture until hop/failure (prevents dropping
--                        items on the origin after they've been captured)
--   pending_arrival[pname] — set on join until restore completes (prevents
--                        dropping the destination's saved inventory before
--                        the nexus restore overwrites it)
core.register_allow_player_inventory_action(function(player, action, inventory, info)
	local pname = player:get_player_name()
	if departing[pname] or pending_arrival[pname] then
		local phase = departing[pname] and "departure" or "arrival"
		core.log("action", "[nexus] BLOCKED " .. action .. " action for " .. pname .. " (" .. phase .. " freeze)")
		return 0  -- Block all moves, puts, takes, drops, and crafts
	end
end)

-- =============================================================================
-- Travel Lock: Loading Screen + Player Freeze
-- =============================================================================
-- During transfer, the player is fully locked: a fullscreen loading screen
-- blocks all interaction, physics are frozen (no walking), and inventory is
-- frozen (no drops/moves). This eliminates ALL race conditions — the player
-- never has control during the vulnerable capture→restore window.
--
-- The loading screen also fixes client-side inventory desync: since the player
-- can't send inventory actions during the window, there are no rejected
-- predictions to confuse the hotbar rendering. When the screen clears,
-- the client shows a clean, server-authoritative inventory.

local saved_physics = {}

-- Show a fullscreen loading screen during wormhole travel.
local function show_travel_screen(pname, message)
	local formspec = table.concat({
		"formspec_version[4]",
		"size[12,7]",
		"position[0.5,0.46]",
		"anchor[0.5,0.5]",
		"no_prepend[]",
		"bgcolor[#0A0A2A;false]",  -- dark void / wormhole backdrop
		"hypertext[1,2.5;10,2.5;msg;<global halign=center><style color=#FFFFFF size=24>" ..
			core.formspec_escape(message) ..
			"</style><br><br><style color=#888888 size=16>Stand by for materialization...</style>]",
	})
	core.show_formspec(pname, "nexus:travel", formspec)
end

local function close_travel_screen(pname)
	core.show_formspec(pname, "nexus:travel", "")
end

-- Fully lock a player: freeze movement, show loading screen.
-- Call this at the start of departure AND on arrival.
local function lock_player(player, message)
	local pname = player:get_player_name()
	-- Save current physics before overriding (games may set custom values)
	saved_physics[pname] = player:get_physics_override()
	player:set_physics_override({
		speed = 0,
		jump = 0,
		gravity = 0,
	})
	show_travel_screen(pname, message)
end

-- Unlock a player: restore physics, remove loading screen.
local function unlock_player(player)
	local pname = player:get_player_name()
	local saved = saved_physics[pname]
	if saved then
		player:set_physics_override(saved)
		saved_physics[pname] = nil
	else
		player:set_physics_override({ speed = 1, jump = 1, gravity = 1 })
	end
	close_travel_screen(pname)
end

-- Prevent the player from closing the travel screen with ESC during transfer.
-- If they try, immediately re-show it.
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname == "nexus:travel" and fields.quit then
		local pname = player:get_player_name()
		if departing[pname] or pending_arrival[pname] then
			show_travel_screen(pname, "Transfer in progress...")
			return true  -- suppress further processing
		end
	end
end)

-- =============================================================================
-- State Handler Registry
-- =============================================================================

-- State handlers are functions that capture custom game state on departure
-- and restore it on arrival. Core handlers (inventory, player_meta) are built-in.
-- Third-party mods register their own handlers to carry custom state.

nexus.state = nexus.state or {}
nexus.state._handlers = nexus.state._handlers or {}

-- Register a custom state handler.
-- @param name    string  Unique handler name (e.g. "progress", "reputation")
-- @param handler table   { capture = fn(player) -> table, restore = fn(player, data) }
function nexus.state.register_handler(name, handler)
    assert(type(name) == "string", "handler name must be a string")
    assert(type(handler) == "table", "handler must be a table")
    assert(type(handler.capture) == "function", "handler.capture must be a function")
    assert(type(handler.restore) == "function", "handler.restore must be a function")
    nexus.state._handlers[name] = handler
    core.log("action", "[nexus] state handler registered: " .. name)
end

-- Capture all registered state for a player.
-- Returns the full state table ready for transfer.
function nexus.state.capture(player)
    local pname = player:get_player_name()

    -- Core state
    local core_data = nexus.serialize.capture_core(player)
    local inventory = nexus.serialize.capture_inventory(player)
    local player_meta = nexus.serialize.capture_player_meta(player)

    -- Extension state from registered handlers
    local extensions = {}
    for name, handler in pairs(nexus.state._handlers) do
        local ok, data = pcall(handler.capture, player)
        if ok then
            extensions[name] = data
        else
            core.log("error", "[nexus] state handler '" .. name ..
                "' capture failed: " .. tostring(data))
        end
    end

    return {
        version = 1,
        format = "nexus-state",
        player = pname,
        origin = GALAXY_NAME,
        timestamp = os.time(),
        core = core_data,
        inventory = inventory,
        player_meta = player_meta,
        extensions = extensions,
    }
end

-- Restore all registered state for a player from a state table.
function nexus.state.restore(player, state)
    local pname = player:get_player_name()

    -- Restore in order: core → inventory → meta → extensions
    if state.core then
        nexus.serialize.restore_core(player, state.core)
    end

    if state.inventory then
        nexus.serialize.restore_inventory(player, state.inventory)
    end

    if state.player_meta then
        nexus.serialize.restore_player_meta(player, state.player_meta)
    end

    -- Extension state (guard against nil from JSON null)
    if state.extensions then
        for name, data in pairs(state.extensions) do
            local handler = nexus.state._handlers[name]
            if handler then
                local ok, err = pcall(handler.restore, player, data)
                if not ok then
                    core.log("error", "[nexus] state handler '" .. name ..
                        "' restore failed: " .. tostring(err))
                end
            end
        end
    end
end

-- =============================================================================
-- Callback Registry
-- =============================================================================

nexus._callbacks = nexus._callbacks or {
    on_depart = {},
    on_arrive = {},
    on_travel_failed = {},
}

-- Register a callback to fire before a player departs this galaxy.
-- Return false from the callback to cancel the travel.
function nexus.on_depart(handler)
    table.insert(nexus._callbacks.on_depart, handler)
end

-- Register a callback to fire after a player arrives and state is restored.
function nexus.on_arrive(handler)
    table.insert(nexus._callbacks.on_arrive, handler)
end

-- Register a callback for travel failures.
function nexus.on_travel_failed(handler)
    table.insert(nexus._callbacks.on_travel_failed, handler)
end

local function fire_callbacks(event, ...)
    for _, handler in ipairs(nexus._callbacks[event]) do
        local ok, err = pcall(handler, ...)
        if not ok then
            core.log("error", "[nexus] callback " .. event .. " failed: " .. tostring(err))
        end
    end
end

-- =============================================================================
-- Travel API
-- =============================================================================

-- Initiate travel for a player to another galaxy.
-- @param player      ObjectRef|string  Player to transfer
-- @param destination string             Galaxy/server name to travel to
-- @param opts?       table              { arrival_gate = "beta:g1" }
-- @return boolean success
-- @return string?  error message
function nexus.travel(player, destination, opts)
    opts = opts or {}

    -- Resolve player object
    if type(player) == "string" then
        player = core.get_player_by_name(player)
    end
    if not player or not player:is_player() then
        return false, "Invalid player"
    end

    local pname = player:get_player_name()

    -- Prevent double-departure: if the player is already mid-transfer, refuse.
    -- Without this, a second failed departure would clear the freeze flag
    -- from the first in-progress transfer.
    if departing[pname] then
        return false, "Transfer already in progress"
    end

    if not http then
        return false, "HTTP API not available (check secure.http_mods)"
    end

    -- Fire on_depart callbacks — allow cancellation
    for _, handler in ipairs(nexus._callbacks.on_depart) do
        local ok, result = pcall(handler, player, destination)
        if ok and result == false then
            return false, "Travel cancelled by callback"
        end
    end

    -- Freeze inventory to prevent duplication during the async transfer window.
    -- This blocks drops, moves, and chest deposits between capture and hop.
    -- Also show the loading screen + freeze movement — full lock.
    departing[pname] = true
    lock_player(player, "Entering wormhole to " .. destination .. "...")

    -- Capture state
    core.log("action", "[nexus] capturing state for " .. pname .. " → " .. destination)
    local state = nexus.state.capture(player)

    -- Attach gate travel info if provided
    if opts.arrival_gate then
        state.gate_travel = {
            departure_gate = opts.departure_gate,
            arrival_gate = opts.arrival_gate,
        }
    end

    -- POST to proxy
    local request_id = pname .. "_" .. os.time()
    local payload = core.write_json({
        player = pname,
        destination = destination,
        request_id = request_id,
        state = state,
    })

    core.log("action", "[nexus] sending departure request for " .. pname ..
        " (" .. #payload .. " bytes)")

    nexus_http({
        url = PROXY_URL .. "/nexus/depart",
        method = "POST",
        data = payload,
        timeout = HTTP_TIMEOUT,
        extra_headers = { "Content-Type: application/json" },
    }, function(result)
        if result.code == 200 then
            local resp = core.parse_json(result.data)
            if resp and resp.ok then
                core.log("action", "[nexus] departure confirmed for " .. pname ..
                    " — hop in progress")

                -- Safety timeout: if the player is still on this server after
                -- 15 seconds, the hop failed silently (proxy crash, dest down).
                -- Unlock them so they're not stuck on the loading screen forever.
                core.after(15, function()
                    if departing[pname] then
                        departing[pname] = nil
                        local p = core.get_player_by_name(pname)
                        if p then
                            unlock_player(p)
                            core.chat_send_player(pname,
                                "[nexus] Transfer timed out — hop may have failed. Try again.")
                            core.log("warning", "[nexus] departure timeout for " ..
                                pname .. " — auto-unlocking")
                        end
                    end
                end)
            else
                departing[pname] = nil
                unlock_player(player)  -- Remove lock on failure
                local msg = (resp and resp.message) or "Unknown response"
                core.log("error", "[nexus] departure failed for " .. pname .. ": " .. msg)
                core.chat_send_player(pname, "Travel failed: " .. msg)
                fire_callbacks("on_travel_failed", player, msg, "depart")
            end
        else
            departing[pname] = nil
            unlock_player(player)  -- Remove lock on failure
            local msg = "Proxy returned HTTP " .. result.code
            core.log("error", "[nexus] departure HTTP error for " .. pname .. ": " .. msg)
            core.chat_send_player(pname, "Travel failed: " .. msg)
            fire_callbacks("on_travel_failed", player, msg, "depart")
        end
    end)

    return true
end

-- =============================================================================
-- Cleanup: Clear transfer state when a player leaves
-- =============================================================================

-- When a player leaves (either by hopping to another server or by disconnecting),
-- clear their departure and arrival tracking. On a successful hop, the departing
-- flag doesn't need clearing (the player is gone), but we clear it anyway for
-- safety — if the same player reconnects, we don't want a stale freeze.
core.register_on_leaveplayer(function(player)
    local pname = player:get_player_name()
    departing[pname] = nil
    pending_arrival[pname] = nil
    saved_physics[pname] = nil
end)

-- =============================================================================
-- Arrival Handler
-- =============================================================================

-- When a player joins this server, check if they have pending state from a transfer.
-- This fires both on initial connect AND after a hop from another server.
core.register_on_joinplayer(function(player, last_login)
    local pname = player:get_player_name()

    if not http then return end
    if pending_arrival[pname] then return end -- already processing

    -- Freeze inventory immediately — we don't yet know if this is a transfer
    -- arrival or a normal login. There's a window between join and the nexus
    -- state restore (0.5s + HTTP roundtrip) during which the destination's
    -- saved inventory is loaded. Without freezing, a player could drop those
    -- items, then the restore overwrites the inventory with the captured copy —
    -- duplicating items. The freeze is lifted once state is checked/restored.
    pending_arrival[pname] = true

    -- Fully lock the player: loading screen + frozen movement + inventory freeze.
    -- This runs BEFORE we even know if there's pending state. For normal logins,
    -- the lock is removed as soon as the GET returns 404 (~0.5s). For transfers,
    -- it stays until restore completes. This ensures the player never sees a
    -- desynced inventory — everything happens behind the loading screen.
    lock_player(player, "Materializing in " .. GALAXY_LABEL .. "...")

    -- Safety timeout: if the state check/restore takes too long (proxy down,
    -- HTTP hung), unlock the player anyway so they're not stuck forever.
    core.after(30, function()
        if pending_arrival[pname] then
            pending_arrival[pname] = nil
            local p = core.get_player_by_name(pname)
            if p then
                unlock_player(p)
                core.log("warning", "[nexus] arrival timeout for " .. pname ..
                    " — auto-unlocking")
            end
        end
    end)

    -- Give the hop a moment to settle, then check for pending state
    core.after(0.5, function()
        if not core.get_player_by_name(pname) then return end -- player left already

        nexus_http({
            url = PROXY_URL .. "/nexus/state/" .. pname,
            method = "GET",
            timeout = HTTP_TIMEOUT,
        }, function(result)
            if result.code ~= 200 then
                -- No pending state — this is a normal login, not a transfer
                pending_arrival[pname] = nil
                unlock_player(player)  -- Remove lock for normal login
                return
            end

            local resp = core.parse_json(result.data)
            if not resp or not resp.ok or not resp.state then
                core.log("warning", "[nexus] arrival state malformed for " .. pname)
                pending_arrival[pname] = nil
                unlock_player(player)  -- Remove lock on malformed state
                return
            end

            local state = resp.state
            core.log("action", "[nexus] restoring state for " .. pname ..
                " (from " .. (state.origin or "unknown") .. ")")

            -- Restore the player's state
            nexus.state.restore(player, state)
            pending_arrival[pname] = nil
            unlock_player(player)  -- Restore complete — remove lock + loading screen

            -- Handle gate arrival positioning
            if state.gate_travel and state.gate_travel.arrival_gate then
                nexus._handle_gate_arrival(player, state.gate_travel.arrival_gate)
            end

            -- Confirm restore — delete state from proxy
            nexus_http({
                url = PROXY_URL .. "/nexus/state/" .. pname,
                method = "DELETE",
                timeout = HTTP_TIMEOUT,
            }, function(del_result)
                if del_result.code == 200 then
                    core.log("action", "[nexus] state confirmed and cleared for " .. pname)
                else
                    core.log("warning", "[nexus] state delete failed for " .. pname ..
                        " (HTTP " .. del_result.code .. ") — will expire via TTL")
                end
            end)

            -- Fire arrival callbacks
            fire_callbacks("on_arrive", player, state.origin or "unknown", state)

            core.chat_send_player(pname, "Arrival confirmed. Welcome to " .. GALAXY_LABEL .. ".")
        end)
    end)
end)

-- =============================================================================
-- Galaxy Registration (at server startup)
-- =============================================================================

-- Register this galaxy with the proxy on startup
core.register_on_mods_loaded(function()
    if not http then return end

    local payload = core.write_json({
        galaxy = {
            name = GALAXY_NAME,
            label = GALAXY_LABEL,
            tier = GALAXY_TIER,
        },
    })

    -- Small delay to let the proxy plugin's HTTP server be ready
    core.after(2, function()
        nexus_http({
            url = PROXY_URL .. "/nexus/register",
            method = "POST",
            data = payload,
            timeout = HTTP_TIMEOUT,
            extra_headers = { "Content-Type: application/json" },
        }, function(result)
            if result.code == 200 then
                core.log("action", "[nexus] galaxy '" .. GALAXY_NAME ..
                    "' registered with proxy")
            else
                core.log("warning", "[nexus] galaxy registration failed (HTTP " ..
                    result.code .. ") — is the proxy running?")
            end
        end)
    end)
end)

-- =============================================================================
-- Test Chat Command
-- =============================================================================

-- /travel <destination> — triggers the full nexus transfer pipeline.
-- This goes through state capture → HTTP depart → proxy hop → state restore,
-- unlike the proxy's raw >server command which only moves the connection.
core.register_chatcommand("travel", {
	params = "<destination>",
	description = "Travel to another galaxy via the nexus transfer system (captures and restores state)",
	privs = {},
	func = function(name, param)
		local destination = param:trim()
		if destination == "" then
			return false, "Usage: /travel <destination> (e.g. /travel beta)"
		end

		-- Don't allow travel to the server we're already on
		if destination == GALAXY_NAME then
			return false, "You are already on " .. GALAXY_LABEL
		end

		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end

		core.chat_send_player(name, "[nexus] Initiating travel to '" .. destination .. "'...")
		local ok, err = nexus.travel(player, destination)
		if not ok then
			return false, "Travel failed: " .. (err or "unknown error")
		end

		return true, "Departure initiated — state captured, transferring..."
	end,
})

-- =============================================================================
-- Utility API
-- =============================================================================

-- Get the name of this server's galaxy.
function nexus.get_current_galaxy()
    return GALAXY_NAME
end

-- Check if a player is currently being transferred.
function nexus.is_in_transit(pname)
    return pending_arrival[pname] ~= nil or departing[pname] ~= nil
end

-- Placeholder for gate arrival positioning (implemented by gate system)
function nexus._handle_gate_arrival(player, arrival_gate)
    -- This will be expanded when the gate system is built.
    -- For now, just log it.
    core.log("action", "[nexus] gate arrival at " .. arrival_gate ..
        " (positioning not yet implemented)")
end

-- =============================================================================
-- Gate System (loaded last — needs nexus._http, nexus._config, nexus.travel)
-- =============================================================================

dofile(modpath .. "/gates.lua")

-- =============================================================================
-- Startup logging
-- =============================================================================

core.log("action", "[nexus] initialized — galaxy: " .. GALAXY_NAME ..
    " (" .. GALAXY_LABEL .. ", tier " .. GALAXY_TIER .. ")" ..
    " proxy: " .. PROXY_URL)
