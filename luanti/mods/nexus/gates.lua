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

        -- Use the core travel pipeline with gate info
        nexus.travel(player, link.remote_galaxy, {
            arrival_gate = link.remote_address,
            departure_gate = gate_address,
        })
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

local function register_gate_at(pos)
    local address = make_address(pos)
    local meta = core.get_meta(pos)
    meta:set_string("address", address)
    meta:set_string("infotext", "Stargate: " .. address)

    local_gates[address] = {pos = vector.new(pos)}

    nexus.gate.register({
        address = address,
        label = GALAXY .. " Gate",
        galaxy = GALAXY,
        position = {x = pos.x, y = pos.y, z = pos.z},
        arrival_offset = {x = 0, y = 1, z = -2},  -- 2 blocks in front, 1 up
        facing = 0,
        powered = true,
        obstructed = false,
    })
end

local function unregister_gate_at(pos)
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")
    if address == "" then return end

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

    -- Preserve metadata across rotations etc.
    preserve_metadata = function(pos, oldnode, oldmeta, drops)
        -- If mined (not destroyed), the gate is unregistered in on_destruct
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
            local pos = gate_data.pos
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

        local pos = gate_data.pos
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

            -- Calculate arrival position (gate pos + offset)
            local arrival_pos = vector.add(pos, {x = 0, y = 1, z = 0})

            -- Create the item entity
            local obj = core.add_item(arrival_pos, stack)
            if obj and qi.velocity then
                -- Transform velocity: flip Z so item flies OUT of the gate
                -- (opposite of the throw direction that went INTO the gate)
                obj:set_velocity({
                    x = qi.velocity.x or 0,
                    y = qi.velocity.y or 2,
                    z = -(qi.velocity.z or 0),
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
            local objects = core.get_objects_inside_radius(gate_data.pos, 1.5)
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
                core.chat_send_player(name, "[nexus] Wormhole established! Walk into the gate to travel.")
                local gate_data = local_gates[nearest_addr]
                if gate_data then
                    core.sound_play("nexus_gate_open", {
                        pos = gate_data.pos, max_hear_distance = 30, gain = 0.8
                    })
                end
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
                core.sound_play("nexus_gate_close", {
                    pos = gate_data.pos, max_hear_distance = 30, gain = 0.8
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
local refresh_timer = 0
core.register_globalstep(function(dtime)
    refresh_timer = refresh_timer + dtime
    if refresh_timer < 2.0 then return end  -- every 2 seconds
    refresh_timer = 0

    for address, _ in pairs(local_gates) do
        nexus.gate.get_link(address, function(link)
            if link and link.linked then
                linked_gates[address] = true
            else
                -- Only clear if we didn't establish it locally
                -- (our own outgoing link might show as linked too)
                linked_gates[address] = linked_gates[address] or nil
            end
        end)
    end
end)

-- Cleanup cooldown on leave
core.register_on_leaveplayer(function(player)
    arrival_cooldown[player:get_player_name()] = nil
end)

core.log("action", "[nexus] gate system loaded")
