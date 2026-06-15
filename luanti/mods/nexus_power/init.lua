-- nexus_power/init.lua
-- Tiered power system for nexus gates.
--
-- Provides three tiers of ore → ingot → power fuel:
--   Resonite  (T1) — shallow, uncommon  → same-world gate power
--   Stellarite (T2) — deep, rare         → same-galaxy gate power
--   Voidium   (T3) — very deep, very rare → cross-galaxy gate power
--
-- Registers as a nexus.power provider so gates check/consume power.
-- Ore generation uses core.register_ore() — engine-level, works on
-- any Luanti game (host rock auto-detected).

local modpath = core.get_modpath(core.get_current_modname())
local storage = core.get_mod_storage()

-- =============================================================================
-- Configuration
-- =============================================================================

-- Which ores generate on THIS world? Set via nexus_power.ores config.
-- Examples:
--   nexus_power.ores = resonite                  (starting world)
--   nexus_power.ores = resonite,stellarite       (tier 1 destination)
--   nexus_power.ores = resonite,stellarite,voidium (deep/hazardous world)
-- If not set, defaults to resonite only (starting world).
local ore_config = core.settings:get("nexus_power.ores") or "resonite"
local world_ores = {}
for ore in ore_config:gmatch("([%w_]+)") do
    world_ores[ore] = true
end

local TIERS = {
    {
        name = "resonite",
        display = "Resonite",
        color = "#2a8a8a",
        tier = 1,  -- nexus.power.TIER.SAME_WORLD
        -- Ore gen: underground, uncommon (same depth range on all worlds)
        ore_y_min = -64,
        ore_y_max = -16,
        ore_scarcity = 8 * 8 * 8,    -- 1 in 512
        ore_num_ores = 5,
        ore_size = 3,
        -- Power: how much one ingot fuels
        power_per_ingot = 10,
    },
    {
        name = "stellarite",
        display = "Stellarite",
        color = "#aa5aca",
        tier = 2,  -- nexus.power.TIER.SAME_GALAXY
        -- Ore gen: underground, rare (only on tier 1+ destination worlds)
        ore_y_min = -64,
        ore_y_max = -16,
        ore_scarcity = 10 * 10 * 10,  -- 1 in 1000
        ore_num_ores = 4,
        ore_size = 3,
        power_per_ingot = 50,
    },
    {
        name = "voidium",
        display = "Voidium",
        color = "#4a4aaa",
        tier = 3,  -- nexus.power.TIER.CROSS_GALAXY
        -- Ore gen: deep underground, very rare (only on dangerous worlds)
        ore_y_min = -64,
        ore_y_max = -16,
        ore_scarcity = 12 * 12 * 12,  -- 1 in 1728
        ore_num_ores = 3,
        ore_size = 2,
        power_per_ingot = 500,
    },
}

-- Cost per dial, per tier (how much power a trip consumes)
-- Configurable via settings. Defaults: significant / huge / insane.
local DIAL_COST = {
    [1] = tonumber(core.settings:get("nexus_power.dial_cost_same_world")) or 50,
    [2] = tonumber(core.settings:get("nexus_power.dial_cost_same_galaxy")) or 300,
    [3] = tonumber(core.settings:get("nexus_power.dial_cost_cross_galaxy")) or 2000,
}

-- Upkeep per second while wormhole is open, per tier
-- Configurable. Defaults keep a gate open for a few minutes on a full charge.
local UPKEEP_COST = {
    [1] = tonumber(core.settings:get("nexus_power.upkeep_same_world")) or 0.5,   -- 100 power = ~3 min
    [2] = tonumber(core.settings:get("nexus_power.upkeep_same_galaxy")) or 2.0,  -- 100 power = ~50 sec
    [3] = tonumber(core.settings:get("nexus_power.upkeep_cross_galaxy")) or 10.0, -- 100 power = ~10 sec
}

-- How often (seconds) the upkeep drain runs
local UPKEEP_INTERVAL = 5

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
        _mcl_fortune_drop = { -- Mineclonia fortune enchant support
            discrete_uniform = {
                min = 1,
                max = 1,
            },
        },
        _mcl_silk_touch_drop = true,
    })

    -- Raw ore item (what you get from mining)
    core.register_craftitem(":nexus_power:" .. t.name, {
        description = "Raw " .. t.display,
        inventory_image = "nexus_" .. t.name .. "_ingot.png",  -- reuse ingot texture for now
        groups = {craftitem = 1},
    })

    -- Refined ingot
    core.register_craftitem(":nexus_power:" .. t.name .. "_ingot", {
        description = t.display .. " Ingot",
        inventory_image = "nexus_" .. t.name .. "_ingot.png",
        groups = {craftitem = 1},
    })

    -- Storage block (9 ingots)
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

