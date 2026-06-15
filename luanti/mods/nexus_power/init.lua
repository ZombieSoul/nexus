-- nexus_power/init.lua
-- Tiered power system for nexus gates.
--
-- Progression design:
--   T1 generator (Resonite)    → same-world travel is sustainable
--                                interstellar is a struggle, intergalactic impossible
--   T2 generator (Stellarite)  → interstellar becomes manageable
--                                intergalactic requires long charge, can't sustain upkeep
--   T3 generator (Voidium)     → intergalactic becomes sustainable, transitions to content
--
-- All values are configurable.

local modpath = core.get_modpath(core.get_current_modname())
local storage = core.get_mod_storage()

-- =============================================================================
-- Configuration (all configurable via settings)
-- =============================================================================

local S = core.settings

-- Gate capacity — how much power a gate can store
local GATE_CAPACITY = tonumber(S:get("nexus_power.gate_capacity")) or 5000

-- Dial costs — the "punch through" energy to establish a wormhole
local DIAL_COST = {
    [1] = tonumber(S:get("nexus_power.dial_cost_same_world"))   or 50,    -- trivial for T1
    [2] = tonumber(S:get("nexus_power.dial_cost_same_galaxy"))  or 500,   -- needs T2 generator
    [3] = tonumber(S:get("nexus_power.dial_cost_cross_galaxy")) or 5000,  -- needs T2 charged long, or T3
}

-- Upkeep per second while wormhole is open
-- T1 generator can sustain same-world easily
-- T2 generator can sustain interstellar but barely keeps up with intergalactic
-- T3 generator sustains intergalactic comfortably
local UPKEEP_COST = {
    [1] = tonumber(S:get("nexus_power.upkeep_same_world"))   or 2,    -- T1 gen outputs 5/s, sustainable
    [2] = tonumber(S:get("nexus_power.upkeep_same_galaxy"))  or 25,   -- T2 gen outputs 50/s, sustainable
    [3] = tonumber(S:get("nexus_power.upkeep_cross_galaxy")) or 200,  -- T3 gen outputs 300/s, sustainable; T2 can't keep up
}

local UPKEEP_INTERVAL = tonumber(S:get("nexus_power.upkeep_interval")) or 5

-- =============================================================================
-- Ore / Fuel Tiers
-- =============================================================================

local TIERS = {
    {
        name = "resonite",
        display = "Resonite",
        color = "#2a8a8a",
        tier = 1,
        ore_y_min = -64,
        ore_y_max = -16,
        ore_scarcity = 8 * 8 * 8,
        ore_num_ores = 5,
        ore_size = 3,
        power_per_ingot = 100,     -- 1 ingot = 100 power
    },
    {
        name = "stellarite",
        display = "Stellarite",
        color = "#aa5aca",
        tier = 2,
        ore_y_min = -64,
        ore_y_max = -16,
        ore_scarcity = 10 * 10 * 10,
        ore_num_ores = 4,
        ore_size = 3,
        power_per_ingot = 1000,    -- 1 ingot = 1000 power (10x T1)
    },
    {
        name = "voidium",
        display = "Voidium",
        color = "#4a4aaa",
        tier = 3,
        ore_y_min = -64,
        ore_y_max = -16,
        ore_scarcity = 12 * 12 * 12,
        ore_num_ores = 3,
        ore_size = 2,
        power_per_ingot = 10000,   -- 1 ingot = 10000 power (10x T2)
    },
}

-- =============================================================================
-- Generator Tiers
-- =============================================================================

