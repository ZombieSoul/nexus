-- nexus/gates.lua
-- Gate-to-gate travel system using native Luanti dimensions.
--
-- Gates are physical structures (7 keystones + base block). Players dial
-- addresses using glyph sequences or saved crystals. When a link is
-- established, walking through the gate switches the player's dimension.
--
-- Gate links are LOCAL (in-memory) — no proxy, no HTTP, no state transfer.
-- The engine's change_player_dimension handles everything.

local cfg = nexus._config
local GALAXY = cfg.galaxy_name
local WORLD = cfg.world_name or GALAXY
local ALLOW_SAME_WORLD = cfg.allow_same_world ~= false

-- Forward declarations
local start_dialing, cancel_dialing
local compute_dial_sequence, play_dialing_sequence, reset_keystones

nexus.gates = {}
nexus.gate = {}

-- =============================================================================
-- Gate Registry — local in-memory (no proxy)
-- =============================================================================

-- All registered gates: address → {pos, center, arrival, dimension, label}
local local_gates = {}

-- Gate links: address → {remote_address, remote_dimension, remote_pos, tier}
local active_links = {}

-- Gate state: address → "idle" | "dialing" | "connected" | "receiving"
local gate_state = {}

-- Gate power tiers (for upkeep)
local gate_link_tiers = {}

-- Track dialing sequences
local dialing_timers = {}

-- Expose for nexus_power
function nexus.gate.get_local_gates()
    return local_gates
end

function nexus.gate.is_dial_origin(address)
    return gate_state[address] == "connected"
end

function nexus.gate.get_link_tier(address)
    return gate_link_tiers[address] or nexus.power.TIER.SAME_WORLD
end

-- Expose gate registry for nexus.travel
nexus.gates = local_gates

-- =============================================================================
-- Address Conversion Layer
-- =============================================================================

local function address_to_route(addr)
    if not addr then return nil end
    local dim, gate_id = addr:match("^([^:]+):([^:]+)$")
    if dim then
        return { dimension = dim, gate_id = gate_id }
    end
    return nil
end

local function route_to_address(route)
    return route.dimension .. ":" .. route.gate_id
end

local function make_gate_id(pos)
    return "g" .. math.abs(pos.x) .. "_" .. math.abs(pos.z)
end

local function make_route(pos)
    -- The dimension is the CURRENT dimension the player is in
    local dim = core.get_player_by_name("__dimension_lookup__") -- dummy
    -- Actually we need to know the current dimension at gate placement time
    -- Use a different approach: the gate stores its dimension
    return nil -- handled by register_gate_at
end

local function make_address(pos, dimension_name)
    return dimension_name .. ":" .. make_gate_id(pos)
end

-- =============================================================================
-- Gate Structure Geometry
-- =============================================================================

local GATE_NODE = "nexus:gate_base"
local HORIZON_NODE = "nexus:event_horizon"

local KEYSTONE_OFFSETS = {
    {-2, 1, 0},   -- K1 lower-left
    {2,  1, 0},   -- K2 lower-right
    {-3, 3, 0},   -- K3 mid-left
    {3,  3, 0},   -- K4 mid-right
    {-2, 5, 0},   -- K5 upper-left
    {2,  5, 0},   -- K6 upper-right
    {0,  6, 0},   -- K7 top center
}

local SPAN_OFFSETS = {
    {-1, 0, 0}, {1, 0, 0},
    {-3, 2, 0}, {3, 2, 0},
    {-3, 4, 0}, {3, 4, 0},
    {-1, 6, 0}, {1, 6, 0},
}

local PORTAL_OFFSETS = {
    {-1, 1, 0}, {0, 1, 0}, {1, 1, 0},
    {-2, 2, 0}, {-1, 2, 0}, {0, 2, 0}, {1, 2, 0}, {2, 2, 0},
    {-2, 3, 0}, {-1, 3, 0}, {0, 3, 0}, {1, 3, 0}, {2, 3, 0},
    {-2, 4, 0}, {-1, 4, 0}, {0, 4, 0}, {1, 4, 0}, {2, 4, 0},
    {-1, 5, 0}, {0, 5, 0}, {1, 5, 0},
}