-- Smelting: raw ore → ingot (uses Mineclonia furnace if available, else cooking)
for _, t in ipairs(TIERS) do
    core.register_craft({
        type = "cooking",
        output = "nexus_power:" .. t.name .. "_ingot",
        recipe = "nexus_power:" .. t.name,
        cooktime = 10,
    })
    -- Block = 9 ingots
    core.register_craft({
        output = "nexus_power:" .. t.name .. "_block",
        recipe = {
            {"nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot"},
            {"nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot"},
            {"nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot", "nexus_power:" .. t.name .. "_ingot"},
        },
    })
    -- Ingot from block
    core.register_craft({
        output = "nexus_power:" .. t.name .. "_ingot 9",
        recipe = {{"nexus_power:" .. t.name .. "_block"}},
    })
end

-- =============================================================================
-- Ore Generation (engine-level: core.register_ore)
-- =============================================================================

-- Detect host rock based on what nodes the current game has
local function get_stone_types()
    local stones = {}
    -- Mineclonia uses mcl_core:stone and mcl_deepslate:deepslate
    if core.registered_nodes["mcl_core:stone"] then
        table.insert(stones, "mcl_core:stone")
    end
    if core.registered_nodes["mcl_deepslate:deepslate"] then
        table.insert(stones, "mcl_deepslate:deepslate")
    end
    -- Fallback: mapgen_stone (engine default)
    if #stones == 0 then
        table.insert(stones, "mapgen_stone")
    end
    return stones
end

local host_rocks = get_stone_types()

for _, t in ipairs(TIERS) do
    -- Only register ores that this world is configured for
    if not world_ores[t.name] then
        core.log("action", "[nexus_power] " .. t.display ..
            " ore NOT generated on this world (not in nexus_power.ores)")
    else
        -- Register in each host rock type
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
            " ore registered in: " ..
            table.concat(host_rocks, ",") ..
            " (y " .. t.ore_y_min .. " to " .. t.ore_y_max .. ")")
    end
end

-- =============================================================================
-- Power Storage (per-gate)
-- =============================================================================
-- Gate power is stored in the gate BASE node's metadata.
-- The generator block charges nearby gates.

local CHARGE_RADIUS = 5  -- generator charges gates within this many blocks

-- Get the power stored in a gate
local function get_gate_power(gate_address)
    return storage:get_int("power_" .. gate_address)
end

-- Set the power stored in a gate
local function set_gate_power(gate_address, amount)
    storage:set_int("power_" .. gate_address, amount)
end

-- =============================================================================
-- Generator Block
-- =============================================================================

local GENERATOR_NODE = "nexus_power:generator"

-- Generator formspec
local function show_generator_formspec(pos)
    local meta = core.get_meta(pos)
    local fuel = meta:get_string("fuel_type") or ""
    local stored = meta:get_int("stored_power") or 0

    local formspec = table.concat({
        "formspec_version[4]",
        "size[10,8]",
        "no_prepend[]",
        "bgcolor[#1A1A2A;true]",
        "label[0.5,0.5;Resonance Power Generator]",
        "label[0.5,1.5;Fuel slot:]",
        "listcolors[#222233;#333355;#000000]",
        string.format("list[nodemeta:%d,%d,%d;fuel;2,1.3;1,1;]", pos.x, pos.y, pos.z),
        string.format("label[4,1.7;Stored power: %d]", stored),
        "label[4,2.2;Insert ingots to generate gate power]",
        string.format("list[current_player;main;1,4;8,4;]"),
        string.format("listring[nodemeta:%d,%d,%d;fuel]", pos.x, pos.y, pos.z),
        "listring[current_player;main]",
    }, "\n")
    return formspec
end

