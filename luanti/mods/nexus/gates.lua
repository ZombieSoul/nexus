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
    local galaxy, world, gate_id = addr:match("^([^:]+):([^:]+):([^:]+)$")
    if not galaxy then return nil end
    return { galaxy = galaxy, world = world, gate_id = gate_id }
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

-- Arrival cooldown to prevent immediate bounce-back (pname → expiry time)
local arrival_cooldown = {}

-- Generate a human-readable address from position.
local function make_address(pos)
    return GALAXY .. ":g" .. math.abs(pos.x) .. "_" .. math.abs(pos.z)
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

            -- Consume power for this trip
            if not nexus.power.consume(gate_address, tier) then
                core.chat_send_player(pname, "[nexus] Power draw failed. Try again.")
                return
            end

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

            -- Consume power for this trip
            if not nexus.power.consume(gate_address, tier) then
                core.chat_send_player(pname, "[nexus] Power draw failed. Try again.")
                return
            end

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
local RING_NODE = "nexus:gate_ring"
local HORIZON_NODE = "nexus:event_horizon"

-- =============================================================================
-- Gate Structure Geometry
-- =============================================================================
-- The gate is a 3-wide, 5-tall ring. The base block is the controller,
-- placed at the bottom-center. Ring blocks form the frame. The portal
-- opening is the center column (3 blocks tall). The event horizon fills
-- the opening when linked.
--
-- Layout (relative to base block at origin, facing north / -Z):
--
--   Ring Ring Ring    y+4   top of ring
--   Ring Air  Ring    y+3
--   Ring Air  Ring    y+2   ← center (trigger zone, event horizon)
--   Ring Air  Ring    y+1
--   Ring Base Ring    y+0   bottom
--
-- Players/items arrive 2 blocks IN FRONT of center (z-2), clear of the
-- 1.5-block trigger radius. This prevents the item re-capture loop.

-- Ring block offsets relative to the base block (excluding base itself)
local RING_OFFSETS = {
    {-1, 0, 0}, {1, 0, 0},                       -- bottom row (left, right of base)
    {-1, 1, 0}, {1, 1, 0},                       -- row 1
    {-1, 2, 0}, {1, 2, 0},                       -- row 2
    {-1, 3, 0}, {1, 3, 0},                       -- row 3
    {-1, 4, 0}, {0, 4, 0}, {1, 4, 0},            -- top row
}

-- Portal opening offsets (where event horizon appears when linked)
local PORTAL_OFFSETS = {
    {0, 1, 0}, {0, 2, 0}, {0, 3, 0},
}

-- The center of the ring (trigger zone) is 2 blocks above the base
local function get_center(base_pos)
    return {x = base_pos.x, y = base_pos.y + 2, z = base_pos.z}
end

-- Arrival point: 2 blocks in front of center, clear of trigger radius
local function get_arrival_pos(base_pos)
    local c = get_center(base_pos)
    return {x = c.x, y = c.y, z = c.z - 2}
end

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

    nexus.gate.unregister(address)
    core.log("action", "[nexus] gate destroyed: " .. address)
end