local function get_center(base_pos)
    return {x = base_pos.x, y = base_pos.y + 3, z = base_pos.z}
end

local function get_arrival_pos(base_pos)
    local c = get_center(base_pos)
    return {x = c.x, y = c.y, z = c.z - 2}
end

-- =============================================================================
-- Keystone Definitions
-- =============================================================================

local KEYSTONE_COLORS = {
    "red", "orange", "yellow", "green", "cyan", "blue",
    "violet", "magenta", "white", "pink", "lime", "amber",
}
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

local function is_ancient_keystone(name)
    return name and name:match("^nexus_worldgen:")
end

-- =============================================================================
-- Event Horizon
-- =============================================================================

local function remove_event_horizon(base_pos)
    for _, off in ipairs(PORTAL_OFFSETS) do
        local p = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        if core.get_node(p).name == HORIZON_NODE then
            core.remove_node(p)
        end
    end
end

local function place_event_horizon(base_pos)
    for _, off in ipairs(PORTAL_OFFSETS) do
        local p = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        if core.get_node(p).name == "air" then
            core.set_node(p, {name = HORIZON_NODE})
        end
    end
end

core.register_node(HORIZON_NODE, {
    description = "Event Horizon",
    tiles = {{
        name = "nexus_event_horizon_anim.png",
        animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = 3},
    }},
    drawtype = "glasslike",
    paramtype = "light",
    use_texture_alpha = "blend",
    groups = {not_in_creative_inventory = 1, unbreakable = 1},
    light_source = 14,
    walkable = false,
    pointable = false,
    diggable = false,
    drop = "",
    post_effect_color = {a = 80, r = 20, g = 40, b = 120},
})

-- =============================================================================
-- Gate Registration
-- =============================================================================

local storage = core.get_mod_storage()

local function get_dimension_at_pos(pos)
    -- Find which dimension this position is in by checking the player
    -- or use a global that gates.lua sets during registration
    -- Actually, we can store it in node metadata
    return nil -- will be set in on_construct
end

local function register_gate_at(pos, dimension_name)
    if not dimension_name then
        -- Try to get from metadata (for re-registration)
        dimension_name = core.get_meta(pos):get_string("dimension")
        if dimension_name == "" then
            -- Default to the mod's configured world
            dimension_name = WORLD
        end
    end

    local address = make_address(pos, dimension_name)
    local meta = core.get_meta(pos)
    meta:set_string("address", address)
    meta:set_string("dimension", dimension_name)
    meta:set_string("infotext", "Ancient Gate")

    -- Crystal slot
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
        dimension = dimension_name,
    }

    -- Persist in mod_storage
    storage:set_string("gate_" .. address,
        pos.x .. "," .. pos.y .. "," .. pos.z .. "," .. dimension_name)

    core.log("action", "[nexus] gate registered: " .. address ..
        " in dimension " .. dimension_name)
end

local function unregister_gate_at(pos)
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")
    if address == "" then return end

    remove_event_horizon(pos)

    -- Break any active link
    if active_links[address] then
        local remote = active_links[address].remote_address
        active_links[address] = nil
        active_links[remote] = nil
        gate_state[address] = nil
        gate_state[remote] = nil
    end

    local_gates[address] = nil
    storage:set_string("gate_" .. address, "")

    core.log("action", "[nexus] gate destroyed: " .. address)
end

-- =============================================================================
-- Gate Link Management (local — no HTTP)
-- =============================================================================

