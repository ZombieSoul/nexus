-- nexus_worldgen/init.lua
-- World generation for nexus gates.
--
-- Spawns ancient gate ruins during worldgen — players discover gates
-- in ancient stone structures. Ruins are mostly intact (the ancients
-- built to last) with occasional battle damage from ancient wars.
--
-- Ancient gates are very tough — not easily destroyed. If someone
-- manages to destroy one, the stored energy releases explosively
-- (scaled by stored power, multiplied if wormhole is active).
--
-- Crystals with pre-written addresses spawn as loot in ruins, giving
-- players destinations to discover.

local modpath = core.get_modpath(core.get_current_modname())
local storage = core.get_mod_storage()

-- Create the global before anything references it
nexus_worldgen = {}

-- =============================================================================
-- Configuration
-- =============================================================================

local S = core.settings

-- How rare are ancient gate ruins? Lower = more common.
-- This is the average distance between ruins in chunks.
local RUIN_SPACING = tonumber(S:get("nexus_worldgen.ruin_spacing")) or 8

-- Player gate power cost multiplier (convenience tax)
local PLAYER_GATE_MULTIPLIER = tonumber(S:get("nexus_worldgen.player_gate_multiplier")) or 2.0

-- Ancient gate hardness (how resistant to destruction)
local ANCIENT_HARDNESS = tonumber(S:get("nexus_worldgen.ancient_hardness")) or 5  -- 5x tougher than player gates

-- Explosion power per stored energy unit when a gate is destroyed
local EXPLOSION_PER_POWER = tonumber(S:get("nexus_worldgen.explosion_per_power")) or 0.5

-- Minimum explosion radius (even empty gates explode a bit)
local MIN_EXPLOSION_RADIUS = tonumber(S:get("nexus_worldgen.min_explosion_radius")) or 2

-- =============================================================================
-- Ancient Gate Block (very tough version of gate_base)
-- =============================================================================

local ANCIENT_GATE_BASE = "nexus_worldgen:ancient_gate_base"
local ANCIENT_KEYSTONE = "nexus_worldgen:ancient_keystone_off"
local ANCIENT_SPAN = "nexus_worldgen:ancient_span"

-- These nodes are extremely tough — blast resistant and hard to mine
-- They can be destroyed with sustained effort (TNT, many explosions,
-- high-tier tools) but not by casual creeper explosions or random mining.

local ancient_groups = {
    cracky = 1,          -- very hard to mine (needs diamond+ pickaxe)
    oddly_breakable_by_hand = 0,
    explosion_resistant = 1,  -- custom group for blast resistance
    not_in_creative_inventory = 1,
    nexus_ancient = 1,  -- identifies as an ancient gate block
}

-- Reuse existing textures for the ancient variants
core.register_node(ANCIENT_GATE_BASE, {
    description = "Ancient Gate Base",
    tiles = {"nexus_gate_base.png"},
    groups = ancient_groups,
    drop = "",
    light_source = 8,
    sounds = core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {},

    on_construct = function(pos)
        -- Same as player gate_base: register the gate
        -- We need to call the nexus gate registration
        if nexus.gate and nexus.gate.register then
            -- The gates.lua module handles registration via its own
            -- on_construct — but we're a different node. We need to
            -- replicate the registration logic here, marking it as ancient.
            local address = nexus_worldgen.make_ancient_address(pos)
            local meta = core.get_meta(pos)
            meta:set_string("address", address)
            meta:set_string("infotext", "Ancient Stargate: " .. address)
            meta:set_string("ancient", "true")  -- mark as ancient

            -- Crystal slot inventory
            local inv = meta:get_inventory()
            inv:set_size("crystal", 1)

            -- Persist in mod_storage
            storage:set_string("gate_" .. address,
                pos.x .. "," .. pos.y .. "," .. pos.z)

            -- Register with proxy via the gates module's internal function
            nexus_worldgen.register_ancient_gate(pos, address)
        end
    end,

    on_destruct = function(pos)
        -- Energy explosion!
        nexus_worldgen.on_ancient_gate_destroyed(pos)
    end,

    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        -- Reuse the gate formspec from gates.lua
        if nexus._show_gate_formspec then
            nexus._show_gate_formspec(pos, player)
        end
    end,

    allow_metadata_inventory_put = function(pos, listname, index, stack, player)
        if listname == "crystal" and nexus.crystal and nexus.crystal.is_crystal(stack) then
            return 1
        end
        return 0
    end,

    allow_metadata_inventory_take = function(pos, listname, index, stack, player)
        return 1
    end,

    on_metadata_inventory_put = function(pos, listname, index, stack, player)
        if nexus.crystal then nexus.crystal.lock(pos) end
        if nexus._show_gate_formspec then nexus._show_gate_formspec(pos, player) end
    end,

    on_metadata_inventory_take = function(pos, listname, index, stack, player)
        if nexus.crystal then nexus.crystal.lock(pos) end
        if nexus._show_gate_formspec then nexus._show_gate_formspec(pos, player) end
    end,
})