-- The gate formspec
local function show_gate_formspec(pos, player)
    local pname = player:get_player_name()
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")
    local linked = linked_gates[address] ~= nil

    local status = linked and "Linked (wormhole open)" or "Idle"
    local status_color = linked and "00FF00" or "888888"

    local parts = {
        "formspec_version[4]",
        "size[12,12]",
        "no_prepend[]",
        "bgcolor[#0A0A2A;true]",
        string.format(
            "hypertext[0.5,0.2;9,0.8;addr;<global halign=center><style color=#00BFFF size=18>Stargate: %s</style>]",
            core.formspec_escape(address)),
        string.format(
            "hypertext[0.5,0.9;9,0.5;status;<global halign=center><style color=#%s size=14>%s</style>]",
            status_color, status),
        -- Crystal slot + label
        "label[0.5,1.8;Crystal slot:]",
        "listcolors[#333355;#555577;#000000;#444466;#666688]",
        -- Visible box behind the slot so players can see it
        string.format("box[2.9,1.6;1.2,1.2;#333355]"),
        string.format("list[nodemeta:%d,%d,%d;crystal;3,1.7;1,1;]", pos.x, pos.y, pos.z),
        "hypertext[4.5,1.7;5,1.2;slot_help;<style color=#888888 size=12>Insert a resonance crystal here to load saved addresses.\\nShift-click the crystal in your inventory below to insert it.</style>]",
    }

    -- Crystal addresses or PIN entry
    local crystal = nexus.crystal.get_gate_crystal(pos)
    local y = 3.1

    if crystal then
        local is_private = nexus.crystal.is_private(crystal)
        local unlocked = nexus.crystal.is_gate_unlocked(pos)

        if is_private and not unlocked then
            -- Show PIN entry
            parts[#parts+1] = string.format(
                "hypertext[0.5,%f;9,0.5;pin_hint;<global halign=center><style color=#FF8800 size=14>Private crystal — enter PIN to activate</style>]", y)
            y = y + 0.7
            parts[#parts+1] = string.format("pwd[3,%f;4,0.8;gate_pin;PIN]", y)
            y = y + 1.0
            parts[#parts+1] = string.format("button[3,%f;4,0.8;unlock;Unlock]", y)
            y = y + 1.2
        elseif unlocked then
            -- Show saved addresses as buttons (using numeric index to
            -- avoid corrupting addresses that contain underscores)
            local addrs = nexus.crystal.get_gate_addresses(pos)
            local has_addrs = false
            local btn_x = 0.5
            local btn_y = y
            local col = 0
            local addr_map = {}  -- index → actual address
            local addr_idx = 0
            for addr, entry in pairs(addrs) do
                has_addrs = true
                addr_idx = addr_idx + 1
                addr_map[addr_idx] = addr
                local lock_icon = entry.encrypted and " \194\187" or ""
                local safe_label = core.formspec_escape(entry.label .. lock_icon)
                parts[#parts+1] = string.format(
                    "button[%f,%f;5,0.6;addrbtn_%d;%s]",
                    btn_x, btn_y, addr_idx, safe_label)
                col = col + 1
                if col >= 2 then
                    col = 0
                    btn_x = 0.5
                    btn_y = btn_y + 0.7
                else
                    btn_x = 6.0
                end
            end
            -- Store the address map in player meta so the click handler
            -- can look up the actual address
            local pmeta = player:get_meta()
            pmeta:set_string("nexus_addr_map", core.write_json(addr_map))
            if not has_addrs then
                pmeta:set_string("nexus_addr_map", "")
                parts[#parts+1] = string.format(
                    "hypertext[0.5,%f;9,0.5;no_addr;<global halign=center><style color=#666666 size=13>Crystal has no saved addresses</style>]", y)
            end
            y = btn_y + 0.8
        end
    end

    -- Manual dial section
    parts[#parts+1] = string.format("field[1,%f;7,0.8;dest;Or type an address;]", y)
    y = y + 0.9
    parts[#parts+1] = string.format("button[1,%f;3,0.8;dial;Dial]", y)
    parts[#parts+1] = string.format("button[5,%f;3,0.8;close;Close Link]", y)
    y = y + 1.2

    -- Player inventory (shown so players can drag/shift-click crystals into the gate slot)
    parts[#parts+1] = "hypertext[0.5,0;0,0;inv_label;]"  -- placeholder
    parts[#parts+1] = string.format("list[current_player;main;1.5,%f;8,4;]", y)
    -- Listrings enable shift-click to move items between gate crystal slot and player inventory
    parts[#parts+1] = string.format("listring[nodemeta:%d,%d,%d;crystal]", pos.x, pos.y, pos.z)
    parts[#parts+1] = "listring[current_player;main]"

    -- Store position in player meta so the formspec handler knows which gate
    local pmeta = player:get_meta()
    pmeta:set_string("nexus_gate_pos",
        pos.x .. "," .. pos.y .. "," .. pos.z)

    core.show_formspec(pname, "nexus:gate_dial", table.concat(parts, "\n"))
end

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

-- Ring frame blocks — form the stargate structure. Not obtainable normally.
core.register_node(RING_NODE, {
    description = "Stargate Ring Segment",
    tiles = {"nexus_gate_ring.png"},
    groups = {cracky = 3, not_in_creative_inventory = 1},
    light_source = 4,
    drop = "",  -- doesn't drop anything when broken

    on_destruct = function(pos)
        -- If a ring block is destroyed, find and destroy the whole gate
        for addr, data in pairs(local_gates) do
            local base_pos = data.pos
            for _, off in ipairs(RING_OFFSETS) do
                local rp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
                if vector.equals(rp, pos) then
                    -- This ring block belongs to this gate — remove everything
                    remove_event_horizon(base_pos)
                    -- Remove all ring blocks
                    for _, off2 in ipairs(RING_OFFSETS) do
                        local p = {x = base_pos.x + off2[1], y = base_pos.y + off2[2], z = base_pos.z + off2[3]}
                        local node = core.get_node(p)
                        if node.name == RING_NODE then
                            core.remove_node(p)
                        end
                    end
                    -- Remove the base
                    local bnode = core.get_node(base_pos)
                    if bnode.name == GATE_NODE then
                        core.remove_node(base_pos)
                    end
                    return
                end
            end
        end
    end,
})

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
    -- Prevent placement by players — only the gate system places this
    on_construct = function(pos)
        -- If somehow placed manually, remove it
        core.remove_node(pos)
    end,
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

-- =============================================================================
-- Formspec Handler (Dial / Close)
-- =============================================================================

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "nexus:gate_dial" then return end

    local pname = player:get_player_name()
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
    for field_name in pairs(fields) do
        local clicked_idx = field_name:match("^addrbtn_(%d+)$")
        if clicked_idx then
            local addr_map_str = pmeta:get_string("nexus_addr_map")
            if addr_map_str ~= "" then
                local addr_map = core.parse_json(addr_map_str)
                local dest = addr_map and addr_map[clicked_idx]
                if dest then
                    fields.dest = dest
                    break
                end
            end
        end
    end

    if fields.dial then
        local dest = (fields.dest or ""):trim()
        if dest == "" then
            core.chat_send_player(pname, "[nexus] Enter a destination address")
            return true
        end

        core.chat_send_player(pname, "[nexus] Dialing " .. dest .. "...")
        core.sound_play("nexus_gate_dial", {to_player = pname})

        nexus.gate.establish_link(address, dest, pname, function(ok, info)
            if ok then
                linked_gates[address] = true
                place_event_horizon(pos)
                core.chat_send_player(pname, "[nexus] Wormhole established!")
                core.sound_play("nexus_gate_open", {
                    pos = pos, max_hear_distance = 30, gain = 0.8
                })
                -- Refresh formspec
                show_gate_formspec(pos, player)
            else
                core.chat_send_player(pname, "[nexus] Dialing failed: " ..
                    tostring(info))
                core.sound_play("nexus_gate_abort", {to_player = pname})
            end
        end)

    elseif fields.close then
        nexus.gate.close_link(address, function(ok)
            linked_gates[address] = nil
            remove_event_horizon(pos)
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
            local pos = gate_data.center or gate_data.pos
            local objects = core.get_objects_inside_radius(pos, 1.5)
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
    description = "Build a complete stargate at your position",
    privs = {give = true},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end

        local pos = vector.round(player:get_pos())
        pos.y = math.floor(pos.y)

        -- Check area is clear
        local blocked = false
        for _, off in ipairs(RING_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            if core.get_node(p).name ~= "air" then
                blocked = true
                break
            end
        end
        for _, off in ipairs(PORTAL_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            if core.get_node(p).name ~= "air" then
                blocked = true
                break
            end
        end

        if blocked then
            return false, "Area not clear — need a 3x5 open space"
        end

        -- Place ring blocks
        for _, off in ipairs(RING_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            core.set_node(p, {name = RING_NODE})
        end

        -- Place base block (triggers on_construct → registration)
        core.set_node(pos, {name = GATE_NODE})

        local address = core.get_meta(pos):get_string("address")
        return true, "Stargate built: " .. address
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

        core.chat_send_player(name, "[nexus] Dialing " .. dest ..
            " from " .. nearest_addr .. "...")

        nexus.gate.establish_link(nearest_addr, dest, name, function(ok, info)
            if ok then
                linked_gates[nearest_addr] = true
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
            core.chat_send_player(name, "[nexus] Wormhole closed.")
            local gate_data = local_gates[nearest_addr]
            if gate_data then
                remove_event_horizon(gate_data.pos)
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

            if is_linked and not was_linked then
                -- Link just appeared — place event horizon
                linked_gates[address] = true
                place_event_horizon(gate_data.pos)
                core.sound_play("nexus_gate_open", {
                    pos = gate_data.center, max_hear_distance = 30, gain = 0.6
                })
            elseif not is_linked and was_linked then
                -- Link just disappeared — remove event horizon
                linked_gates[address] = nil
                remove_event_horizon(gate_data.pos)
                core.sound_play("nexus_gate_close", {
                    pos = gate_data.center, max_hear_distance = 30, gain = 0.6
                })
            end
        end)
    end
end)

-- Cleanup cooldown on leave
core.register_on_leaveplayer(function(player)
    arrival_cooldown[player:get_player_name()] = nil
end)

core.log("action", "[nexus] gate system loaded")