local GENERATORS = {
    {
        name = "generator_t1",
        display = "Resonite Generator",
        node = "nexus_power:generator_t1",
        texture = "nexus_generator.png",
        tier = 1,
        -- Only accepts T1 fuel
        accepts_fuel = {resonite = true},
        -- Transfer rate to gate (power per cycle)
        transfer_rate = 5,         -- 5 power per 2s tick = 2.5/s
        -- Internal buffer
        buffer_capacity = 500,
        -- Fuel burn rate (how often it processes an ingot, in seconds)
        burn_interval = 4,
    },
    {
        name = "generator_t2",
        display = "Stellarite Generator",
        node = "nexus_power:generator_t2",
        texture = "nexus_stellarite_block.png",  -- reuse for now
        tier = 2,
        -- Accepts T1 and T2 fuel
        accepts_fuel = {resonite = true, stellarite = true},
        transfer_rate = 50,        -- 50 power per 2s = 25/s
        buffer_capacity = 5000,
        burn_interval = 3,
    },
    {
        name = "generator_t3",
        display = "Voidium Generator",
        node = "nexus_power:generator_t3",
        texture = "nexus_voidium_block.png",  -- reuse for now
        tier = 3,
        -- Accepts all fuel tiers
        accepts_fuel = {resonite = true, stellarite = true, voidium = true},
        transfer_rate = 300,       -- 300 power per 2s = 150/s
        buffer_capacity = 50000,
        burn_interval = 2,
    },
}

-- =============================================================================
-- Node / Item Registration
-- =============================================================================

for _, t in ipairs(TIERS) do
    -- Ore node
    core.register_node(":nexus_power:" .. t.name .. "_ore", {
        description = t.display .. " Ore",
        tiles = {"nexus_" .. t.name .. "_ore.png"},
        groups = {cracky = 3, pickaxey = 2, building_block = 1, material_stone = 1},
        drop = "nexus_power:" .. t.name,
        sounds = core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {},
        _mcl_silk_touch_drop = true,
    })

    -- Raw ore item
    core.register_craftitem(":nexus_power:" .. t.name, {
        description = "Raw " .. t.display,
        inventory_image = "nexus_" .. t.name .. "_ingot.png",
        groups = {craftitem = 1},
    })

    -- Refined ingot
    core.register_craftitem(":nexus_power:" .. t.name .. "_ingot", {
        description = t.display .. " Ingot",
        inventory_image = "nexus_" .. t.name .. "_ingot.png",
        groups = {craftitem = 1},
    })

    -- Storage block
    core.register_node(":nexus_power:" .. t.name .. "_block", {
        description = t.display .. " Block",
        tiles = {"nexus_" .. t.name .. "_block.png"},
        groups = {cracky = 2, pickaxey = 1, building_block = 1, material_stone = 1},
        sounds = core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {},
    })
end

-- =============================================================================
-- Crafting Recipes
-- =============================================================================

for _, t in ipairs(TIERS) do
    core.register_craft({
        type = "cooking",
        output = "nexus_power:" .. t.name .. "_ingot",
        recipe = "nexus_power:" .. t.name,
        cooktime = 10,
    })
    core.register_craft({
        output = "nexus_power:" .. t.name .. "_block",
        recipe = {
            {"nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot"},
            {"nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot"},
            {"nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot"},
        },
    })
    core.register_craft({
        output = "nexus_power:" .. t.name .. "_ingot 9",
        recipe = {{"nexus_power:" .. t.name .. "_block"}},
    })
end

-- Generator crafting (tiered)
core.register_craft({
    output = "nexus_power:generator_t1",
    recipe = {
        {"mcl_core:iron_ingot", "nexus_power:resonite_ingot", "mcl_core:iron_ingot"},
        {"mcl_core:iron_ingot", "mcl_core:furnace", "mcl_core:iron_ingot"},
        {"mcl_core:iron_ingot", "nexus_power:resonite_block", "mcl_core:iron_ingot"},
    },
})
core.register_craft({
    output = "nexus_power:generator_t2",
    recipe = {
        {"nexus_power:resonite_block", "nexus_power:stellarite_ingot", "nexus_power:resonite_block"},
        {"nexus_power:generator_t1", "nexus_power:stellarite_block", "nexus_power:generator_t1"},
        {"nexus_power:resonite_block", "nexus_power:stellarite_ingot", "nexus_power:resonite_block"},
    },
})
core.register_craft({
    output = "nexus_power:generator_t3",
    recipe = {
        {"nexus_power:stellarite_block", "nexus_power:voidium_ingot", "nexus_power:stellarite_block"},
        {"nexus_power:generator_t2", "nexus_power:voidium_block", "nexus_power:generator_t2"},
        {"nexus_power:stellarite_block", "nexus_power:voidium_ingot", "nexus_power:stellarite_block"},
    },
})

