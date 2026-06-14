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

        if link.remote_galaxy == GALAXY then
            -- SAME GALAXY: instant local teleport, no hop needed.
            -- The player stays on this server; we just move them to the
            -- destination gate. No state capture, no loading screen.
            nexus.gate.get_info(link.remote_address, function(info)
                if not info or not info.gate then
                    core.chat_send_player(pname,
                        "[nexus] Destination gate lost.")
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
                -- Set arrival cooldown so they don't bounce back immediately
                arrival_cooldown[pname] = (core.get_us_time() / 1000000) + 3.0
                core.log("action", "[nexus] " .. pname ..
                    " teleported locally to " .. link.remote_address)
            end)
        else
            -- CROSS GALAXY: full proxy hop + state sync pipeline
            nexus.travel(player, link.remote_galaxy, {
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

    local center = get_center(pos)
    local arrival = get_arrival_pos(pos)

    local_gates[address] = {
        pos = vector.new(pos),
        center = vector.new(center),
        arrival = vector.new(arrival),
    }

    nexus.gate.register({
        address = address,
        label = GALAXY .. " Gate",
        galaxy = GALAXY,
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
    local status_color = linked and "#00FF00" or "#888888"

    local formspec = table.concat({
        "formspec_version[4]",
        "size[8,6]",
        "no_prepend[]",
        "bgcolor[#0A0A2A;true]",
        "hypertext[0.5,0.5;7,1;addr;<global halign=center><style color=#00BFFF size=18>" ..
            "Stargate: " .. core.formspec_escape(address) .. "</style>]",
        "hypertext[0.5,1.3;7,0.6;status;<global halign=center><style color=" ..
            status_color .. " size=14>" .. status .. "</style>]",
        "field[1,2.3;6,0.8;dest;Destination Address;]",
        "button[1,3.3;3,0.8;dial;Dial]",
        "button[4.5,3.3;3,0.8;close;Close Link]",
        "hypertext[0.5,4.5;7,1;hint;<global halign=center><style color=#666666 size=12>" ..
            "Walk through the gate to travel when linked</style>]",
    })

    -- Store position in player meta so the formspec handler knows which gate
    local pmeta = player:get_meta()
    pmeta:set_string("nexus_gate_pos",
        pos.x .. "," .. pos.y .. "," .. pos.z)

    core.show_formspec(pname, "nexus:gate_dial", formspec)
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
    end,

    on_destruct = function(pos)
        unregister_gate_at(pos)
    end,

    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
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