local function establish_link(from_addr, to_addr, opened_by)
    -- Check destination gate exists
    if not local_gates[to_addr] then
        return false, "No gate at address '" .. to_addr .. "'"
    end

    -- Can't link to self
    if from_addr == to_addr then
        return false, "Gate cannot link to itself"
    end

    -- Check neither gate is already linked
    if active_links[from_addr] then
        return false, "Origin gate already linked"
    end
    if active_links[to_addr] then
        return false, "Destination gate already linked"
    end

    -- Create bidirectional link
    local from_gate = local_gates[from_addr]
    local to_gate = local_gates[to_addr]

    active_links[from_addr] = {
        remote_address = to_addr,
        remote_dimension = to_gate.dimension,
        remote_pos = to_gate.pos,
        remote_arrival = to_gate.arrival,
    }
    active_links[to_addr] = {
        remote_address = from_addr,
        remote_dimension = from_gate.dimension,
        remote_pos = from_gate.pos,
        remote_arrival = from_gate.arrival,
    }

    core.log("action", "[nexus] link established: " .. from_addr .. " <-> " .. to_addr ..
        " (by " .. (opened_by or "?") .. ")")
    return true
end

local function close_link(gate_address)
    if not active_links[gate_address] then return false end

    local remote = active_links[gate_address].remote_address

    -- Close both ends
    active_links[gate_address] = nil
    if remote and active_links[remote] then
        active_links[remote] = nil
    end

    -- Reset states
    gate_state[gate_address] = "idle"
    if remote then gate_state[remote] = "idle" end
    gate_link_tiers[gate_address] = nil
    gate_link_tiers[remote] = nil

    -- Clean up visuals on both gates
    local gate_data = local_gates[gate_address]
    if gate_data then
        remove_event_horizon(gate_data.pos)
        reset_keystones(gate_data.pos)
    end
    if remote and local_gates[remote] then
        local remote_data = local_gates[remote]
        remove_event_horizon(remote_data.pos)
        reset_keystones(remote_data.pos)
    end

    return true
end

-- =============================================================================
-- Dialing Sequence
-- =============================================================================

local function hash_to_symbol(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + string.byte(s, i)) % 12
    end
    return h + 1
end