-- =============================================================================
-- Ore Generation
-- =============================================================================

local ore_config = S:get("nexus_power.ores") or "resonite"
local world_ores = {}
for ore in ore_config:gmatch("([%w_]+)") do
    world_ores[ore] = true
end

local function get_stone_types()
    local stones = {}
    if core.registered_nodes["mcl_core:stone"] then
        table.insert(stones, "mcl_core:stone")
    end
    if core.registered_nodes["mcl_deepslate:deepslate"] then
        table.insert(stones, "mcl_deepslate:deepslate")
    end
    if #stones == 0 then
        table.insert(stones, "mapgen_stone")
    end
    return stones
end

local host_rocks = get_stone_types()

for _, t in ipairs(TIERS) do
    if not world_ores[t.name] then
        core.log("action", "[nexus_power] " .. t.display ..
            " ore NOT generated on this world")
    else
        for _, rock in ipairs(host_rocks) do
            core.register_ore({
                ore_type = "scatter",
                name = "nexus_power:" .. t.name .. "_ore_in_" .. rock:gsub(":", "_"),
                ore = "nexus_power:" .. t.name .. "_ore",
                wherein = rock,
                clust_scarcity = t.ore_scarcity,
                clust_num_ores = t.ore_num_ores,
                clust_size = t.ore_size,
                y_min = t.ore_y_min,
                y_max = t.ore_y_max,
            })
        end
        core.log("action", "[nexus_power] " .. t.display ..
            " ore registered in: " .. table.concat(host_rocks, ","))
    end
end

-- =============================================================================
-- Power Storage
-- =============================================================================

local function get_gate_power(gate_address)
    return storage:get_int("power_" .. gate_address)
end

local function set_gate_power(gate_address, amount)
    storage:set_int("power_" .. gate_address, math.max(0, math.floor(amount)))
end

-- =============================================================================
-- Generator Blocks (3 tiers)
-- =============================================================================

local CHARGE_RADIUS = tonumber(S:get("nexus_power.charge_radius")) or 5

local function show_generator_formspec(pos, gen_def)
    local meta = core.get_meta(pos)
    local stored = meta:get_int("stored_power") or 0
    local parts = {
        "formspec_version[4]",
        "size[10,8]",
        "no_prepend[]",
        "bgcolor[#1A1A2A;true]",
        "label[0.5,0.5;" .. gen_def.display .. "]",
        "label[0.5,1.5;Fuel slot:]",
        "listcolors[#222233;#333355;#000000]",
        string.format("list[nodemeta:%d,%d,%d;fuel;2,1.3;1,1;]", pos.x, pos.y, pos.z),
        string.format("label[4,1.5;Buffer: %d / %d]", stored, gen_def.buffer_capacity),
        string.format("label[4,2.0;Transfer rate: %d/cycle]", gen_def.transfer_rate),
        string.format("label[4,2.5;Accepts: %s fuel]", gen_def.tier == 1 and "Resonite" or
            gen_def.tier == 2 and "Resonite/Stellarite" or "All tiers"),
        string.format("list[current_player;main;1,4;8,4;]"),
        string.format("listring[nodemeta:%d,%d,%d;fuel]", pos.x, pos.y, pos.z),
        "listring[current_player;main]",
    }
    return table.concat(parts, "\n")
end

-- Build a lookup: fuel item name → generator tiers that accept it + power value
local fuel_lookup = {}
for _, t in ipairs(TIERS) do
    local ingot_name = "nexus_power:" .. t.name .. "_ingot"
    fuel_lookup[ingot_name] = {power = t.power_per_ingot, min_gen_tier = t.tier}