-- Ancient keystones (same visual as regular but tougher)
core.register_node(ANCIENT_KEYSTONE, {
    description = "Ancient Keystone",
    tiles = {"nexus_keystone_off.png"},
    groups = ancient_groups,
    drop = "",
    light_source = 2,
    sounds = core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {},
    on_destruct = function(pos)
        -- Cascade: destroying one ancient block destroys the whole gate
        nexus_worldgen.cascade_destroy(pos)
    end,
})

core.register_node(ANCIENT_SPAN, {
    description = "Ancient Gate Span",
    tiles = {"nexus_span.png"},
    groups = ancient_groups,
    drop = "",
    light_source = 1,
    sounds = core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {},
    on_destruct = function(pos)
        nexus_worldgen.cascade_destroy(pos)
    end,
})

-- Lit ancient keystone variants (same colors as player gates)
if nexus._keystone_colors then
    for _, color in ipairs(nexus._keystone_colors) do
        core.register_node("nexus_worldgen:ancient_keystone_lit_" .. color, {
            description = "Ancient Keystone (" .. color .. ")",
            tiles = {"nexus_keystone_lit_" .. color .. ".png"},
            groups = ancient_groups,
            drop = "",
            light_source = 12,
            sounds = core.node_sound_stone_defaults and core.node_sound_stone_defaults() or {},
            on_destruct = function(pos)
                nexus_worldgen.cascade_destroy(pos)
            end,
        })
    end
end

-- =============================================================================
-- Gate Address Generation
-- =============================================================================

function nexus_worldgen.make_ancient_address(pos)
    -- Ancient gates use the same addressing but with a prefix to distinguish
    local world = nexus._config.world_name or nexus._config.galaxy_name or "unknown"
    local galaxy = nexus._config.galaxy_name or "unknown"
    return galaxy .. ":" .. world .. ":ancient_" .. math.abs(pos.x) .. "_" .. math.abs(pos.z)
end