core.register_node(GENERATOR_NODE, {
    description = "Resonance Power Generator",
    tiles = {"nexus_generator.png"},
    groups = {cracky = 2, pickaxey = 1, material_stone = 1},
    light_source = 6,
    sounds = core.node_sound_metal_defaults and core.node_sound_metal_defaults()
        or (core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {}),

    on_construct = function(pos)
        local meta = core.get_meta(pos)
        local inv = meta:get_inventory()
        inv:set_size("fuel", 1)
        meta:set_int("stored_power", 0)
        meta:set_string("infotext", "Resonance Power Generator")
        local timer = core.get_node_timer(pos)
        timer:start(3.0)
    end,

    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        core.show_formspec(player:get_player_name(), "nexus_power:generator",
            show_generator_formspec(pos))
    end,

    allow_metadata_inventory_put = function(pos, listname, index, stack, player)
        -- Only accept our ingots as fuel
        for _, t in ipairs(TIERS) do
            if stack:get_name() == "nexus_power:" .. t.name .. "_ingot" then
                return stack:get_count()
            end
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
        local max_store = 1000

        -- If there's fuel and we have storage space, burn it
        if not fuel_stack:is_empty() and stored < max_store then
            local fuel_name = fuel_stack:get_name()
            for _, t in ipairs(TIERS) do
                if fuel_name == "nexus_power:" .. t.name .. "_ingot" then
                    stored = stored + t.power_per_ingot
                    if stored > max_store then stored = max_store end
                    meta:set_int("stored_power", stored)
                    fuel_stack:take_item(1)
                    inv:set_stack("fuel", 1, fuel_stack)
                    break
                end
            end
        end

        -- Distribute power to nearby gates
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
                                local gate_max = 500
                                if current < gate_max and stored > 0 then
                                    local transfer = math.min(gate_max - current, stored, 10)
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

        meta:set_string("infotext", "Resonance Power Generator (" .. stored .. " power)")
        return true  -- keep timer running
    end,
})

-- =============================================================================
-- Upkeep: drain power from open wormholes, auto-close when depleted
-- =============================================================================

-- Track which gates are currently linked and their tier, so we can drain upkeep.
-- This is populated by checking linked_gates from the gates module.
local upkeep_timer = 0

core.register_globalstep(function(dtime)
    upkeep_timer = upkeep_timer + dtime
    if upkeep_timer < UPKEEP_INTERVAL then return end
    local elapsed = upkeep_timer
    upkeep_timer = 0

    -- Check if gates module is loaded
    if not nexus.gate then return end

    -- Iterate local gates that are linked
    for addr, data in pairs(nexus.gate.get_local_gates and nexus.gate.get_local_gates() or {}) do
        -- Only drain if this gate is linked (wormhole open)
        -- We check via the proxy link state
        if nexus.gate.is_linked and nexus.gate.is_linked(addr) then
            local power = get_gate_power(addr)
            -- Determine tier from the active link
            local tier = nexus.gate.get_link_tier and nexus.gate.get_link_tier(addr) or 1
            local drain = (UPKEEP_COST[tier] or 1.0) * elapsed

            if power <= drain then
                -- Power depleted — auto-close the wormhole
                set_gate_power(addr, 0)
                nexus.gate.close_link(addr, function()
                    core.log("action", "[nexus_power] gate " .. addr ..
                        " power depleted — wormhole collapsed")
                end)
                -- Notify nearby players
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
        -- Can this gate afford a trip at this tier?
        local cost = DIAL_COST[tier] or 999
        local available = get_gate_power(gate_address)
        return available >= cost
    end,

    consume = function(gate_address, tier)
        -- Consume power for a trip. Return false if insufficient.
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
        local found = false
        for x = -3, 3 do
            for y = -2, 6 do
                for z = -3, 3 do
                    local pos = {x = ppos.x + x, y = ppos.y + y, z = ppos.z + z}
                    if core.get_node(pos).name == "nexus:gate_base" then
                        local addr = core.get_meta(pos):get_string("address")
                        local power = get_gate_power(addr)
                        local cost1 = DIAL_COST[1] or "?"
                        local cost2 = DIAL_COST[2] or "?"
                        local cost3 = DIAL_COST[3] or "?"
                        local up1 = UPKEEP_COST[1] or "?"
                        local up2 = UPKEEP_COST[2] or "?"
                        local up3 = UPKEEP_COST[3] or "?"
                        return true, "Gate " .. addr .. " — power: " .. power ..
                            "\n  Dial costs:" ..
                            "\n    Same-world: " .. cost1 .. " (upkeep " .. up1 .. "/s)" ..
                            "\n    Same-galaxy: " .. cost2 .. " (upkeep " .. up2 .. "/s)" ..
                            "\n    Cross-galaxy: " .. cost3 .. " (upkeep " .. up3 .. "/s)"
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
                            " (now " .. (current + amount) .. ")"
                    end
                end
            end
        end
        return false, "No gate found nearby"
    end,
})

core.log("action", "[nexus_power] loaded — 3 ore tiers, generator, registered as nexus.power provider")