end

for _, gen in ipairs(GENERATORS) do
    local def = gen  -- capture for closures

    core.register_node(":" .. def.node, {
        description = def.display,
        tiles = {def.texture},
        groups = {cracky = 2, pickaxey = 1, material_stone = 1},
        light_source = 4 + def.tier * 2,
        sounds = core.node_sound_metal_defaults and core.node_sound_metal_defaults()
            or (core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {}),

        on_construct = function(pos)
            local meta = core.get_meta(pos)
            local inv = meta:get_inventory()
            inv:set_size("fuel", 1)
            meta:set_int("stored_power", 0)
            meta:set_string("infotext", def.display .. " (0 power)")
            local timer = core.get_node_timer(pos)
            timer:start(def.burn_interval)
        end,

        on_rightclick = function(pos, node, player, itemstack, pointed_thing)
            core.show_formspec(player:get_player_name(), "nexus_power:generator",
                show_generator_formspec(pos, def))
        end,

        allow_metadata_inventory_put = function(pos, listname, index, stack, player)
            -- Only accept fuel this generator tier can use
            local fuel_info = fuel_lookup[stack:get_name()]
            if fuel_info and fuel_info.min_gen_tier <= def.tier then
                return stack:get_count()
            end
            return 0
        end,

        allow_metadata_inventory_take = function(pos, listname, index, stack, player)
            return stack:get_count()
        end,

        on_timer = function(pos, elapsed)
            local meta = core.get_meta(pos)
            local inv = meta:get_inventory()
            local fuel_stack = inv:get_stack("fuel", 1)
            local stored = meta:get_int("stored_power") or 0

            -- Burn fuel if there's room
            if not fuel_stack:is_empty() and stored < def.buffer_capacity then
                local fuel_info = fuel_lookup[fuel_stack:get_name()]
                if fuel_info and fuel_info.min_gen_tier <= def.tier then
                    stored = stored + fuel_info.power
                    if stored > def.buffer_capacity then
                        stored = def.buffer_capacity
                    end
                    meta:set_int("stored_power", stored)
                    fuel_stack:take_item(1)
                    inv:set_stack("fuel", 1, fuel_stack)
                end
            end

            -- Transfer power to nearby gates
            if stored > 0 then
                for x = -CHARGE_RADIUS, CHARGE_RADIUS do
                    for y = -CHARGE_RADIUS, CHARGE_RADIUS do
                        for z = -CHARGE_RADIUS, CHARGE_RADIUS do
                            local gpos = {x = pos.x + x, y = pos.y + y, z = pos.z + z}
                            local gnode = core.get_node(gpos)
                            if gnode.name == "nexus:gate_base" then
                                local gmeta = core.get_meta(gpos)
                                local gate_addr = gmeta:get_string("address")
                                if gate_addr ~= "" then
                                    local current = get_gate_power(gate_addr)
                                    if current < GATE_CAPACITY and stored > 0 then
                                        local transfer = math.min(
                                            GATE_CAPACITY - current, stored, def.transfer_rate)
                                        set_gate_power(gate_addr, current + transfer)
                                        stored = stored - transfer
                                        meta:set_int("stored_power", stored)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            meta:set_string("infotext", def.display .. " (" .. stored .. " buffer)")
            return true
        end,
    })
end

-- =============================================================================
-- Upkeep: drain power from open wormholes, auto-close when depleted
-- =============================================================================

local upkeep_timer = 0

