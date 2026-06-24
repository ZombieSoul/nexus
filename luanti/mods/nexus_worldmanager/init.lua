-- nexus_worldmanager/init.lua
-- World configuration manager.
--
-- Reads the world identity from server config and applies settings:
-- - Mapgen parameters (terrain, seed, water level)
-- - Ore generation (delegates to nexus_power)
-- - Ruin density (delegates to nexus_worldgen)
-- - Time speed
-- - Hazard effects (heat, toxic fog, etc.)
--
-- The world template is defined in worlds.json (project root). The
-- setup_worlds.sh script generates per-world config files from it.
-- This mod reads the APPLIED settings from the server config and
-- implements the runtime behavior (hazards, time).

local modpath = core.get_modpath(core.get_current_modname())

nexus_worldmanager = {}

-- =============================================================================
-- World Identity (read from server config, set by setup_worlds.sh)
-- =============================================================================

local WORLD_NAME = core.settings:get("nexus.world_name") or "unknown"
local GALAXY_NAME = core.settings:get("nexus.galaxy_name") or "unknown"
local GALAXY_LABEL = core.settings:get("nexus.galaxy_label") or GALAXY_NAME
local GALAXY_TIER = tonumber(core.settings:get("nexus.galaxy_tier") or "0")
local WORLD_DESCRIPTION = core.settings:get("nexus.world_description") or ""
local TIME_SPEED = tonumber(core.settings:get("nexus_worldmanager.time_speed") or "72")
local HAZARDS_RAW = core.settings:get("nexus_worldmanager.hazards") or ""

