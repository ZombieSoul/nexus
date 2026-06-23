-- nexus/gates.lua
-- Gate-to-gate travel system.
--
-- Provides physical stargate blocks, gate registry interaction,
-- link establishment (dialing), walk-through travel triggers,
-- and arrival positioning at destination gates.
--
-- This module is loaded at the END of init.lua, so it has access to
-- nexus.travel, nexus._http, nexus._config, and all transfer state.

local http_fn = nexus._http
local cfg = nexus._config
local PROXY = cfg.proxy_url
local TIMEOUT = cfg.http_timeout
local GALAXY = cfg.galaxy_name
local WORLD = cfg.world_name or GALAXY
local ALLOW_SAME_WORLD = cfg.allow_same_world ~= false

-- Mod storage for gate persistence (survives server restart)
local storage = core.get_mod_storage()

-- Dial timing (per-symbol, per-tier). Controls how dramatic the dialing sequence is.
local DIAL_TIME = {
    same_world   = tonumber(core.settings:get("nexus.dial_time_same_world")) or 1.0,
    same_galaxy  = tonumber(core.settings:get("nexus.dial_time_same_galaxy")) or 1.5,
    cross_galaxy = tonumber(core.settings:get("nexus.dial_time_cross_galaxy")) or 2.0,
}

-- =============================================================================
-- Address Conversion Layer
-- =============================================================================
-- The ONLY place address strings are parsed or formatted.
-- Internal routing always uses structured route tables:
--   { galaxy = "milkyway", world = "earth", gate_id = "g10_20" }
-- Changing the address format later means changing ONLY these two functions.
-- Current format: "galaxy:world:gate_id" (e.g. "milkyway:earth:g10_20")

--- Parse an address string into a structured route.
--- @param addr string  e.g. "milkyway:earth:g10_20"
--- @return table? route  {galaxy=, world=, gate_id=} or nil if invalid
local function address_to_route(addr)
    if not addr then return nil end
    -- Try 3-part format: galaxy:world:gate_id
    local galaxy, world, gate_id = addr:match("^([^:]+):([^:]+):([^:]+)$")
    if galaxy then
        return { galaxy = galaxy, world = world, gate_id = gate_id }
    end
    -- Try legacy 2-part format: galaxy:gate_id (from before world decoupling)
    local old_galaxy, old_gid = addr:match("^([^:]+):([^:]+)$")
    if old_galaxy then
        return { galaxy = old_galaxy, world = old_galaxy, gate_id = old_gid }
    end
    return nil
end

--- Format a structured route into an address string.
--- @param route table  {galaxy=, world=, gate_id=}
--- @return string address
local function route_to_address(route)
    return route.galaxy .. ":" .. route.world .. ":" .. route.gate_id
end

--- Generate a unique gate_id from position (within this world).
local function make_gate_id(pos)
    return "g" .. math.abs(pos.x) .. "_" .. math.abs(pos.z)
end

--- Build the full route for a gate at the given position on this server.
local function make_route(pos)
    return {
        galaxy = GALAXY,
        world = WORLD,
        gate_id = make_gate_id(pos),
    }
end

-- Authenticated HTTP with Content-Type
local function gate_http(opts, callback)
    opts.extra_headers = opts.extra_headers or {}
    table.insert(opts.extra_headers, "Content-Type: application/json")
    return http_fn(opts, callback)
end

nexus.gate = {}

-- =============================================================================
-- Local Gate Tracking
-- =============================================================================

-- Gates that exist on THIS server: address → {pos = vector, node_pos = vector}
local local_gates = {}

-- Gates with active links on this server: address → true
local linked_gates = {}

-- Gates currently running their dialing sequence (prevents the poller
-- from placing the event horizon before the sequence completes)
local dialing_in_progress = {}

-- Track the tier of each active link (for upkeep cost calculation)
local gate_link_tiers = {}

-- Arrival cooldown to prevent immediate bounce-back (pname → expiry time)
local arrival_cooldown = {}

-- Generate a human-readable address from position.
local function make_address(pos)
    return route_to_address(make_route(pos))
end

-- =============================================================================
-- Gate Registry API (HTTP wrappers)
-- =============================================================================

--- Register a gate with the proxy.
function nexus.gate.register(gate_def, callback)
    local payload = core.write_json(gate_def)
    gate_http({
        url = PROXY .. "/nexus/gate",
        method = "POST",
        data = payload,
        timeout = TIMEOUT,
    }, function(result)
        if result.code == 200 then
            core.log("action", "[nexus] gate registered: " .. gate_def.address)
        else
            core.log("error", "[nexus] gate register failed for " ..
                gate_def.address .. ": HTTP " .. result.code)
        end
        if callback then callback(result.code == 200) end
    end)
end

--- Unregister a gate (destroyed).
function nexus.gate.unregister(address, callback)
    gate_http({
        url = PROXY .. "/nexus/gate/" .. address,
        method = "DELETE",
        timeout = TIMEOUT,
    }, function(result)
        if callback then callback(result.code == 200) end
    end)
end

--- Query a gate's info from the proxy.
function nexus.gate.get_info(address, callback)
    gate_http({
        url = PROXY .. "/nexus/gate/" .. address,
        method = "GET",
        timeout = TIMEOUT,
    }, function(result)
        if result.code ~= 200 then
            callback(nil)
            return
        end
        local resp = core.parse_json(result.data)
        callback(resp)
    end)
end

--- Establish a link (dial). Calls callback(true, link_info) or callback(false, error_msg).
function nexus.gate.establish_link(from_addr, to_addr, opened_by, callback)
    local payload = core.write_json({
        from = from_addr,
        to = to_addr,
        opened_by = opened_by,
        duration = 0,  -- 0 = manual close only (no auto-expire)
    })
    gate_http({
        url = PROXY .. "/nexus/link",
        method = "POST",
        data = payload,
        timeout = TIMEOUT,
    }, function(result)
        local resp = core.parse_json(result.data)
        if result.code == 200 and resp and resp.ok then
            callback(true, resp)
        else
            local msg = (resp and resp.message) or ("HTTP " .. result.code)
            callback(false, msg)
        end
    end)
end

--- Close a link.
function nexus.gate.close_link(gate_address, callback)
    gate_http({
        url = PROXY .. "/nexus/link/" .. gate_address,
        method = "DELETE",
        timeout = TIMEOUT,
    }, function(result)
        if callback then callback(result.code == 200) end
    end)
end

--- Query the active link for a gate.
function nexus.gate.get_link(gate_address, callback)
    gate_http({
        url = PROXY .. "/nexus/link/" .. gate_address,
        method = "GET",
        timeout = TIMEOUT,
    }, function(result)
        if result.code ~= 200 then
            callback(nil)
            return
        end
        local resp = core.parse_json(result.data)
        callback(resp)
    end)
end

-- =============================================================================
-- Gate Travel
-- =============================================================================