core.register_globalstep(function(dtime)
    upkeep_timer = upkeep_timer + dtime
    if upkeep_timer < UPKEEP_INTERVAL then return end
    local elapsed = upkeep_timer
    upkeep_timer = 0

    if not nexus.gate then return end

    for addr, data in pairs(nexus.gate.get_local_gates and nexus.gate.get_local_gates() or {}) do
        if nexus.gate.is_dial_origin and nexus.gate.is_dial_origin(addr) then
            local power = get_gate_power(addr)
            local tier = nexus.gate.get_link_tier and nexus.gate.get_link_tier(addr) or 1
            local drain = (UPKEEP_COST[tier] or 1) * elapsed

            if power <= drain then
                set_gate_power(addr, 0)
                nexus.gate.close_link(addr, function()
                    core.log("action", "[nexus_power] gate " .. addr ..
                        " power depleted — wormhole collapsed")
                end)
                if data and data.center then
                    core.chat_send_all("[nexus] Wormhole at " .. addr ..
                        " collapsed — power depleted!")
                    core.sound_play("nexus_gate_close", {
                        pos = data.center, max_hear_distance = 30, gain = 0.8
                    })
                end
            else
                set_gate_power(addr, power - drain)
            end
        end
    end
end)

-- =============================================================================
-- Register as nexus.power Provider
-- =============================================================================

nexus.power.register_provider({
    name = "nexus_power",

    check = function(gate_address, tier)
        local cost = DIAL_COST[tier] or 999
        local available = get_gate_power(gate_address)
        return available >= cost
    end,

    consume = function(gate_address, tier)
        local cost = DIAL_COST[tier] or 999
        local available = get_gate_power(gate_address)
        if available < cost then
            return false
        end
        set_gate_power(gate_address, available - cost)
        return true
    end,
})

-- =============================================================================
-- Chat Commands
-- =============================================================================

core.register_chatcommand("gatepower", {
    params = "",
    description = "Show power stored in the nearest gate",
    privs = {},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end
        local ppos = player:get_pos()
        for x = -3, 3 do
            for y = -2, 6 do
                for z = -3, 3 do
                    local pos = {x = ppos.x + x, y = ppos.y + y, z = ppos.z + z}
                    if core.get_node(pos).name == "nexus:gate_base" then
                        local addr = core.get_meta(pos):get_string("address")
                        local power = get_gate_power(addr)
                        return true, "Gate " .. addr .. " — power: " .. power ..
                            " / " .. GATE_CAPACITY ..
                            "\n  Dial: same-world=" .. DIAL_COST[1] ..
                            " same-galaxy=" .. DIAL_COST[2] ..
                            " cross-galaxy=" .. DIAL_COST[3] ..
                            "\n  Upkeep: same-world=" .. UPKEEP_COST[1] .. "/s" ..
                            " same-galaxy=" .. UPKEEP_COST[2] .. "/s" ..
                            " cross-galaxy=" .. UPKEEP_COST[3] .. "/s"
                    end
                end
            end
        end
        return false, "No gate found nearby"
    end,
})

core.register_chatcommand("givepower", {
    params = "<amount>",
    description = "Give power to the nearest gate (admin/testing)",
    privs = {give = true},
    func = function(name, param)
        local amount = tonumber(param) or 100
        local player = core.get_player_by_name(name)
        if not player then return false end
        local ppos = player:get_pos()
        for x = -3, 3 do
            for y = -2, 6 do
                for z = -3, 3 do
                    local pos = {x = ppos.x + x, y = ppos.y + y, z = ppos.z + z}
                    if core.get_node(pos).name == "nexus:gate_base" then
                        local addr = core.get_meta(pos):get_string("address")
                        local current = get_gate_power(addr)
                        set_gate_power(addr, current + amount)
                        return true, "Added " .. amount .. " power to gate " .. addr ..
                            " (now " .. (current + amount) .. " / " .. GATE_CAPACITY .. ")"
                    end
                end
            end
        end
        return false, "No gate found nearby"
    end,
})

core.log("action", "[nexus_power] loaded — 3 ore tiers, 3 generators, registered as nexus.power provider")
core.log("action", "[nexus_power] dial costs: " .. DIAL_COST[1] .. "/" .. DIAL_COST[2] .. "/" .. DIAL_COST[3])
core.log("action", "[nexus_power] upkeep/s: " .. UPKEEP_COST[1] .. "/" .. UPKEEP_COST[2] .. "/" .. UPKEEP_COST[3])