-- Parse hazards list (comma-separated)
local HAZARDS = {}
for hazard in HAZARDS_RAW:gmatch("([%w_]+)") do
    HAZARDS[#HAZARDS+1] = hazard
end
local HAZARD_SET = {}
for _, h in ipairs(HAZARDS) do HAZARD_SET[h] = true end

-- =============================================================================
-- Apply Time Speed
-- =============================================================================

if TIME_SPEED ~= 72 then
    core.settings:set("time_speed", tostring(TIME_SPEED))
    core.log("action", "[nexus_worldmanager] time_speed set to " .. TIME_SPEED)
end

-- =============================================================================
-- Hazard System
-- =============================================================================
-- Hazards are periodic environmental effects that make a world dangerous.
-- Each hazard has a damage type, interval, and mitigation.

local hazard_definitions = {
    heat = {
        description = "Extreme Heat",
        damage = 1,
        interval = 8,
        message = "The heat is draining you...",
        -- Players in shade or near water take reduced damage
        mitigated_by_shade = true,
    },
    toxic_fog = {
        description = "Toxic Atmosphere",
        damage = 2,
        interval = 6,
        message = "The toxic air burns your lungs...",
        mitigated_by_shade = false,
    },
    cold = {
        description = "Bitter Cold",
        damage = 1,
        interval = 10,
        message = "The freezing cold bites at you...",
        mitigated_by_shade = false,
    },
    radiation = {
        description = "Background Radiation",
        damage = 1,
        interval = 15,
        message = "You feel radiation sickness...",
        mitigated_by_shade = true,
    },
}

-- Apply hazards via a globalstep timer
if #HAZARDS > 0 then
    local hazard_timer = 0
    local HAZARD_CHECK_INTERVAL = 5  -- check every 5 seconds

    core.register_globalstep(function(dtime)
        hazard_timer = hazard_timer + dtime
        if hazard_timer < HAZARD_CHECK_INTERVAL then return end

        for _, hazard_name in ipairs(HAZARDS) do
            local def = hazard_definitions[hazard_name]
            if not def then goto next_hazard end

            -- Check if it's time to apply this hazard
            -- We use a simple modulo check on the accumulated timer
            local elapsed = hazard_timer
            if elapsed >= def.interval then
                hazard_timer = 0  -- reset (simple approach for now)

                for _, player in ipairs(core.get_connected_players()) do
                    local pname = player:get_player_name()
                    local pos = player:get_pos()
                    local hp = player:get_hp()

                    -- Skip if player is dead or in creative/invulnerable
                    local privs = core.check_player_privs(pname, {fly = true})
                    if privs and hp > 0 then
                        goto next_player
                    end

                    -- Check mitigation (shade = block above player)
                    local damage = def.damage
                    if def.mitigated_by_shade then
                        local above = {x = pos.x, y = pos.y + 2, z = pos.z}
                        local node = core.get_node(above)
                        if node.name ~= "air" then
                            local node_def = core.registered_nodes[node.name]
                            if node_def and node_def.walkable then
                                damage = math.floor(damage / 2)
                            end
                        end
                    end

                    -- Skip if no damage (fully mitigated)
                    if damage <= 0 then goto next_player end

                    -- Apply damage
                    player:set_hp(hp - damage, {type = "set_hp", cause = hazard_name})
                    core.chat_send_player(pname, core.colorize("#FF8844", "[" ..
                        def.description .. "] " .. def.message))

                    ::next_player::
                end
            end

            ::next_hazard::
        end
        hazard_timer = 0
    end)

    local hazard_names = {}
    for _, h in ipairs(HAZARDS) do
        local def = hazard_definitions[h]
        if def then
            hazard_names[#hazard_names+1] = def.description
        end
    end
    core.log("action", "[nexus_worldmanager] hazards active: " ..
        table.concat(hazard_names, ", "))
end

-- =============================================================================
-- World Info API
-- =============================================================================

function nexus_worldmanager.get_world_info()
    return {
        name = WORLD_NAME,
        galaxy = GALAXY_NAME,
        galaxy_label = GALAXY_LABEL,
        tier = GALAXY_TIER,
        description = WORLD_DESCRIPTION,
        time_speed = TIME_SPEED,
        hazards = HAZARDS,
    }
end

function nexus_worldmanager.has_hazard(hazard_name)
    return HAZARD_SET[hazard_name] == true
end

-- =============================================================================
-- Chat Commands
-- =============================================================================

core.register_chatcommand("worldinfo", {
    params = "",
    description = "Show information about this world",
    privs = {},
    func = function(name)
        local info = nexus_worldmanager.get_world_info()
        local lines = {
            core.colorize("#00BFFF", "=== World Information ==="),
            "  Name: " .. info.name,
            "  Galaxy: " .. info.galaxy_label .. " (" .. info.galaxy .. ")",
            "  Tier: " .. info.tier,
            "  Description: " .. info.description,
            "  Time Speed: " .. info.time_speed .. " (" ..
                string.format("%.0f", 24 / (info.time_speed / 60)) .. " min day)",
        }
        if #info.hazards > 0 then
            local hazard_strs = {}
            for _, h in ipairs(info.hazards) do
                local def = hazard_definitions[h]
                if def then
                    hazard_strs[#hazard_strs+1] = def.description ..
                        " (" .. def.damage .. " dmg / " .. def.interval .. "s)"
                else
                    hazard_strs[#hazard_strs+1] = h
                end
            end
            lines[#lines+1] = "  " .. core.colorize("#FF4444", "⚠ Hazards: " ..
                table.concat(hazard_strs, ", "))
        else
            lines[#lines+1] = "  Hazards: None"
        end

        -- Show ore availability if nexus_power is loaded
        if nexus_power then
            local ore_config = core.settings:get("nexus_power.ores") or "resonite"
            lines[#lines+1] = "  Ores: " .. ore_config
        end

        return true, table.concat(lines, "\n")
    end,
})

-- /worlds — list all known worlds (from config, not live query)
core.register_chatcommand("worlds", {
    params = "",
    description = "List known worlds in the network",
    privs = {},
    func = function(name)
        -- Query the proxy for registered galaxies
        if not nexus._http then
            return false, "HTTP API not available"
        end
        nexus._http({
            url = (core.settings:get("nexus.proxy_url") or "http://127.0.0.1:8090") ..
                "/nexus/galaxies",
            method = "GET",
            timeout = 5,
        }, function(result)
            if result.code ~= 200 then
                core.chat_send_player(name, "[nexus] Could not query galaxy registry")
                return
            end
            local resp = core.parse_json(result.data)
            if not resp or not resp.galaxies then
                core.chat_send_player(name, "[nexus] No galaxies registered")
                return
            end
            core.chat_send_player(name, core.colorize("#00BFFF", "=== Known Galaxies ==="))
            for _, gal in ipairs(resp.galaxies) do
                local status = gal.available and "●" or "○"
                core.chat_send_player(name, string.format("  %s %s (tier %d) — %s",
                    status, gal.label or gal.name, gal.tier or 0, gal.name))
            end
        end)
        return true
    end,
})

core.log("action", "[nexus_worldmanager] loaded — world: " .. WORLD_NAME ..
    " (" .. GALAXY_LABEL .. ", tier " .. GALAXY_TIER ..
    "), hazards: " .. (#HAZARDS > 0 and table.concat(HAZARDS, ",") or "none"))
