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
local HTTP_TIMEOUT = tonumber(core.settings:get("nexus.timeout") or "10")

-- HTTP API handle (requires secure.http_mods = nexus in minetest.conf)
local http = core.request_http_api()
if not http then
    core.log("error", "[nexus] HTTP API not available! " ..
        "Add 'secure.http_mods = nexus' to minetest.conf")
end

-- Track players who just arrived (anti-loop / restore-in-progress flag)
local pending_arrival = {}

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

    -- Extension state
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

    http.fetch({
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
            else
                local msg = (resp and resp.message) or "Unknown response"
                core.log("error", "[nexus] departure failed for " .. pname .. ": " .. msg)
                core.chat_send_player(pname, "Travel failed: " .. msg)
                fire_callbacks("on_travel_failed", player, msg, "depart")
            end
        else
            local msg = "Proxy returned HTTP " .. result.code
            core.log("error", "[nexus] departure HTTP error for " .. pname .. ": " .. msg)
            core.chat_send_player(pname, "Travel failed: " .. msg)
            fire_callbacks("on_travel_failed", player, msg, "depart")
        end
    end)

    return true
end

-- =============================================================================
-- Arrival Handler
-- =============================================================================

-- When a player joins this server, check if they have pending state from a transfer.
-- This fires both on initial connect AND after a hop from another server.
core.register_on_joinplayer(function(player, last_login)
    local pname = player:get_player_name()

    if not http then return end
    if pending_arrival[pname] then return end -- already processing

    -- Give the hop a moment to settle, then check for pending state
    core.after(0.5, function()
        if not core.get_player_by_name(pname) then return end -- player left already

        http.fetch({
            url = PROXY_URL .. "/nexus/state/" .. pname,
            method = "GET",
            timeout = HTTP_TIMEOUT,
        }, function(result)
            if result.code ~= 200 then
                -- No pending state — this is a normal login, not a transfer
                return
            end

            local resp = core.parse_json(result.data)
            if not resp or not resp.ok or not resp.state then
                core.log("warning", "[nexus] arrival state malformed for " .. pname)
                return
            end

            local state = resp.state
            core.log("action", "[nexus] restoring state for " .. pname ..
                " (from " .. (state.origin or "unknown") .. ")")

            -- Restore the player's state
            nexus.state.restore(player, state)

            -- Handle gate arrival positioning
            if state.gate_travel and state.gate_travel.arrival_gate then
                nexus._handle_gate_arrival(player, state.gate_travel.arrival_gate)
            end

            -- Confirm restore — delete state from proxy
            http.fetch({
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
        http.fetch({
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
-- Utility API
-- =============================================================================

-- Get the name of this server's galaxy.
function nexus.get_current_galaxy()
    return GALAXY_NAME
end

-- Check if a player is currently being transferred.
function nexus.is_in_transit(pname)
    return pending_arrival[pname] ~= nil
end

-- Placeholder for gate arrival positioning (implemented by gate system)
function nexus._handle_gate_arrival(player, arrival_gate)
    -- This will be expanded when the gate system is built.
    -- For now, just log it.
    core.log("action", "[nexus] gate arrival at " .. arrival_gate ..
        " (positioning not yet implemented)")
end

-- =============================================================================
-- Startup logging
-- =============================================================================

core.log("action", "[nexus] initialized — galaxy: " .. GALAXY_NAME ..
    " (" .. GALAXY_LABEL .. ", tier " .. GALAXY_TIER .. ")" ..
    " proxy: " .. PROXY_URL)