function nexus_worldgen.register_ancient_gate(pos, address)
    -- Use the proxy registration from gates.lua
    -- We need to expose the internal register function or replicate it
    local center = {x = pos.x, y = pos.y + 3, z = pos.z}
    local arrival = {x = center.x, y = center.y, z = center.z - 2}

    -- Register via the exposed gates API
    if nexus.gate and nexus.gate.register then
        nexus.gate.register({
            address = address,
            label = "Ancient Gate",
            galaxy = nexus._config.galaxy_name,
            world = nexus._config.world_name,
            position = {x = center.x, y = center.y, z = center.z},
            arrival_offset = {x = 0, y = 0, z = -2},
            facing = 0,
            powered = true,
            obstructed = false,
            ancient = true,  -- mark as ancient
        })
    end

    core.log("action", "[nexus_worldgen] ancient gate registered: " .. address ..
        " at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
end

-- =============================================================================
-- Gate Destruction Mechanics
-- =============================================================================

-- Find the ancient gate base near a destroyed block
function nexus_worldgen.find_nearby_gate_base(pos)
    for x = -3, 3 do
        for y = -1, 7 do
            for z = -3, 3 do
                local p = {x = pos.x + x, y = pos.y + y, z = pos.z + z}
                if core.get_node(p).name == ANCIENT_GATE_BASE then
                    return p
                end
            end
        end
    end
    return nil
end

-- Cascade: when one ancient block is destroyed, destroy the whole gate
function nexus_worldgen.cascade_destroy(pos)
    local base_pos = nexus_worldgen.find_nearby_gate_base(pos)
    if not base_pos then return end

    -- Only trigger once — check if the base still exists
    if core.get_node(base_pos).name ~= ANCIENT_GATE_BASE then return end

    -- Remove all ancient keystone/span blocks around the base
    local offsets = {
        {0,6,0},{2,5,0},{-2,5,0},{2,2,0},{-2,2,0},{0,1,0},
        {-1,0,0},{1,0,0},{-3,2,0},{3,2,0},{-3,4,0},{3,4,0},
        {-1,6,0},{1,6,0},
    }
    for _, off in ipairs(offsets) do
        local p = {x = base_pos.x + off[1], y = base_pos.y + off[2], z = base_pos.z + off[3]}
        local node = core.get_node(p)
        if node.name:match("^nexus_worldgen:") then
            core.remove_node(p)
        end
    end
    -- Remove the base (triggers the explosion)
    core.remove_node(base_pos)
end

-- Handle ancient gate destruction — energy explosion!
function nexus_worldgen.on_ancient_gate_destroyed(pos)
    local meta = core.get_meta(pos)
    local address = meta:get_string("address")

    -- Get stored power
    local power = 0
    if nexus_power then
        power = storage:get_int("power_" .. address)
    end

    -- Check if wormhole is active (check link state)
    local wormhole_active = false
    if nexus.gate and nexus.gate.is_linked then
        wormhole_active = nexus.gate.is_linked(address)
    end

    -- Calculate explosion
    local radius = MIN_EXPLOSION_RADIUS + (power * EXPLOSION_PER_POWER / 100)
    if wormhole_active then
        radius = radius * 2  -- wormhole multiplies the explosion
    end
    radius = math.min(radius, 30)  -- cap at 30 blocks

    core.log("action", "[nexus_worldgen] ancient gate " .. address ..
        " DESTROYED — explosion radius " .. math.floor(radius) ..
        " (power: " .. power .. ", wormhole: " .. tostring(wormhole_active) .. ")")

    -- Create explosion
    core.after(0.1, function()
        if core.create_explosion then
            -- Luanti 5.16+ has core.create_explosion
            core.create_explosion(pos, {
                radius = radius,
                damage = radius * 2,
            })
        else
            -- Fallback: remove blocks in radius
            for x = -radius, radius do
                for y = -radius, radius do
                    for z = -radius, radius do
                        local p = {x = pos.x + x, y = pos.y + y, z = pos.z + z}
                        local dist = math.sqrt(x*x + y*y + z*z)
                        if dist <= radius and core.get_node(p).name ~= "air" then
                            local node = core.get_node(p)
                            -- Don't destroy bedrock or other ancient blocks
                            if node.name ~= "mapgen_stone" and
                               not node.name:match("^nexus_worldgen:") then
                                core.remove_node(p)
                            end
                        end
                    end
                end
            end
        end
    end)

    -- If wormhole was active, trigger cascade explosion on the other side
    if wormhole_active and nexus.gate then
        nexus.gate.get_link(address, function(link)
            if link and link.linked and link.remote_address then
                -- Notify the proxy that this gate is gone — the remote end
                -- will also experience an explosion (handled by its own
                -- destruction when the link breaks)
                nexus.gate.close_link(address)
                core.chat_send_all("[nexus] CATASTROPHIC EVENT: Ancient gate " ..
                    address .. " has been destroyed! Wormhole collapse detected!")
                core.chat_send_all("[nexus] Residual energy signature at: (" ..
                    pos.x .. ", " .. pos.y .. ", " .. pos.z .. ")")
            end
        end)
    end

    -- Leave a residual energy crater marker
    core.after(0.5, function()
        local meta2 = core.get_meta(pos)
        meta2:set_string("infotext", "Ancient Gate Ruin — energy signature detected")
        meta2:set_string("nexus_crater", "true")
        meta2:set_string("nexus_crater_power", tostring(power))
        meta2:set_string("nexus_crater_time", tostring(os.time()))
    end)

    -- Unregister from proxy
    if nexus.gate and nexus.gate.unregister then
        nexus.gate.unregister(address)
    end

    -- Clear from mod_storage
    storage:set_string("gate_" .. address, "")
end

-- =============================================================================
-- World Generation — Ancient Gate Ruins
-- =============================================================================

-- Ruin structure: a small stone platform with the gate on top, surrounded
-- by partially collapsed walls. Built programmatically (no schematic needed).

local RUIN_RADIUS = 6  -- ruins are roughly this many blocks from center

-- Stone types for ruin walls (game-agnostic with fallbacks)
local function get_ruin_stone()
    if core.registered_nodes["mcl_core:stonebricks"] then
        return "mcl_core:stonebricks"
    elseif core.registered_nodes["mcl_core:cobblestone"] then
        return "mcl_core:cobblestone"
    else
        return "mapgen_stone"
    end
end

local ruin_stone = get_ruin_stone()

-- Build an ancient gate ruin at the given position
function nexus_worldgen.build_ruin(pos, pr)
    local stone = ruin_stone
    local base_y = pos.y

    -- Build a flat stone platform (the ancient floor)
    for x = -RUIN_RADIUS, RUIN_RADIUS do
        for z = -RUIN_RADIUS, RUIN_RADIUS do
            local p = {x = pos.x + x, y = base_y - 1, z = pos.z + z}
            local dist = math.sqrt(x*x + z*z)
            if dist <= RUIN_RADIUS then
                if core.get_node(p).name == "air" or
                   core.get_item_group(core.get_node(p).name, "solid") > 0 then
                    core.set_node(p, {name = stone})
                end
            end
        end
    end

    -- Build surrounding walls (mostly intact, some battle damage)
    for angle = 0, math.pi * 2, 0.15 do
        local wx = math.floor(pos.x + math.cos(angle) * RUIN_RADIUS)
        local wz = math.floor(pos.z + math.sin(angle) * RUIN_RADIUS)
        -- Wall height: 3-5 blocks, with gaps (battle damage)
        local height = pr:next(3, 5)
        -- 20% chance of a gap (damage)
        if pr:next(1, 100) > 20 then
            for y = 0, height do
                local p = {x = wx, y = base_y + y, z = wz}
                if core.get_node(p).name == "air" then
                    core.set_node(p, {name = stone})
                end
            end
        end
    end

    -- Place the ancient gate (base block first, then keystones/spans)
    local gate_offsets = {
        base = {0, 0, 0},
        keystones = {
            {-2, 1, 0}, {2, 1, 0}, {-3, 3, 0}, {3, 3, 0},
            {-2, 5, 0}, {2, 5, 0}, {0, 6, 0},
        },
        spans = {
            {-1, 0, 0}, {1, 0, 0}, {-3, 2, 0}, {3, 2, 0},
            {-3, 4, 0}, {3, 4, 0}, {-1, 6, 0}, {1, 6, 0},
        },
    }

    -- Place base block (triggers on_construct → registration)
    local base_pos = {x = pos.x, y = base_y, z = pos.z}
    core.set_node(base_pos, {name = ANCIENT_GATE_BASE})

    -- Place keystones
    for _, off in ipairs(gate_offsets.keystones) do
        local p = {x = pos.x + off[1], y = base_y + off[2], z = pos.z + off[3]}
        if core.get_node(p).name == "air" then
            core.set_node(p, {name = ANCIENT_KEYSTONE})
        end
    end

    -- Place spans
    for _, off in ipairs(gate_offsets.spans) do
        local p = {x = pos.x + off[1], y = base_y + off[2], z = pos.z + off[3]}
        if core.get_node(p).name == "air" then
            core.set_node(p, {name = ANCIENT_SPAN})
        end
    end

    -- 30% chance to place a crystal with an address in a chest near the gate
    if pr:next(1, 100) <= 30 then
        nexus_worldgen.place_loot_chest(pos, pr)
    end

    core.log("action", "[nexus_worldgen] ancient gate ruin built at (" ..
        pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
end

-- Place a loot chest with a crystal
function nexus_worldgen.place_loot_chest(gate_pos, pr)
    local chest_pos = {
        x = gate_pos.x + pr:next(-3, 3),
        y = gate_pos.y,
        z = gate_pos.z + pr:next(-3, 3),
    }

    -- Use whatever chest the game has
    local chest_name = "mcl_chests:chest" or "default:chest" or nil
    if not chest_name or not core.registered_nodes[chest_name] then
        -- No chest available — drop the crystal on the ground instead
        local crystal = ItemStack("nexus:resonance_crystal")
        nexus.crystal.save_address(crystal, gate_pos and core.get_meta(gate_pos):get_string("address") or "unknown",
            "Ancient Discovery", pr:next(1, 100) > 50)  -- 50% chance encrypted
        core.add_item(chest_pos, crystal)
        return
    end

    core.set_node(chest_pos, {name = chest_name})
    local meta = core.get_meta(chest_pos)
    local inv = meta:get_inventory()
    inv:set_size("main", 27)

    -- Create a crystal with the gate's address (or a random known gate address)
    local crystal = ItemStack("nexus:resonance_crystal")
    local address = core.get_meta(gate_pos):get_string("address")
    if address ~= "" then
        local encrypted = pr:next(1, 100) > 60  -- 40% chance encrypted
        nexus.crystal.save_address(crystal, address, "Ancient Discovery", encrypted)
        inv:add_item("main", crystal)
    end

    -- Maybe add some ore ingots as bonus loot
    if pr:next(1, 100) <= 50 then
        inv:add_item("main", "nexus_power:resonite_ingot " .. pr:next(1, 5))
    end
end

-- =============================================================================
-- Chunk Generation — spawn ruins at intervals
-- =============================================================================

-- Track which chunks have already been processed to avoid double-spawning
local processed_chunks = {}

core.register_on_generated(function(minp, maxp, seed)
    -- Only generate in the overworld (not too high, not too low)
    if minp.y < -64 or minp.y > 128 then return end

    -- Don't generate ruins near world spawn (avoid interfering with spawn mechanics)
    local dist_from_origin = math.sqrt(minp.x * minp.x + minp.z * minp.z)
    if dist_from_origin < 200 then return end  -- keep 200 blocks clear around spawn

    -- Use chunk coordinates to determine if this chunk should have a ruin
    local chunk_x = math.floor(minp.x / 80)
    local chunk_z = math.floor(minp.z / 80)
    local chunk_key = chunk_x .. "," .. chunk_z

    -- Already processed?
    if processed_chunks[chunk_key] then return end
    processed_chunks[chunk_key] = true

    -- Hash-based spacing: not every chunk gets a ruin
    -- Use a simple hash of coordinates + seed to decide
    local hash = bit.bxor(bit.bxor(chunk_x * 73856093, chunk_z * 19349663), seed)
    local spacing_check = math.abs(hash % RUIN_SPACING)

    if spacing_check ~= 0 then return end  -- only 1 in RUIN_SPACING chunks

    -- Find a suitable surface position in this chunk
    local center_x = math.floor((minp.x + maxp.x) / 2)
    local center_z = math.floor((minp.z + maxp.z) / 2)

    -- Scan downward from surface to find ground level
    local surface_y = nil
    for y = maxp.y, minp.y, -1 do
        local node = core.get_node({x = center_x, y = y, z = center_z})
        if node.name ~= "air" and node.name ~= "ignore" then
            -- Check if it's a solid surface
            local def = core.registered_nodes[node.name]
            if def and def.walkable then
                surface_y = y + 1
                break
            end
        end
    end

    if not surface_y then return end  -- no suitable surface found

    -- Check there's enough air above for the gate (7 blocks tall)
    local clear = true
    for y = surface_y, surface_y + 8 do
        if core.get_node({x = center_x, y = y, z = center_z}).name ~= "air" then
            clear = false
            break
        end
    end
    if not clear then return end

    -- Build the ruin!
    local pos = {x = center_x, y = surface_y, z = center_z}
    local pr = PseudoRandom(math.abs(hash))
    nexus_worldgen.build_ruin(pos, pr)
end)

-- =============================================================================
-- Player Gate Cost Multiplier
-- =============================================================================

-- Hook into the power system: player gates cost more
-- We wrap the existing nexus.power provider to add the multiplier
core.register_on_mods_loaded(function()
    core.after(2, function()
        if not nexus.power or not nexus.power.get_provider then return end
        local original = nexus.power.get_provider()
        if not original or original.name == "nexus_worldgen_wrapped" then return end

        -- Get the gate's ancient status from meta (via proxy)
        local original_check = original.check
        local original_consume = original.consume

        original.check = function(gate_address, tier)
            -- For player gates, the cost check uses multiplied cost
            -- But we don't know if it's ancient here without checking meta
            -- For now, the multiplier is handled in consume only
            return original_check(gate_address, tier)
        end

        original.consume = function(gate_address, tier)
            -- Check if this is an ancient gate
            -- We check mod_storage for ancient flag
            local is_ancient = nexus_worldgen.is_gate_ancient(gate_address)
            if is_ancient then
                return original_consume(gate_address, tier)
            else
                -- Player gate: consume multiplied cost
                local cost_mult = PLAYER_GATE_MULTIPLIER
                -- Temporarily set dial cost higher
                -- This is tricky because the provider's consume uses internal DIAL_COST
                -- For now, call original consume multiple times to simulate multiplier
                -- (This is a simplification — better approach is to expose cost to provider)
                local success = original_consume(gate_address, tier)
                if success and cost_mult > 1 then
                    -- Consume the extra (cost_mult - 1) times more
                    for _ = 1, math.floor(cost_mult - 1) do
                        original_consume(gate_address, tier)
                    end
                end
                return success
            end
        end

        original.name = "nexus_worldgen_wrapped"
        core.log("action", "[nexus_worldgen] player gate cost multiplier: " ..
            PLAYER_GATE_MULTIPLIER .. "x")
    end)
end)

-- Check if a gate address is ancient
function nexus_worldgen.is_gate_ancient(gate_address)
    return storage:get_string("ancient_" .. gate_address) == "true"
end

-- Mark a gate as ancient in storage (called during ruin generation)
-- This needs to be set when the gate is registered
local original_register_ancient = nexus_worldgen.register_ancient_gate
nexus_worldgen.register_ancient_gate = function(pos, address)
    storage:set_string("ancient_" .. address, "true")
    original_register_ancient(pos, address)
end

-- =============================================================================
-- Startup: Re-register ancient gates from storage
-- =============================================================================

core.register_on_mods_loaded(function()
    core.after(5, function()
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
                if pos.x and core.get_node(pos).name == ANCIENT_GATE_BASE then
                    local address = key:sub(5)
                    nexus_worldgen.register_ancient_gate(pos, address)
                    count = count + 1
                end
            end
        end
        if count > 0 then
            core.log("action", "[nexus_worldgen] re-registered " .. count ..
                " ancient gate(s) from storage")
        end
    end)
end)

-- =============================================================================
-- Chat Commands
-- =============================================================================

core.register_chatcommand("spawnruin", {
    params = "",
    description = "Spawn an ancient gate ruin at your position (admin/testing)",
    privs = {give = true},
    func = function(name)
        local player = core.get_player_by_name(name)
        if not player then return false end
        local pos = vector.round(player:get_pos())
        pos.y = math.floor(pos.y)
        local pr = PseudoRandom(os.time())
        nexus_worldgen.build_ruin(pos, pr)
        return true, "Ancient gate ruin spawned at (" ..
            pos.x .. "," .. pos.y .. "," .. pos.z .. ")"
    end,
})

core.register_chatcommand("findruins", {
    params = "",
    description = "List all known ancient gate ruins",
    privs = {},
    func = function(name)
        local keys = storage:to_table().fields
        local found = false
        for key, val in pairs(keys) do
            if key:match("^gate_") and val ~= "" then
                local address = key:sub(5)
                local parts = string.split(val, ",")
                core.chat_send_player(name, "[nexus] Ancient gate: " .. address ..
                    " at (" .. parts[1] .. "," .. parts[2] .. "," .. parts[3] .. ")")
                found = true
            end
        end
        if not found then
            return true, "No ancient gates found on this world."
        end
        return true
    end,
})

core.log("action", "[nexus_worldgen] loaded — ancient gate ruins, loot, destruction mechanics")