--- Travel a player through a linked gate to the destination.
function nexus.gate.travel_player(player, gate_address)
    local pname = player:get_player_name()

    -- Don't trigger if already in transit
    if nexus.is_in_transit(pname) then return end
    -- Don't trigger during arrival cooldown (prevents bounce-back)
    -- Use core.get_us_time() (real-time microseconds) — os.clock() is CPU
    -- time and barely advances on an idle server, making cooldowns permanent.
    local now = core.get_us_time() / 1000000
    if arrival_cooldown[pname] and now < arrival_cooldown[pname] then
        return
    end

    -- Set immediate cooldown to prevent re-trigger during the async
    -- HTTP call (the real departing flag isn't set until nexus.travel runs)
    arrival_cooldown[pname] = now + 5.0

    nexus.gate.get_link(gate_address, function(link)
        if not link or not link.linked then
            return  -- no active link
        end

        core.log("action", "[nexus] " .. pname .. " entering gate " ..
            gate_address .. " → " .. link.remote_address)

        -- Resolve the remote route from the address
        local remote = address_to_route(link.remote_address)
        local remote_world = (remote and remote.world) or link.remote_world
        local remote_galaxy = (remote and remote.galaxy) or link.remote_galaxy

        -- Power check: determine the tier and verify the gate can afford it.
        -- If nexus.power has no provider (or require_power=false), this
        -- always passes — gates are free.
        local tier, tier_label = nexus.power.tier_for(
            GALAXY, WORLD, remote_galaxy or GALAXY, remote_world or WORLD)
        local can_afford, perr = nexus.power.check(gate_address, tier)
        if not can_afford then
            core.chat_send_player(pname, "[nexus] " .. perr)
            core.log("action", "[nexus] " .. pname ..
                " travel blocked: insufficient power (" .. tier_label .. ")")
            return
        end

        if remote_world == WORLD then
            -- SAME WORLD: instant local teleport (if allowed)
            -- Player stays on this server, just moves to the dest gate.
            if not ALLOW_SAME_WORLD then
                core.chat_send_player(pname, "[nexus] Same-world gate travel is disabled.")
                return
            end

            -- Consume power at dial time now, not walk-through
            nexus.gate.get_info(link.remote_address, function(info)
                if not info or not info.gate then
                    core.chat_send_player(pname, "[nexus] Destination gate lost.")
                    return
                end
                local g = info.gate
                local pos = g.position or {}
                local offset = g.arrival_offset or {x = 0, y = 1, z = 0}
                local arrival_pos = {
                    x = (pos.x or 0) + (offset.x or 0),
                    y = (pos.y or 0) + (offset.y or 0),
                    z = (pos.z or 0) + (offset.z or 0),
                }
                player:set_pos(arrival_pos)
                if g.facing then
                    player:set_look_horizontal(math.rad(g.facing))
                end
                player:set_velocity({x = 0, y = 0, z = 0})
                arrival_cooldown[pname] = (core.get_us_time() / 1000000) + 3.0
                core.log("action", "[nexus] " .. pname ..
                    " teleported locally to " .. link.remote_address)
            end)
        else
            -- CROSS WORLD: proxy hop + state sync (same galaxy = interstellar,
            -- different galaxy = intergalactic — mechanism is the same,
            -- power cost differentiation comes with the energy system)

            -- Consume power at dial time now, not walk-through
            nexus.travel(player, remote_world or link.remote_galaxy, {
                arrival_gate = link.remote_address,
                departure_gate = gate_address,
            })
        end
    end)
end

-- =============================================================================
-- Arrival Positioning
-- =============================================================================

-- Override the placeholder from init.lua — position the player at the
-- destination gate's arrival point with correct facing.
nexus._handle_gate_arrival = function(player, arrival_gate)
    local pname = player:get_player_name()

    -- Set arrival cooldown so they don't immediately bounce back
    arrival_cooldown[pname] = (core.get_us_time() / 1000000) + 3.0

    nexus.gate.get_info(arrival_gate, function(info)
        if not info or not info.gate then
            core.chat_send_player(pname,
                "[nexus] Destination gate '" .. arrival_gate ..
                "' not found. Spawning at world origin.")
            core.log("warning", "[nexus] arrival gate " .. arrival_gate ..
                " not found — emergency spawn for " .. pname)
            return
        end

        local g = info.gate
        local pos = g.position or {}
        local offset = g.arrival_offset or {x = 0, y = 1, z = 0}
        local arrival_pos = {
            x = (pos.x or 0) + (offset.x or 0),
            y = (pos.y or 0) + (offset.y or 0),
            z = (pos.z or 0) + (offset.z or 0),
        }

        -- Teleport player to the arrival point
        player:set_pos(arrival_pos)

        -- Set facing to match gate orientation
        if g.facing then
            player:set_look_horizontal(math.rad(g.facing))
        end

        -- Zero velocity to prevent fall damage
        player:set_velocity({x = 0, y = 0, z = 0})

        core.log("action", "[nexus] " .. pname .. " arrived at gate " ..
            arrival_gate .. " (" .. math.floor(arrival_pos.x) .. "," ..
            math.floor(arrival_pos.y) .. "," .. math.floor(arrival_pos.z) .. ")")
    end)
end

-- =============================================================================
-- Gate Block
-- =============================================================================

-- The gate base is the master block. When placed, it registers with the proxy.
-- When destroyed, it unregisters. Right-click shows the dial formspec.

local GATE_NODE = "nexus:gate_base"
local HORIZON_NODE = "nexus:event_horizon"
local SPAN_NODE = "nexus:gate_span"

-- =============================================================================
-- Hexagonal Gate Geometry
-- =============================================================================
-- The gate is a HEXAGONAL ring of 6 keystones. The base block is the
-- controller at the bottom. Each keystone lights up with the color of the
-- symbol being dialed — the color sequence IS the address.
--
-- Layout (relative to base block at origin, facing north / -Z):
--
--          K1                y+5   top vertex
--       K6    K2             y+4   upper sides
--       [portal] [portal]    y+3   event horizon fills here
--       [portal]             y+2   event horizon
--       K5    K3             y+2   lower sides
--          K4                y+1   bottom vertex
--          BASE              y+0   controller

-- 7 Keystones (one per dial symbol position — cross-galaxy needs all 7)
local KEYSTONE_OFFSETS = {
    {-2, 1, 0},   -- K1 lower-left
    {2,  1, 0},   -- K2 lower-right
    {-3, 3, 0},   -- K3 mid-left
    {3,  3, 0},   -- K4 mid-right
    {-2, 5, 0},   -- K5 upper-left
    {2,  5, 0},   -- K6 upper-right
    {0,  6, 0},   -- K7 top center
}

-- Span blocks fill ALL non-keystone, non-portal positions to form a solid ring
local SPAN_OFFSETS = {
    {-1, 0, 0}, {1, 0, 0},              -- y+0: O C O
    {-3, 2, 0}, {3, 2, 0},              -- y+2: O ... O
    {-3, 4, 0}, {3, 4, 0},              -- y+4: O ... O
    {-1, 6, 0}, {1, 6, 0},              -- y+6: O X O (top: span, K7 keystone, span)
}

-- All frame blocks
local ALL_FRAME_OFFSETS = {}
for _, off in ipairs(KEYSTONE_OFFSETS) do ALL_FRAME_OFFSETS[#ALL_FRAME_OFFSETS+1] = off end
for _, off in ipairs(SPAN_OFFSETS) do ALL_FRAME_OFFSETS[#ALL_FRAME_OFFSETS+1] = off end

-- Portal opening offsets (event horizon fills the interior)
local PORTAL_OFFSETS = {
    {-1, 1, 0}, {0, 1, 0}, {1, 1, 0},                          -- y+1: 3 air
    {-2, 2, 0}, {-1, 2, 0}, {0, 2, 0}, {1, 2, 0}, {2, 2, 0},  -- y+2: 5 air
    {-2, 3, 0}, {-1, 3, 0}, {0, 3, 0}, {1, 3, 0}, {2, 3, 0},  -- y+3: 5 air
    {-2, 4, 0}, {-1, 4, 0}, {0, 4, 0}, {1, 4, 0}, {2, 4, 0},  -- y+4: 5 air
    {-1, 5, 0}, {0, 5, 0}, {1, 5, 0},                          -- y+5: 3 air
}

-- The center of the ring (trigger zone) is 3.5 blocks above the base
local function get_center(base_pos)
    return {x = base_pos.x, y = base_pos.y + 3, z = base_pos.z}
end

-- Arrival point: 2 blocks in front of center, clear of trigger radius
local function get_arrival_pos(base_pos)
    local c = get_center(base_pos)
    return {x = c.x, y = c.y, z = c.z - 2}
end

-- Legacy alias
local RING_OFFSETS = ALL_FRAME_OFFSETS

local function register_gate_at(pos)
    local address = make_address(pos)
    local meta = core.get_meta(pos)
    meta:set_string("address", address)
    meta:set_string("infotext", "Stargate: " .. address)

    -- Ensure the crystal slot inventory exists (set up here so it works
    -- for both newly-placed gates AND gates re-loaded via LBM on restart)
    local inv = meta:get_inventory()
    if inv:get_size("crystal") == 0 then
        inv:set_size("crystal", 1)
    end

    -- Persist gate position in mod_storage so we can re-register ALL gates
    -- on server startup — not just ones in loaded chunks.
    storage:set_string("gate_" .. address,
        pos.x .. "," .. pos.y .. "," .. pos.z)

    local center = get_center(pos)
    local arrival = get_arrival_pos(pos)

    local_gates[address] = {
        pos = vector.new(pos),
        center = vector.new(center),
        arrival = vector.new(arrival),
    }

    nexus.gate.register({
        address = address,
        label = WORLD .. " Gate",
        galaxy = GALAXY,
        world = WORLD,
        position = {x = center.x, y = center.y, z = center.z},
        arrival_offset = {x = 0, y = 0, z = -2},  -- 2 blocks in front of center
        facing = 0,
        powered = true,
        obstructed = false,
    })
end

local function remove_event_horizon(base_pos)
    for _, off in ipairs(PORTAL_OFFSETS) do
        local p = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        local node = core.get_node(p)
        if node.name == HORIZON_NODE then
            core.remove_node(p)
        end
    end
end

local function place_event_horizon(base_pos)
    for _, off in ipairs(PORTAL_OFFSETS) do
        local p = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        local node = core.get_node(p)
        if node.name == "air" then
            core.set_node(p, {name = HORIZON_NODE})
        end
    end
end

local function unregister_gate_at(pos)
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")
    if address == "" then return end

    -- Remove event horizon
    remove_event_horizon(pos)

    local_gates[address] = nil
    linked_gates[address] = nil
    gate_link_tiers[address] = nil

    -- Remove from mod_storage
    storage:set_string("gate_" .. address, "")

    nexus.gate.unregister(address)
    core.log("action", "[nexus] gate destroyed: " .. address)
end

-- The gate formspec
-- =============================================================================
-- Dialing Sequence
-- =============================================================================
-- When a dial succeeds, keystones light up one at a time, each showing the
-- color of the symbol being dialed. The color sequence IS the address.
-- Per-tier timing controls drama: same-world is fast, cross-galaxy is ceremonial.

-- Keystone node names and helpers (MUST be defined before play_dialing_sequence)
local KEYSTONE_COLORS = {
    "red", "orange", "yellow", "green", "cyan", "blue",
    "violet", "magenta", "white", "pink", "lime", "amber",
}
-- Expose for worldgen
nexus._keystone_colors = KEYSTONE_COLORS

local KEYSTONE_OFF = "nexus:keystone_off"
local function keystone_lit_name(color)
    return "nexus:keystone_lit_" .. color
end
local function is_keystone(name)
    if name == KEYSTONE_OFF then return true end
    for _, color in ipairs(KEYSTONE_COLORS) do
        if name == keystone_lit_name(color) then return true end
    end
    return false
end

-- Hash a string to a color index (1-12)
local function hash_to_symbol(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + string.byte(s, i)) % 12
    end
    return h + 1  -- 1-based index into KEYSTONE_COLORS
end

-- Compute the symbol sequence (colors) for a destination address
local function compute_dial_sequence(dest_address, tier)
    local route = address_to_route(dest_address)
    if not route then return {} end
    local symbols = {}
    if tier >= nexus.power.TIER.CROSS_GALAXY then
        symbols[#symbols+1] = hash_to_symbol(route.galaxy or "x")
    end
    if tier >= nexus.power.TIER.SAME_GALAXY then
        symbols[#symbols+1] = hash_to_symbol(route.world or "x")
    end
    -- Always include gate_id (split into symbols)
    local gid = route.gate_id or "g0_0"
    local half = math.floor(#gid / 2)
    symbols[#symbols+1] = hash_to_symbol(gid:sub(1, half))
    symbols[#symbols+1] = hash_to_symbol(gid:sub(half + 1))
    if tier >= nexus.power.TIER.SAME_GALAXY then
        symbols[#symbols+1] = hash_to_symbol((route.world or "x") .. "2")
    end
    if tier >= nexus.power.TIER.CROSS_GALAXY then
        symbols[#symbols+1] = hash_to_symbol((route.galaxy or "x") .. "2")
    end
    -- Final lock symbol
    symbols[#symbols+1] = hash_to_symbol(dest_address)
    return symbols
end

-- Play the dialing sequence: light each keystone one at a time
local function play_dialing_sequence(base_pos, symbols, tier, on_complete)
    local num_symbols = #symbols
    local per_symbol_time
    if tier == nexus.power.TIER.CROSS_GALAXY then
        per_symbol_time = DIAL_TIME.cross_galaxy
    elseif tier == nexus.power.TIER.SAME_GALAXY then
        per_symbol_time = DIAL_TIME.same_galaxy
    else
        per_symbol_time = DIAL_TIME.same_world
    end

    local function light_keystone(step)
        if step > num_symbols then
            -- All keystones lit — final burst then complete
            if on_complete then on_complete() end
            return
        end

        local color_idx = symbols[step]
        local color = KEYSTONE_COLORS[color_idx] or "white"
        -- Light the keystone at this position (step 1 = K1, step 2 = K2, etc.)
        local ks_idx = ((step - 1) % 7) + 1  -- 7 keystones (K1-K7)
        local off = KEYSTONE_OFFSETS[ks_idx]
        local kp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}

        if core.get_node(kp).name == KEYSTONE_OFF or is_keystone(core.get_node(kp).name) then
            core.swap_node(kp, {name = keystone_lit_name(color)})
        end

        -- Particle burst at this keystone
        core.add_particlespawner({
            amount = 15,
            time = 0.5,
            minpos = {x = kp.x - 0.3, y = kp.y - 0.3, z = kp.z - 0.3},
            maxpos = {x = kp.x + 0.3, y = kp.y + 0.3, z = kp.z + 0.3},
            minvel = {x = -1, y = 1, z = -1},
            maxvel = {x = 1, y = 3, z = 1},
            minexptime = 0.5,
            maxexptime = 1.0,
            minsize = 1,
            maxsize = 3,
            texture = "nexus_keystone_lit_" .. color .. ".png",
            glow = 14,
        })

        -- Dialing sound (rising pitch per step)
        core.sound_play("nexus_gate_dial", {
            pos = kp, max_hear_distance = 20, gain = 0.5,
            pitch = 0.8 + (step / num_symbols) * 0.5,
        })

        -- Light the next keystone after the delay
        core.after(per_symbol_time, function()
            light_keystone(step + 1)
        end)
    end

    -- Reset all keystones to off before starting
    for _, off in ipairs(KEYSTONE_OFFSETS) do
        local kp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        if is_keystone(core.get_node(kp).name) then
            core.swap_node(kp, {name = KEYSTONE_OFF})
        end
    end

    light_keystone(1)
end

-- Reset all keystones to unlit (called when link closes)
local function reset_keystones(base_pos)
    for _, off in ipairs(KEYSTONE_OFFSETS) do
        local kp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        if is_keystone(core.get_node(kp).name) then
            core.swap_node(kp, {name = KEYSTONE_OFF})
        end
    end
end
local function show_gate_formspec(pos, player)
    local pname = player:get_player_name()
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")
    local is_ancient = meta:get_string("ancient") == "true"
    local linked = linked_gates[address] ~= nil

    local title = is_ancient and "Ancient Stargate" or "Stargate"
    local status_text = linked and "● LINKED" or "○ IDLE"
    local status_color = linked and "#2BA830" or "#7A7A7A"

    -- Use Mineclonia's formspec helpers if available, else fallback
    local LC = "#313131"  -- Mineclonia label color
    local function islot(x, y, w, h)
        if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
            return mcl_formspec.get_itemslot_bg_v4(x, y, w, h)
        end
        return ""
    end

    local parts = {
        "formspec_version[4]",
        "size[12,15.5]",
        -- NO no_prepend — let Mineclonia's background theme apply
        string.format("label[4.5,0.4;%s]", title),
        string.format(
            "label[3,0.9;%s]",
            address),
        string.format(
            "label[4.8,1.3;%s%s%s]",
            core.colorize(status_color, status_text), "", ""),

        -- ── Crystal section ──
        "label[0.4,1.9;Crystal]",
        islot(0.6, 2.1, 1, 1),
        string.format("list[nodemeta:%d,%d,%d;crystal;0.6,2.1;1,1;]", pos.x, pos.y, pos.z),
        "label[1.9,2.3;Insert a resonance crystal to load saved addresses]",
        "label[1.9,2.6;Shift-click from your inventory to insert]",
    }

    -- Crystal content (addresses or PIN)
    local crystal = nexus.crystal.get_gate_crystal(pos)

    if crystal then
        local is_private = nexus.crystal.is_private(crystal)
        local unlocked = nexus.crystal.is_gate_unlocked(pos)

        if is_private and not unlocked then
            -- PIN entry
            parts[#parts+1] = "label[0.4,3.5;PIN Required]"
            parts[#parts+1] = string.format(
                "label[0.4,3.8;%sPrivate crystal — enter PIN to activate%s]",
                core.colorize("#C87000", ""), "")
            parts[#parts+1] = "pwd[4,4.1;4,0.8;gate_pin;Enter PIN]"
            parts[#parts+1] = "button[4,4.9;4,0.7;unlock;Unlock Crystal]"
        elseif unlocked then
            -- Saved addresses
            parts[#parts+1] = "label[0.4,3.5;Saved Addresses]"

            local addrs = nexus.crystal.get_gate_addresses(pos)
            local has_addrs = false
            local btn_x = 0.4
            local btn_y = 3.9
            local col = 0
            local addr_map = {}
            local addr_idx = 0
            for addr, entry in pairs(addrs) do
                has_addrs = true
                addr_idx = addr_idx + 1
                addr_map[addr_idx] = addr
                local lock = entry.encrypted and " \226\150\160" or ""
                local safe_label = core.formspec_escape(entry.label .. lock)
                parts[#parts+1] = string.format(
                    "button[%f,%f;5.5,0.7;addrbtn_%d;%s]",
                    btn_x, btn_y, addr_idx, safe_label)
                col = col + 1
                if col >= 2 then
                    col = 0
                    btn_x = 0.4
                    btn_y = btn_y + 0.8
                else
                    btn_x = 6.1
                end
            end

            local pmeta = player:get_meta()
            pmeta:set_string("nexus_addr_map", core.write_json(addr_map))

            if not has_addrs then
                pmeta:set_string("nexus_addr_map", "")
                parts[#parts+1] = "label[0.4,4.1;This crystal has no saved addresses]"
            end
        end
    else
        parts[#parts+1] = "label[0.4,3.5;Addresses]"
        parts[#parts+1] = "label[0.4,3.8;No crystal inserted]"
    end

    -- ── Manual dial section ──
    parts[#parts+1] = "label[0.4,7.2;Manual Dial]"
    parts[#parts+1] = "field[0.4,7.9;7.5,0.9;dest;Destination Address;]"
    parts[#parts+1] = "button[0.4,8.9;3.5,0.8;dial;Dial]"
    parts[#parts+1] = "button[4.1,8.9;3.5,0.8;close;Close Link]"

    -- ── Inventory section ──
    parts[#parts+1] = "label[0.4,10.0;Inventory]"
    parts[#parts+1] = islot(1, 10.4, 8, 4)
    parts[#parts+1] = string.format("list[current_player;main;1,10.4;8,4;]")
    parts[#parts+1] = string.format("listring[nodemeta:%d,%d,%d;crystal]", pos.x, pos.y, pos.z)
    parts[#parts+1] = "listring[current_player;main]"

    -- Store position in player meta
    local pmeta = player:get_meta()
    pmeta:set_string("nexus_gate_pos",
        pos.x .. "," .. pos.y .. "," .. pos.z)

    core.show_formspec(pname, "nexus:gate_dial", table.concat(parts, "\n"))
end

-- Expose formspec function for worldgen's ancient gate blocks
nexus._show_gate_formspec = show_gate_formspec

core.register_node(GATE_NODE, {
    description = "Stargate Base",
    tiles = {
        "nexus_gate_block.png",  -- top
        "nexus_gate_block.png",  -- bottom
        "nexus_gate_base.png",   -- right
        "nexus_gate_base.png",   -- left
        "nexus_gate_base.png",   -- back
        "nexus_gate_base.png",   -- front
    },
    groups = {cracky = 3, oddly_breakable_by_hand = 2},
    light_source = 8,

    on_construct = function(pos)
        register_gate_at(pos)
        -- Crystal slot inventory (1 slot)
        local meta = core.get_meta(pos)
        local inv = meta:get_inventory()
        inv:set_size("crystal", 1)
    end,

    on_destruct = function(pos)
        -- Drop the crystal before unregistering
        local meta = core.get_meta(pos)
        local inv = meta:get_inventory()
        if inv:get_list("crystal") then
            local crystal = inv:get_stack("crystal", 1)
            if not crystal:is_empty() then
                core.add_item(pos, crystal)
            end
        end
        nexus.crystal.lock(pos)
        unregister_gate_at(pos)
    end,

    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        show_gate_formspec(pos, player)
    end,

    -- Allow placing crystals from the hand
    allow_metadata_inventory_put = function(pos, listname, index, stack, player)
        if listname == "crystal" and nexus.crystal.is_crystal(stack) then
            return 1
        end
        return 0
    end,

    allow_metadata_inventory_take = function(pos, listname, index, stack, player)
        return 1
    end,

    on_metadata_inventory_put = function(pos, listname, index, stack, player)
        -- Lock the gate crystal slot when a new crystal is inserted
        nexus.crystal.lock(pos)
        -- Refresh the formspec so address buttons appear immediately
        show_gate_formspec(pos, player)
    end,

    on_metadata_inventory_take = function(pos, listname, index, stack, player)
        -- Lock when removed
        nexus.crystal.lock(pos)
        -- Refresh so the buttons/PIN disappear
        show_gate_formspec(pos, player)
    end,
})

-- =============================================================================
-- Keystone Nodes (unlit + 12 color-lit variants)
-- =============================================================================
-- Each keystone is a dark stone block when unlit. When its symbol is dialed,
-- it swaps to a lit color variant with light emission. The color sequence
-- during dialing IS the address — players can recognize destinations by
-- their color pattern.

-- Forward-declared destruct handler (defined after node registrations)
local keystone_destruct_handler

-- Span block (structural frame between keystones)
core.register_node(SPAN_NODE, {
    description = "Gate Span",
    tiles = {"nexus_span.png"},
    groups = {cracky = 3, not_in_creative_inventory = 1},
    light_source = 1,
    drop = "",
    on_destruct = keystone_destruct_handler,  -- same cascade cleanup
})

-- Unlit keystone
core.register_node(KEYSTONE_OFF, {
    description = "Gate Keystone",
    tiles = {"nexus_keystone_off.png"},
    groups = {cracky = 3, not_in_creative_inventory = 1},
    light_source = 2,
    drop = "",
    on_destruct = keystone_destruct_handler,
})

-- Lit keystones (one per color)
for _, color in ipairs(KEYSTONE_COLORS) do
    core.register_node(keystone_lit_name(color), {
        description = "Gate Keystone (" .. color .. ")",
        tiles = {"nexus_keystone_lit_" .. color .. ".png"},
        groups = {cracky = 3, not_in_creative_inventory = 1},
        light_source = 12,
        drop = "",
        on_destruct = keystone_destruct_handler,
    })
end

-- Destruct handler: if any keystone is destroyed, remove the entire gate
local function keystone_destruct_handler(pos)
    for addr, data in pairs(local_gates) do
        local base_pos = data.pos
        for _, off in ipairs(KEYSTONE_OFFSETS) do
            local kp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
            if vector.equals(kp, pos) then
                remove_event_horizon(base_pos)
                -- Remove all keystones
                for _, off2 in ipairs(KEYSTONE_OFFSETS) do
                    local p = {x = base_pos.x + off2[1], y = base_pos.y + off2[2], z = base_pos.z + off2[3]}
                    if is_keystone(core.get_node(p).name) or core.get_node(p).name == SPAN_NODE then
                        core.remove_node(p)
                    end
                end
                -- Remove the base
                if core.get_node(base_pos).name == GATE_NODE then
                    core.remove_node(base_pos)
                end
                return
            end
        end
    end
end

-- Event horizon — the glowing portal surface. Non-solid, ephemeral.
core.register_node(HORIZON_NODE, {
    description = "Event Horizon",
    tiles = {{
        name = "nexus_event_horizon.png",
        animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = 3},
    }},
    drawtype = "glasslike",
    paramtype = "light",
    groups = {not_in_creative_inventory = 1, unbreakable = 1},
    light_source = 12,
    walkable = false,
    pointable = false,
    diggable = false,
    drop = "",
    post_effect_color = {a = 120, r = 30, g = 80, b = 200},  -- bluish tint when inside
    -- NOTE: no on_construct that removes the node — that was the bug.
    -- The node is already restricted via groups (not_in_creative_inventory,
    -- diggable=false) and only placed by the gate system via set_node.
})

-- Re-register gates on server restart (LBM fires for loaded nodes)
core.register_lbm({
    label = "Re-register stargates",
    name = "nexus:gate_reregister",
    nodenames = {GATE_NODE},
    run_at_every_load = true,
    action = function(pos, node)
        register_gate_at(pos)
    end,
})

-- On server startup, re-register ALL gates from mod_storage — even ones in
-- unloaded chunks. This ensures gates are always dialable as soon as the
-- server starts, without needing a player to physically visit them first.
local function reregister_gates()
    local keys = storage:to_table().fields
    local count = 0
    for key, val in pairs(keys) do
        if key:match("^gate_") and val ~= "" then
            local parts = string.split(val, ",")
            local pos = {
                x = tonumber(parts[1]),
                y = tonumber(parts[2]),
                z = tonumber(parts[3]),
            }
            if pos.x then
                local node = core.get_node(pos)
                if node.name == GATE_NODE then
                    register_gate_at(pos)
                    count = count + 1
                else
                    local address = key:sub(5)
                    storage:set_string(key, "")
                    core.log("action", "[nexus] cleaned up stale gate: " .. address)
                end
            end
        end
    end
    if count > 0 then
        core.log("action", "[nexus] re-registered " .. count ..
            " gate(s) from storage on startup")
    end
    return count
end

core.register_on_mods_loaded(function()
    -- Defer all registration attempts — map isn't available during on_mods_loaded.
    -- Try at 1s, 3s, and 5s to cover proxy startup timing.
    core.after(1, reregister_gates)
    core.after(3, reregister_gates)
    core.after(5, reregister_gates)
end)

-- =============================================================================
-- Formspec Handler (Dial / Close)
-- =============================================================================

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "nexus:gate_dial" then return end

    local pname = player:get_player_name()
    -- Debug: log all field names so we can see what the client sends
    local field_names = {}
    for k, v in pairs(fields) do
        table.insert(field_names, k .. (type(v) == "string" and v ~= "" and "=" .. v or ""))
    end
    core.log("action", "[nexus] gate_dial fields from " .. pname .. ": " ..
        table.concat(field_names, ", "))
    local pmeta = player:get_meta()
    local pos_str = pmeta:get_string("nexus_gate_pos")
    if pos_str == "" then return end

    local parts = string.split(pos_str, ",")
    local pos = {x = tonumber(parts[1]), y = tonumber(parts[2]), z = tonumber(parts[3])}
    local address = core.get_meta(pos):get_string("address")

    -- Handle PIN unlock
    if fields.unlock then
        local ok, err = nexus.crystal.try_unlock(pos, fields.gate_pin or "")
        if ok then
            core.chat_send_player(pname, "[nexus] Crystal unlocked.")
        else
            core.chat_send_player(pname, "[nexus] " .. (err or "Unlock failed."))
        end
        show_gate_formspec(pos, player)
        return true
    end

    -- Handle crystal address button clicks (numeric index → actual address)
    local dial_addr = nil
    for field_name in pairs(fields) do
        local clicked_idx = field_name:match("^addrbtn_(%d+)$")
        if clicked_idx then
            local addr_map_str = pmeta:get_string("nexus_addr_map")
            if addr_map_str == "" then
                core.chat_send_player(pname, "[nexus] ERROR: no address map found")
                core.sound_play("nexus_gate_abort", {to_player = pname})
                return true
            end
            local addr_map = core.parse_json(addr_map_str)
            local dest = addr_map and addr_map[tonumber(clicked_idx)]
            if not dest then
                core.chat_send_player(pname, "[nexus] ERROR: address button " ..
                    clicked_idx .. " not in map")
                core.sound_play("nexus_gate_abort", {to_player = pname})
                return true
            end
            dial_addr = dest
            core.chat_send_player(pname, "[nexus] Dialing " .. dest .. "...")
            core.sound_play("nexus_gate_dial", {to_player = pname})
            break
        end
    end

    if dial_addr or fields.dial then
        local dest = dial_addr or (fields.dest or ""):trim()
        if dest == "" then
            core.chat_send_player(pname, "[nexus] Enter a destination address")
            return true
        end

        -- Power check BEFORE dialing — don't open a wormhole you can't use
        local route = address_to_route(dest)
        local tier, tier_label = nexus.power.tier_for(
            GALAXY, WORLD,
            (route and route.galaxy) or GALAXY,
            (route and route.world) or WORLD)
        local can_afford, perr = nexus.power.check(address, tier)
        if not can_afford then
            core.chat_send_player(pname, "[nexus] " .. perr)
            core.sound_play("nexus_gate_abort", {to_player = pname})
            return true
        end

        core.chat_send_player(pname, "[nexus] Dialing " .. dest .. "...")

        nexus.gate.establish_link(address, dest, pname, function(ok, info)
            if ok then
                -- Determine tier and play dialing sequence
                local route = address_to_route(dest)
                local tier, tier_label = nexus.power.tier_for(
                    GALAXY, WORLD,
                    (route and route.galaxy) or GALAXY,
                    (route and route.world) or WORLD)
                local symbols = compute_dial_sequence(dest, tier)

                -- Consume dial cost power NOW (not on walk-through)
                nexus.power.consume(address, tier)
                -- Track the tier for upkeep
                gate_link_tiers[address] = tier

                core.chat_send_player(pname, "[nexus] Connection established — dialing " ..
                    #symbols .. " symbols (" .. tier_label .. ")...")

                -- Mark as dialing so the poller doesn't place the horizon early
                dialing_in_progress[address] = true

                play_dialing_sequence(pos, symbols, tier, function()
                    -- Sequence complete — open the portal
                    dialing_in_progress[address] = nil
                    linked_gates[address] = true
                    place_event_horizon(pos)
                    core.chat_send_player(pname, "[nexus] Wormhole established!")
                    core.sound_play("nexus_gate_open", {
                        pos = pos, max_hear_distance = 30, gain = 0.8
                    })
                    -- Particle burst on portal open
                    local center = get_center(pos)
                    core.add_particlespawner({
                        amount = 40, time = 0.5,
                        minpos = {x=center.x-1, y=center.y-1, z=center.z-1},
                        maxpos = {x=center.x+1, y=center.y+1, z=center.z+1},
                        minvel = {x=-3, y=-3, z=-3},
                        maxvel = {x=3, y=3, z=3},
                        minexptime = 0.5, maxexptime = 1.5,
                        minsize = 2, maxsize = 5,
                        texture = "nexus_event_horizon.png",
                        glow = 14,
                    })
                    -- Don't reopen the formspec — the player is watching the
                    -- dialing animation, not interacting with the GUI
                end)
            else
                core.chat_send_player(pname, "[nexus] Dialing failed: " ..
                    tostring(info))
                core.sound_play("nexus_gate_abort", {to_player = pname})
            end
        end)

    elseif fields.close then
        nexus.gate.close_link(address, function(ok)
            linked_gates[address] = nil
    gate_link_tiers[address] = nil
            remove_event_horizon(pos)
            reset_keystones(pos)
            if ok then
                core.chat_send_player(pname, "[nexus] Wormhole closed.")
                core.sound_play("nexus_gate_close", {
                    pos = pos, max_hear_distance = 30, gain = 0.8
                })
            end
            show_gate_formspec(pos, player)
        end)
    end

    return true  -- handled
end)

-- =============================================================================
-- Pad Trigger (Walk-Through Travel)
-- =============================================================================

-- Check for players walking into linked gates.
local pad_timer = 0
core.register_globalstep(function(dtime)
    pad_timer = pad_timer + dtime
    if pad_timer < 0.3 then return end  -- ~3x/second
    pad_timer = 0

    for address, gate_data in pairs(local_gates) do
        if linked_gates[address] then
            -- Check at feet level (y+1) where the player walks through the opening.
            -- The center at y+2 is too high — standing on the base block puts feet at y+1,
            -- which is 1 block below center and barely within the old 1.5 radius.
            local trigger_pos = vector.new(gate_data.pos)
            trigger_pos.y = trigger_pos.y + 1  -- feet level at the portal opening
            local objects = core.get_objects_inside_radius(trigger_pos, 1.5)
            for _, obj in ipairs(objects) do
                if obj:is_player() then
                    nexus.gate.travel_player(obj, address)
                end
            end
        end
    end
end)

-- =============================================================================
-- Item Transfer Through Gates
-- =============================================================================
-- Dropped items entering a linked gate are captured, sent to the proxy,
-- and recreated at the destination gate with transformed velocity.
-- Items use data transfer (destroy+recreate), NOT connection hop.

--- Serialize an ItemStack for transfer
local function serialize_item(stack)
    local entry = {
        name = stack:get_name(),
        count = stack:get_count(),
        wear = stack:get_wear(),
    }
    local meta = stack:get_meta()
    local fields = meta:to_table().fields
    if next(fields) then
        entry.meta = fields
    end
    return entry
end

--- Rotate a velocity vector by an angle (radians), keeping Y unchanged.
local function transform_velocity(vel, angle)
    local cos_a = math.cos(angle)
    local sin_a = math.sin(angle)
    return {
        x = vel.x * cos_a - vel.z * sin_a,
        y = vel.y,
        z = vel.x * sin_a + vel.z * cos_a,
    }
end

--- Send an item through a linked gate to the destination.
function nexus.gate.send_item(gate_address, itemstack, velocity, owner)
    -- Look up the link to find the destination
    nexus.gate.get_link(gate_address, function(link)
        if not link or not link.linked then return end

        local item_data = serialize_item(itemstack)
        local payload = core.write_json({
            entry_gate = gate_address,
            destination_gate = link.remote_address,
            item = item_data,
            velocity = velocity or {x = 0, y = 0, z = 0},
            owner = owner or "",
        })

        gate_http({
            url = PROXY .. "/nexus/item",
            method = "POST",
            data = payload,
            timeout = TIMEOUT,
        }, function(result)
            if result.code ~= 200 then
                core.log("warning", "[nexus] item send failed for " ..
                    gate_address .. ": HTTP " .. result.code)
            end
        end)
    end)
end

--- Fetch and recreate items arriving at a local gate.
local function fetch_incoming_items(address, gate_data)
    gate_http({
        url = PROXY .. "/nexus/item/" .. address,
        method = "GET",
        timeout = TIMEOUT,
    }, function(result)
        if result.code ~= 200 then return end
        local resp = core.parse_json(result.data)
        if not resp or not resp.items or resp.count == 0 then return end

        local pos = gate_data.arrival or gate_data.center or gate_data.pos
        for _, qi in ipairs(resp.items) do
            -- Reconstruct the ItemStack
            local item_data = qi.item or {}
            local stack = ItemStack({
                name = item_data.name,
                count = item_data.count,
                wear = item_data.wear or 0,
            })
            -- Restore item metadata
            if item_data.meta then
                local meta = stack:get_meta()
                for key, value in pairs(item_data.meta) do
                    meta:set_string(key, value)
                end
            end

            -- Create the item at the arrival point (in front of gate, clear of trigger zone)
            local obj = core.add_item(pos, stack)
            if obj then
                -- Give it outward velocity so it flies away from the gate
                obj:set_velocity({
                    x = qi.velocity and qi.velocity.x or 0,
                    y = qi.velocity and qi.velocity.y or 3,
                    z = qi.velocity and -(qi.velocity.z) or -3,
                })
            end

            core.log("action", "[nexus] item arrived at " .. address ..
                ": " .. (item_data.name or "?") ..
                " x" .. (item_data.count or 1))
        end
    end)
end

-- Item sensor: detect dropped items entering linked gates (outgoing)
local item_sensor_timer = 0
core.register_globalstep(function(dtime)
    item_sensor_timer = item_sensor_timer + dtime
    if item_sensor_timer < 0.2 then return end  -- 5x/second
    item_sensor_timer = 0

    for address, gate_data in pairs(local_gates) do
        if linked_gates[address] then
            local pos = gate_data.center or gate_data.pos
            local objects = core.get_objects_inside_radius(pos, 1.5)
            for _, obj in ipairs(objects) do
                local ent = obj:get_luaentity()
                if ent and ent.name == "__builtin:item" and not ent._gate_sent then
                    ent._gate_sent = true  -- prevent double-capture
                    local stack = ItemStack(ent.itemstring)
                    if not stack:is_empty() then
                        local vel = obj:get_velocity()
                        nexus.gate.send_item(address, stack, vel)
                        obj:remove()  -- remove from origin
                    end
                end
            end
        end
    end
end)

-- Incoming item poller: fetch items waiting at our gates
local item_poll_timer = 0
core.register_globalstep(function(dtime)
    item_poll_timer = item_poll_timer + dtime
    if item_poll_timer < 0.5 then return end  -- 2x/second
    item_poll_timer = 0

    for address, gate_data in pairs(local_gates) do
        fetch_incoming_items(address, gate_data)
    end
end)

-- =============================================================================
-- Chat Commands (for testing / convenience)
-- =============================================================================

-- /placegate — auto-build a complete stargate at the player's position
-- Places a base block and all ring blocks. For quick testing.
core.register_chatcommand("placegate", {
    params = "",
    description = "Build a complete hexagonal stargate at your position",
    privs = {give = true},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end

        local pos = vector.round(player:get_pos())
        pos.y = math.floor(pos.y)

        -- Check area is clear (keystones + portal)
        local blocked = false
        for _, off in ipairs(KEYSTONE_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            if core.get_node(p).name ~= "air" then
                blocked = true
                break
            end
        end
        if not blocked then
            for _, off in ipairs(PORTAL_OFFSETS) do
                local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
                if core.get_node(p).name ~= "air" then
                    blocked = true
                    break
                end
            end
        end

        if blocked then
            return false, "Area not clear — need open space for the hexagonal gate"
        end

        -- Place keystone blocks at each vertex
        for _, off in ipairs(KEYSTONE_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            core.set_node(p, {name = KEYSTONE_OFF})
        end

        -- Place span blocks between vertices
        for _, off in ipairs(SPAN_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            core.set_node(p, {name = SPAN_NODE})
        end

        -- Place base block (triggers on_construct → registration)
        core.set_node(pos, {name = GATE_NODE})

        local address = core.get_meta(pos):get_string("address")
        return true, "Hexagonal stargate built: " .. address
    end,
})

-- /dial <address> — dial from the nearest gate
core.register_chatcommand("dial", {
    params = "<destination_address>",
    description = "Dial another stargate from the nearest gate",
    privs = {},
    func = function(name, param)
        local dest = param:trim()
        if dest == "" then
            return false, "Usage: /dial <address> (e.g. /dial beta:g10_20)"
        end

        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found" end

        -- Find nearest gate
        local ppos = player:get_pos()
        local nearest_addr = nil
        local nearest_dist = math.huge
        for addr, data in pairs(local_gates) do
            local dist = vector.distance(ppos, data.pos)
            if dist < nearest_dist then
                nearest_dist = dist
                nearest_addr = addr
            end
        end

        if not nearest_addr then
            return false, "No stargate found on this server"
        end
        if nearest_dist > 100 then
            return false, "Nearest stargate is too far (" ..
                math.floor(nearest_dist) .. " blocks)"
        end

        -- Power check BEFORE dialing
        local route = address_to_route(dest)
        local tier, tier_label = nexus.power.tier_for(
            GALAXY, WORLD,
            (route and route.galaxy) or GALAXY,
            (route and route.world) or WORLD)
        local can_afford, perr = nexus.power.check(nearest_addr, tier)
        if not can_afford then
            return false, perr
        end

        core.chat_send_player(name, "[nexus] Dialing " .. dest ..
            " from " .. nearest_addr .. "...")

        nexus.gate.establish_link(nearest_addr, dest, name, function(ok, info)
            if ok then
                linked_gates[nearest_addr] = true
                -- Consume dial cost and track tier for upkeep
                nexus.power.consume(nearest_addr, tier)
                gate_link_tiers[nearest_addr] = tier
                local gate_data = local_gates[nearest_addr]
                if gate_data then
                    place_event_horizon(gate_data.pos)
                    core.sound_play("nexus_gate_open", {
                        pos = gate_data.center or gate_data.pos,
                        max_hear_distance = 30, gain = 0.8
                    })
                end
                core.chat_send_player(name, "[nexus] Wormhole established! Walk into the gate to travel.")
            else
                core.chat_send_player(name, "[nexus] Dialing failed: " ..
                    tostring(info))
            end
        end)

        return true
    end,
})

-- /removegate — remove the nearest gate (for cleanup of old/broken gates)
core.register_chatcommand("removegate", {
    params = "",
    description = "Remove the nearest stargate and all its blocks",
    privs = {give = true},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end

        local ppos = player:get_pos()
        local nearest_pos = nil
        local nearest_dist = math.huge

        for addr, data in pairs(local_gates) do
            local dist = vector.distance(ppos, data.pos)
            if dist < nearest_dist then
                nearest_dist = dist
                nearest_pos = data.pos
            end
        end

        if not nearest_pos then
            -- Maybe it's an old base block not in local_gates. Search nearby.
            for x = -3, 3 do
                for y = -2, 6 do
                    for z = -3, 3 do
                        local p = {x = ppos.x + x, y = ppos.y + y, z = ppos.z + z}
                        local node = core.get_node(p)
                        if node.name == GATE_NODE then
                            nearest_pos = p
                            break
                        end
                    end
                end
            end
        end

        if not nearest_pos then
            return false, "No stargate found nearby"
        end

        -- Remove all keystones
        for _, off in ipairs(KEYSTONE_OFFSETS) do
            local p = {x = nearest_pos.x + off[1], y = nearest_pos.y + off[2], z = nearest_pos.z + off[3]}
            if is_keystone(core.get_node(p).name) or core.get_node(p).name == SPAN_NODE then
                core.remove_node(p)
            end
            -- Also clean up old ring nodes
            local old_ring = core.get_node(p)
            if old_ring.name == "nexus:gate_ring" then
                core.remove_node(p)
            end
        end
        -- Remove event horizon
        remove_event_horizon(nearest_pos)
        -- Remove base block
        if core.get_node(nearest_pos).name == GATE_NODE then
            core.remove_node(nearest_pos)
        end

        return true, "Stargate removed"
    end,
})

-- /closegate — close the nearest gate's link
core.register_chatcommand("closegate", {
    params = "",
    description = "Close the nearest stargate's wormhole",
    privs = {},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end

        local ppos = player:get_pos()
        local nearest_addr = nil
        local nearest_dist = math.huge
        for addr, data in pairs(local_gates) do
            local dist = vector.distance(ppos, data.pos)
            if dist < nearest_dist then
                nearest_dist = dist
                nearest_addr = addr
            end
        end

        if not nearest_addr then
            return false, "No stargate found"
        end

        nexus.gate.close_link(nearest_addr, function()
            linked_gates[nearest_addr] = nil
            gate_link_tiers[nearest_addr] = nil
            core.chat_send_player(name, "[nexus] Wormhole closed.")
            local gate_data = local_gates[nearest_addr]
            if gate_data then
                remove_event_horizon(gate_data.pos)
                reset_keystones(gate_data.pos)
                core.sound_play("nexus_gate_close", {
                    pos = gate_data.center or gate_data.pos,
                    max_hear_distance = 30, gain = 0.8
                })
            end
        end)
        return true
    end,
})

-- /gates — list all gates on this server
core.register_chatcommand("gates", {
    params = "",
    description = "List all stargates on this server",
    privs = {},
    func = function(name)
        if next(local_gates) == nil then
            return true, "No stargates on this server."
        end
        local lines = {"Stargates on " .. GALAXY .. ":"}
        for addr, data in pairs(local_gates) do
            local linked = linked_gates[addr] and " [LINKED]" or ""
            local p = data.pos
            table.insert(lines, "  " .. addr .. " at (" ..
                p.x .. "," .. p.y .. "," .. p.z .. ")" .. linked)
        end
        return true, table.concat(lines, "\n")
    end,
})

-- =============================================================================
-- Link State Refresh (catch incoming links)
-- =============================================================================

-- Periodically poll the proxy for link state to catch links established
-- from the other direction (incoming wormholes).
-- Also places/removes the event horizon visual when link state changes.
local refresh_timer = 0
core.register_globalstep(function(dtime)
    refresh_timer = refresh_timer + dtime
    if refresh_timer < 2.0 then return end  -- every 2 seconds
    refresh_timer = 0

    for address, gate_data in pairs(local_gates) do
        nexus.gate.get_link(address, function(link)
            local is_linked = link and link.linked
            local was_linked = linked_gates[address] ~= nil

            -- ENFORCE visual state, not just react to changes.
            -- This fixes desync after restarts: leftover event horizon
            -- nodes get cleaned up, missing ones get placed.
            if is_linked and not was_linked then
                if dialing_in_progress[address] then
                    linked_gates[address] = true
                else
                    linked_gates[address] = true
                    place_event_horizon(gate_data.pos)
                    core.sound_play("nexus_gate_open", {
                        pos = gate_data.center, max_hear_distance = 30, gain = 0.6
                    })
                end
            elseif not is_linked and was_linked then
                linked_gates[address] = nil
                gate_link_tiers[address] = nil
                remove_event_horizon(gate_data.pos)
                reset_keystones(gate_data.pos)
                core.sound_play("nexus_gate_close", {
                    pos = gate_data.center, max_hear_distance = 30, gain = 0.6
                })
            elseif not is_linked and not was_linked then
                -- Not linked locally AND not linked on proxy — make sure
                -- any leftover event horizon nodes are gone (desync cleanup)
                remove_event_horizon(gate_data.pos)
            end
        end)
    end
end)

-- Cleanup cooldown on leave
core.register_on_leaveplayer(function(player)
    arrival_cooldown[player:get_player_name()] = nil
end)

-- =============================================================================
-- Public API for nexus_power (upkeep support)
-- =============================================================================

--- Return all local gates (address → gate_data) for upkeep iteration
function nexus.gate.get_local_gates()
    return local_gates
end

--- Is this gate's wormhole currently open AND did this gate initiate the dial?
--- Only the origin gate pays upkeep — the receiving gate doesn't.
function nexus.gate.is_dial_origin(address)
    return linked_gates[address] ~= nil and gate_link_tiers[address] ~= nil
end

--- Get the power tier of the active link for this gate (for upkeep cost)
function nexus.gate.get_link_tier(address)
    return gate_link_tiers[address] or nexus.power.TIER.SAME_WORLD
end

core.log("action", "[nexus] gate system loaded")