compute_dial_sequence = function(dest_address, tier)
    local route = address_to_route(dest_address)
    if not route then return {} end
    local symbols = {}

    local dim = route.dimension or "x"
    local gid = route.gate_id or "g0_0"
    local half = math.floor(#gid / 2)

    if tier >= nexus.power.TIER.CROSS_GALAXY then
        symbols[#symbols+1] = hash_to_symbol(dim)
    end
    if tier >= nexus.power.TIER.SAME_GALAXY then
        symbols[#symbols+1] = hash_to_symbol(dim .. "2")
    end
    symbols[#symbols+1] = hash_to_symbol(gid:sub(1, half))
    symbols[#symbols+1] = hash_to_symbol(gid:sub(half + 1))
    if tier >= nexus.power.TIER.SAME_GALAXY then
        symbols[#symbols+1] = hash_to_symbol(dim .. "3")
    end
    if tier >= nexus.power.TIER.CROSS_GALAXY then
        symbols[#symbols+1] = hash_to_symbol(dim .. "4")
    end
    symbols[#symbols+1] = hash_to_symbol(dest_address)
    return symbols
end

play_dialing_sequence = function(base_pos, symbols, tier, on_complete)
    local num_symbols = #symbols
    local per_symbol_time
    if tier == nexus.power.TIER.CROSS_GALAXY then
        per_symbol_time = tonumber(core.settings:get("nexus.dial_time_cross_galaxy")) or 2.0
    elseif tier == nexus.power.TIER.SAME_GALAXY then
        per_symbol_time = tonumber(core.settings:get("nexus.dial_time_same_galaxy")) or 1.5
    else
        per_symbol_time = tonumber(core.settings:get("nexus.dial_time_same_world")) or 1.0
    end

    local function light_keystone(step)
        if step > num_symbols then
            if on_complete then on_complete() end
            return
        end

        local color_idx = symbols[step]
        local color = KEYSTONE_COLORS[color_idx] or "white"
        local ks_idx = ((step - 1) % 7) + 1
        local off = KEYSTONE_OFFSETS[ks_idx]
        local kp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}

        if is_keystone(core.get_node(kp).name) or is_ancient_keystone(core.get_node(kp).name) then
            core.swap_node(kp, {name = keystone_lit_name(color)})
        end

        core.add_particlespawner({
            amount = 15, time = 0.5,
            minpos = {x = kp.x - 0.3, y = kp.y - 0.3, z = kp.z - 0.3},
            maxpos = {x = kp.x + 0.3, y = kp.y + 0.3, z = kp.z + 0.3},
            minvel = {x = -1, y = 1, z = -1},
            maxvel = {x = 1, y = 3, z = 1},
            minexptime = 0.5, maxexptime = 1.0,
            minsize = 1, maxsize = 3,
            texture = "nexus_keystone_lit_" .. color .. ".png",
            glow = 14,
        })

        core.sound_play("nexus_gate_dial", {
            pos = kp, max_hear_distance = 20, gain = 0.5,
            pitch = 0.8 + (step / num_symbols) * 0.5,
        })

        local timer = core.after(per_symbol_time, function()
            light_keystone(step + 1)
        end)
    end

    -- Reset keystones
    reset_keystones(base_pos)
    light_keystone(1)
end

reset_keystones = function(base_pos)
    for _, off in ipairs(KEYSTONE_OFFSETS) do
        local kp = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        if is_keystone(core.get_node(kp).name) then
            core.swap_node(kp, {name = KEYSTONE_OFF})
        end
    end
end

-- =============================================================================
-- Unified Dialing Flow
-- =============================================================================

start_dialing = function(pos, player, gate_address, dest_address)
    local pname = player:get_player_name()

    local state = gate_state[gate_address] or "idle"
    if state == "dialing" then
        core.chat_send_player(pname, "[nexus] Gate is already dialing")
        return
    end
    if state == "connected" then
        core.chat_send_player(pname, "[nexus] Gate is already linked — close the wormhole first")
        return
    end
    if state == "receiving" then
        core.chat_send_player(pname, "[nexus] This gate has an active wormhole — close it first")
        return
    end

    -- Power check
    local route = address_to_route(dest_address)
    local dest_dim = route and route.dimension or ""
    local my_dim = core.get_meta(pos):get_string("dimension")
    if my_dim == "" then my_dim = WORLD end

    local tier, tier_label = nexus.power.tier_for(
        GALAXY, my_dim, GALAXY, dest_dim)
    local can_afford, perr = nexus.power.check(gate_address, tier)
    if not can_afford then
        core.chat_send_player(pname, "[nexus] " .. perr)
        core.sound_play("nexus_gate_abort", {to_player = pname})
        return
    end

    -- Start visual sequence
    local glyph_indices = compute_dial_sequence(dest_address, tier)
    local glyph_display = nexus.glyphs.get_colored_symbols(glyph_indices)
    gate_state[gate_address] = "dialing"

    core.chat_send_player(pname, "[nexus] Dialing " .. glyph_display ..
        " — " .. #glyph_indices .. " symbols (" .. tier_label .. ")...")

    play_dialing_sequence(pos, glyph_indices, tier, function()
        if gate_state[gate_address] ~= "dialing" then return end

        -- Try to establish link
        local ok, err = establish_link(gate_address, dest_address, pname)

        if ok then
            gate_state[gate_address] = "connected"
            gate_link_tiers[gate_address] = tier
            nexus.power.consume(gate_address, tier)
            gate_state[dest_address] = "receiving"
            place_event_horizon(pos)
            local remote_gate = local_gates[dest_address]
            if remote_gate then
                place_event_horizon(remote_gate.pos)
            end
            core.chat_send_player(pname, "[nexus] Wormhole established!")
            core.sound_play("nexus_gate_open", {
                pos = pos, max_hear_distance = 30, gain = 0.8
            })
        else
            gate_state[gate_address] = "idle"
            reset_keystones(pos)
            core.chat_send_player(pname, "[nexus] Dialing failed: " .. err)
            core.sound_play("nexus_gate_abort", {to_player = pname})
        end
    end)
end

cancel_dialing = function(pos, player)
    local address = core.get_meta(pos):get_string("address")
    if gate_state[address] == "dialing" then
        gate_state[address] = "idle"
        reset_keystones(pos)
        core.chat_send_player(player:get_player_name(), "[nexus] Dialing cancelled.")
        core.sound_play("nexus_gate_abort", {
            pos = pos, max_hear_distance = 20, gain = 0.5
        })
        return true
    end
    return false
end

-- =============================================================================
-- Gate Formspec
-- =============================================================================

local function show_gate_formspec(pos, player)
    local pname = player:get_player_name()
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")
    local state = gate_state[address] or "idle"

    local status_text = "○ IDLE"
    local status_color = "#7A7A7A"
    if state == "connected" then
        status_text = "● LINKED (origin)"
        status_color = "#2BA830"
    elseif state == "receiving" then
        status_text = "● LINKED (incoming)"
        status_color = "#2BA830"
    elseif state == "dialing" then
        status_text = "● DIALING..."
        status_color = "#FFAA00"
    end

    local function islot(x, y, w, h)
        if mcl_formspec and mcl_formspec.get_itemslot_bg_v4 then
            return mcl_formspec.get_itemslot_bg_v4(x, y, w, h)
        end
        return ""
    end

    -- Compute glyph sequence for this gate
    local route = address_to_route(address)
    local my_dim = meta:get_string("dimension")
    if my_dim == "" then my_dim = WORLD end
    local tier = nexus.power.tier_for(GALAXY, my_dim, GALAXY, my_dim)
    local glyph_indices = compute_dial_sequence(address, tier)
    local glyph_display = nexus.glyphs.get_colored_symbols(glyph_indices)

    local parts = {
        "formspec_version[4]",
        "size[12,18.5]",
        string.format("label[1,0.4;%s]", core.colorize("#00BFFF", "Ancient Gate")),
        string.format("label[1,0.9;%s]", glyph_display),
        "label[4.8,1.3;" .. core.colorize(status_color, status_text) .. "]",
        -- Crystal section
        "label[0.4,1.9;Crystal]",
        islot(0.6, 2.1, 1, 1),
        string.format("list[nodemeta:%d,%d,%d;crystal;0.6,2.1;1,1;]", pos.x, pos.y, pos.z),
        "label[1.9,2.3;Insert a resonance crystal to load saved addresses]",
    }

    -- Crystal addresses
    local crystal = nexus.crystal.get_gate_crystal(pos)
    if crystal and nexus.crystal.is_gate_unlocked(pos) then
        local addrs = nexus.crystal.get_gate_addresses(pos)
        local btn_y = 3.5
        local addr_idx = 0
        local addr_map = {}
        for addr, entry in pairs(addrs) do
            addr_idx = addr_idx + 1
            addr_map[addr_idx] = addr
            local safe_label = core.formspec_escape(entry.label)
            parts[#parts+1] = string.format(
                "button[0.4,%f;11,0.7;addrbtn_%d;%s]",
                btn_y, addr_idx, safe_label)
            btn_y = btn_y + 0.8
        end
        local pmeta = player:get_meta()
        pmeta:set_string("nexus_addr_map", core.write_json(addr_map))
    end

    -- Manual dial
    parts[#parts+1] = "label[0.4,7.2;Manual Dial (type symbol numbers: 1-12)"
    parts[#parts+1] = "field[0.4,7.9;7.5,0.9;dest;Symbol sequence (e.g. 1,5,3,8);]"
    parts[#parts+1] = "button[0.4,8.9;3.5,0.8;dial;Dial]"
    parts[#parts+1] = "button[4.1,8.9;3.5,0.8;clear_dial;Clear]"
    parts[#parts+1] = "button[7.8,8.9;3.5,0.8;close;Close Link]"

    -- Glyph dial pad
    parts[#parts+1] = "label[0.4,9.7;Symbols]"
    local all_glyphs = nexus.glyphs.get_all()
    for i, g in ipairs(all_glyphs) do
        local col = (i - 1) % 4
        local row = math.floor((i - 1) / 4)
        local bx = 0.4 + col * 1.3
        local by = 10.0 + row * 1.0
        parts[#parts+1] = string.format(
            "image_button[%f,%f;1,1;nexus_glyph_off_%s.png;glyph_%d;%s]",
            bx, by, g.name, i, g.symbol)
    end

    -- Inventory
    parts[#parts+1] = "label[0.4,13.5;Inventory]"
    parts[#parts+1] = islot(1, 13.9, 8, 4)
    parts[#parts+1] = "list[current_player;main;1,13.9;8,4;]"
    parts[#parts+1] = string.format("listring[nodemeta:%d,%d,%d;crystal]", pos.x, pos.y, pos.z)
    parts[#parts+1] = "listring[current_player;main]"

    -- Store position
    local pmeta = player:get_meta()
    pmeta:set_string("nexus_gate_pos", pos.x .. "," .. pos.y .. "," .. pos.z)

    core.show_formspec(pname, "nexus:gate_dial", table.concat(parts, "\n"))
end

nexus._show_gate_formspec = show_gate_formspec

-- =============================================================================
-- Formspec Handler
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

    -- Clear button
    if fields.clear_dial then
        cancel_dialing(pos, player)
        pmeta:set_string("nexus_dial_seq", "")
        show_gate_formspec(pos, player)
        return true
    end

    -- Glyph pad clicks
    local glyph_sequence = pmeta:get_string("nexus_dial_seq") or ""
    for field_name in pairs(fields) do
        local glyph_idx = field_name:match("^glyph_(%d+)$")
        if glyph_idx then
            if #glyph_sequence < 14 then
                if glyph_sequence ~= "" then glyph_sequence = glyph_sequence .. "," end
                glyph_sequence = glyph_sequence .. glyph_idx
                pmeta:set_string("nexus_dial_seq", glyph_sequence)
                core.sound_play("nexus_gate_dial", {
                    pos = pos, max_hear_distance = 20, gain = 0.3,
                    pitch = 0.8 + (tonumber(glyph_idx) / 12) * 0.4,
                })
            end
            show_gate_formspec(pos, player)
            return true
        end
    end

    -- Crystal address button clicks
    local dial_addr = nil
    for field_name in pairs(fields) do
        local clicked_idx = field_name:match("^addrbtn_(%d+)$")
        if clicked_idx then
            local addr_map_str = pmeta:get_string("nexus_addr_map")
            if addr_map_str ~= "" then
                local addr_map = core.parse_json(addr_map_str)
                dial_addr = addr_map and addr_map[tonumber(clicked_idx)]
                if dial_addr then break end
            end
        end
    end

    -- Dial button
    if dial_addr or fields.dial then
        local dest = dial_addr

        -- If no crystal address, check for manual symbol entry
        if not dest and (fields.dest or ""):trim() ~= "" then
            local typed = (fields.dest):trim()
            -- Parse comma-separated numbers into glyph indices
            local indices = {}
            for num in typed:gmatch("(%d+)") do
                indices[#indices+1] = tonumber(num)
            end
            if #indices > 0 then
                -- Convert glyphs to a destination gate address
                dest = nil
                for addr, data in pairs(local_gates) do
                    local route = address_to_route(addr)
                    if route then
                        local tier = nexus.power.tier_for(GALAXY, data.dimension, GALAXY, data.dimension)
                        local gate_glyphs = compute_dial_sequence(addr, tier)
                        if #gate_glyphs == #indices then
                            local match = true
                            for i, idx in ipairs(indices) do
                                if gate_glyphs[i] ~= idx then
                                    match = false
                                    break
                                end
                            end
                            if match then
                                dest = addr
                                break
                            end
                        end
                    end
                end
                if not dest then
                    core.chat_send_player(pname, "[nexus] No gate found for that symbol sequence")
                    core.sound_play("nexus_gate_abort", {to_player = pname})
                    return true
                end
            end
        end

        if not dest then
            core.chat_send_player(pname, "[nexus] Enter symbols or insert a crystal")
            return true
        end
        start_dialing(pos, player, address, dest)
        return true

    elseif fields.close then
        if cancel_dialing(pos, player) then return true end
        close_link(address)
        core.chat_send_player(pname, "[nexus] Wormhole closed.")
        return true
    end

    return true
end)

-- =============================================================================
-- Pad Trigger — walk through gate to travel
-- =============================================================================

local pad_timer = 0
core.register_globalstep(function(dtime)
    pad_timer = pad_timer + dtime
    if pad_timer < 0.3 then return end
    pad_timer = 0

    for address, gate_data in pairs(local_gates) do
        if gate_state[address] == "connected" or gate_state[address] == "receiving" then
            local trigger_pos = vector.new(gate_data.pos)
            trigger_pos.y = trigger_pos.y + 1
            local objects = core.get_objects_inside_radius(trigger_pos, 1.5)
            for _, obj in ipairs(objects) do
                if obj:is_player() then
                    local link = active_links[address]
                    if link then
                        -- Travel via dimension switch!
                        core.change_player_dimension(obj:get_player_name(),
                            link.remote_dimension, link.remote_arrival)
                    end
                end
            end
        end
    end
end)

-- =============================================================================
-- Gate Block Registration
-- =============================================================================

core.register_node(GATE_NODE, {
    description = "Stargate Base",
    tiles = {"nexus_gate_block.png", "nexus_gate_block.png", "nexus_gate_base.png",
             "nexus_gate_base.png", "nexus_gate_base.png", "nexus_gate_base.png"},
    groups = {cracky = 3, oddly_breakable_by_hand = 2},
    light_source = 8,

    on_construct = function(pos)
        -- Determine which dimension we're in
        -- For now, use the world name from config
        register_gate_at(pos, WORLD)
    end,

    on_destruct = function(pos)
        -- Drop crystal
        local meta = core.get_meta(pos)
        local inv = meta:get_inventory()
        if inv:get_list("crystal") then
            local crystal = inv:get_stack("crystal", 1)
            if not crystal:is_empty() then
                core.add_item(pos, crystal)
            end
        end
        unregister_gate_at(pos)
    end,

    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        show_gate_formspec(pos, player)
    end,

    allow_metadata_inventory_put = function(pos, listname, index, stack, player)
        if listname == "crystal" and nexus.crystal and nexus.crystal.is_crystal(stack) then
            return 1
        end
        return 0
    end,

    allow_metadata_inventory_take = function(pos, listname, index, stack, player)
        return stack:get_count()
    end,

    on_metadata_inventory_put = function(pos, listname, index, stack, player)
        if nexus.crystal then nexus.crystal.lock(pos) end
        show_gate_formspec(pos, player)
    end,

    on_metadata_inventory_take = function(pos, listname, index, stack, player)
        if nexus.crystal then nexus.crystal.lock(pos) end
        show_gate_formspec(pos, player)
    end,
})

-- Keystone nodes
core.register_node(KEYSTONE_OFF, {
    description = "Gate Keystone",
    tiles = {"nexus_keystone_off.png"},
    groups = {cracky = 3, not_in_creative_inventory = 1},
    light_source = 2,
    drop = "",
})

for _, color in ipairs(KEYSTONE_COLORS) do
    core.register_node(keystone_lit_name(color), {
        description = "Gate Keystone (" .. color .. ")",
        tiles = {"nexus_keystone_lit_" .. color .. ".png"},
        groups = {cracky = 3, not_in_creative_inventory = 1},
        light_source = 12,
        drop = "",
    })
end

-- Span blocks
core.register_node("nexus:gate_span", {
    description = "Gate Span",
    tiles = {"nexus_span.png"},
    groups = {cracky = 3, not_in_creative_inventory = 1},
    light_source = 1,
    drop = "",
})

-- Re-register gates from storage on restart
local function reregister_gates()
    local keys = storage:to_table().fields
    local count = 0
    for key, val in pairs(keys) do
        if key:match("^gate_") and val ~= "" then
            local parts = string.split(val, ",")
            local pos = {x = tonumber(parts[1]), y = tonumber(parts[2]), z = tonumber(parts[3])}
            local dim = parts[4] or WORLD
            if pos.x then
                register_gate_at(pos, dim)
                count = count + 1
            end
        end
    end
    if count > 0 then
        core.log("action", "[nexus] re-registered " .. count .. " gate(s) from storage")
    end
end

core.register_on_mods_loaded(function()
    core.after(2, reregister_gates)
end)

-- =============================================================================
-- Chat Commands
-- =============================================================================

core.register_chatcommand("placegate", {
    params = "",
    description = "Build a complete stargate at your position",
    privs = {give = true},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end
        local pos = vector.round(player:get_pos())
        pos.y = math.floor(pos.y)

        for _, off in ipairs(KEYSTONE_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            if core.get_node(p).name ~= "air" then
                return false, "Area not clear"
            end
        end

        for _, off in ipairs(KEYSTONE_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            core.set_node(p, {name = KEYSTONE_OFF})
        end
        for _, off in ipairs(SPAN_OFFSETS) do
            local p = {x = pos.x + off[1], y = pos.y + off[2], z = pos.z + off[3]}
            core.set_node(p, {name = "nexus:gate_span"})
        end

        core.set_node(pos, {name = GATE_NODE})
        local address = core.get_meta(pos):get_string("address")
        local route = address_to_route(address)
        local tier = nexus.power.tier_for(GALAXY, WORLD, GALAXY, WORLD)
        local glyphs = compute_dial_sequence(address, tier)
        local symbols = nexus.glyphs.get_colored_symbols(glyphs)
        return true, "Gate built! Your symbols: " .. symbols
    end,
})

core.register_chatcommand("removegate", {
    params = "",
    description = "Remove the nearest stargate",
    privs = {give = true},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end
        local ppos = player:get_pos()
        for addr, data in pairs(local_gates) do
            local dist = vector.distance(ppos, data.pos)
            if dist < 10 then
                -- Remove all gate blocks
                for _, off in ipairs(KEYSTONE_OFFSETS) do
                    local p = {x = data.pos.x + off[1], y = data.pos.y + off[2], z = data.pos.z + off[3]}
                    core.remove_node(p)
                end
                for _, off in ipairs(SPAN_OFFSETS) do
                    local p = {x = data.pos.x + off[1], y = data.pos.y + off[2], z = data.pos.z + off[3]}
                    core.remove_node(p)
                end
                remove_event_horizon(data.pos)
                core.remove_node(data.pos)
                return true, "Stargate removed: " .. addr
            end
        end
        return false, "No gate found nearby"
    end,
})

core.register_chatcommand("gates", {
    params = "",
    description = "List all gates and their symbols",
    privs = {},
    func = function(name)
        if next(local_gates) == nil then
            return true, "No gates registered."
        end
        local lines = {"Gates:"}
        for addr, data in pairs(local_gates) do
            local state = gate_state[addr] or "idle"
            local linked = active_links[addr] and " [LINKED]" or ""
            local tier = nexus.power.tier_for(GALAXY, data.dimension, GALAXY, data.dimension)
            local glyphs = compute_dial_sequence(addr, tier)
            local symbols = nexus.glyphs.get_colored_symbols(glyphs)
            table.insert(lines, symbols .. "  [" .. data.dimension .. "]" .. linked)
        end
        return true, table.concat(lines, "\n")
    end,
})

core.register_chatcommand("closegate", {
    params = "",
    description = "Close the nearest gate's wormhole",
    privs = {},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end
        local ppos = player:get_pos()
        for addr, data in pairs(local_gates) do
            if vector.distance(ppos, data.pos) < 10 then
                close_link(addr)
                return true, "Wormhole closed."
            end
        end
        return false, "No gate found nearby"
    end,
})

core.log("action", "[nexus] gate system loaded — dimension-based travel")
