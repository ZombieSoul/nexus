-- nexus/init.lua
-- Cross-dimension gate travel system for Luanti.
--
-- With native dimension support, this mod provides gate-to-gate travel
-- between registered dimensions within a single server process. No proxy,
-- no HTTP, no state transfer — just core.change_player_dimension().
--
-- Subsystems:
--   dimensions.lua — register worlds as dimensions at startup
--   serialize.lua  — (kept for item transfer, not player state)
--   power.lua      — power provider interface
--   glyphs.lua     — 12-symbol glyph addressing
--   crystals.lua   — address storage items
--   gates.lua      — gate blocks, dialing, link state

nexus = {}

local modpath = core.get_modpath(core.get_current_modname())

-- =============================================================================
-- World Identity (read from config — which dimension is this mod running on?)
-- =============================================================================

local WORLD_NAME = core.settings:get("nexus.world_name") or "overworld"
local GALAXY_NAME = core.settings:get("nexus.galaxy_name") or "milkyway"
local GALAXY_LABEL = core.settings:get("nexus.galaxy_label") or GALAXY_NAME
local GALAXY_TIER = tonumber(core.settings:get("nexus.galaxy_tier") or "1")
local ALLOW_SAME_WORLD = core.settings:get_bool("nexus.allow_same_world_travel", true)
local REQUIRE_POWER = core.settings:get_bool("nexus.require_power", false)
local HTTP_TIMEOUT = tonumber(core.settings:get("nexus.timeout") or "10")

-- Expose config for submodules
nexus._config = {
    galaxy_name = GALAXY_NAME,
    galaxy_label = GALAXY_LABEL,
    galaxy_tier = GALAXY_TIER,
    world_name = WORLD_NAME,
    allow_same_world = ALLOW_SAME_WORLD,
    require_power = REQUIRE_POWER,
    http_timeout = HTTP_TIMEOUT,
}

-- =============================================================================
-- Load Subsystems
-- =============================================================================

dofile(modpath .. "/serialize.lua")
dofile(modpath .. "/power.lua")
dofile(modpath .. "/glyphs.lua")
dofile(modpath .. "/crystals.lua")
dofile(modpath .. "/dimensions.lua")
dofile(modpath .. "/gates.lua")

-- =============================================================================
-- Gate Travel — dimension-based (replaces HTTP hop)
-- =============================================================================

--- Travel a player to a destination via dimension switch.
--- This replaces the entire proxy hop + state transfer pipeline.
--- With dimensions, it's a single engine call.
--- @param player ObjectRef
--- @param destination string  Dimension name to travel to
--- @param opts? table         { arrival_gate = "earth:g10_20" }
function nexus.travel(player, destination, opts)
    if type(player) == "string" then
        player = core.get_player_by_name(player)
    end
    if not player or not player:is_player() then
        return false, "Invalid player"
    end

    local pname = player:get_player_name()
    opts = opts or {}

    -- Determine arrival position
    local arrival_pos = nil
    if opts.arrival_gate then
        -- Look up the gate's position in the destination dimension
        local gate = nexus.gates[opts.arrival_gate]
        if gate then
            arrival_pos = {
                x = gate.position.x + (gate.arrival_offset.x or 0),
                y = gate.position.y + (gate.arrival_offset.y or 1),
                z = gate.position.z + (gate.arrival_offset.z or -2),
            }
        end
    end

    -- Switch dimension — the engine handles everything:
    -- anti-cheat, block flush, teleport, restream, callbacks
    local ok = core.change_player_dimension(pname, destination, arrival_pos)

    if ok then
        core.log("action", "[nexus] " .. pname .. " traveled to dimension " .. destination)
        return true
    else
        core.log("error", "[nexus] failed to switch " .. pname .. " to " .. destination)
        return false, "Dimension switch failed"
    end
end

-- =============================================================================
-- Chat Commands
-- =============================================================================

-- /travel <dimension> — raw dimension switch for testing/bootstrap
core.register_chatcommand("travel", {
    params = "<dimension>",
    description = "Switch to another dimension (testing)",
    privs = {teleport = true},
    func = function(name, param)
        local destination = param:trim()
        if destination == "" then
            return false, "Usage: /travel <dimension> (e.g. /travel abydos)"
        end
        if destination == WORLD_NAME then
            return false, "You are already in " .. GALAXY_LABEL
        end
        local player = core.get_player_by_name(name)
        if not player then return false, "Player not found" end
        local ok, err = nexus.travel(player, destination)
        if not ok then
            return false, "Travel failed: " .. (err or "unknown error")
        end
        return true
    end,
})

-- =============================================================================
-- Cleanup
-- =============================================================================

core.register_on_leaveplayer(function(player)
    local pname = player:get_player_name()
    -- Submodules handle their own cleanup
    if nexus.crystal then
        -- Crystal module cleans up on leave
    end
end)

-- =============================================================================
-- Startup
-- =============================================================================

core.log("action", "[nexus] initialized — dimension: " .. WORLD_NAME ..
    " (" .. GALAXY_LABEL .. ", tier " .. GALAXY_TIER .. ")")
