-- nexus/dimensions.lua
-- Dimension registration for the nexus gate system.
--
-- Each "world" from worlds.json becomes a registered dimension within
-- a single server process. The mod reads world definitions from a
-- JSON config file and registers them at startup.

nexus.dimensions = {}

local function load_worlds_config()
    local worldpath = core.get_worldpath()
    local config_path = worldpath .. "/worlds.json"
    local file = io.open(config_path, "r")
    if not file then
        core.log("warning", "[nexus] worlds.json not found — using defaults")
        return nil
    end
    local data = file:read("*a")
    file:close()
    return core.parse_json(data)
end

-- =============================================================================
-- Register Dimensions at Startup
-- =============================================================================

core.register_on_mods_loaded(function()
    local config = load_worlds_config()
    if not config or not config.worlds then
        core.log("warning", "[nexus] no world definitions found")
        return
    end

    for name, world in pairs(config.worlds) do
        -- Skip the void lobby — it doesn't exist in the dimension model
        if name ~= "void" then
            -- Check if this dimension is already registered (via world.mt)
            local existing = core.get_dimension_def(name)
            if not existing then
                -- Register via Lua API
                local mapgen = world.mapgen and world.mapgen.terrain or "v7"
                local seed = world.mapgen and world.mapgen.seed or nil

                core.register_dimension(name, {
                    mapgen = mapgen ~= "singlenode" and mapgen or "v7",
                    seed = seed,
                    settings = {
                        water_level = world.mapgen and world.mapgen.water_level or 1,
                    },
                })
                core.log("action", "[nexus] registered dimension: " .. name ..
                    " (" .. (world.description or "") .. ")")
            end

            -- Store world info for gate routing
            nexus.dimensions[name] = {
                galaxy = world.galaxy,
                galaxy_label = world.galaxy_label,
                tier = world.tier,
                description = world.description,
                ores = world.ores or {},
                hazards = world.hazards or {},
                time_speed = world.time_speed or 72,
            }
        end
    end

    -- Log what we have
    local count = 0
    for _ in pairs(nexus.dimensions) do count = count + 1 end
    core.log("action", "[nexus] " .. count .. " dimensions configured")
end)

-- =============================================================================
-- Per-Dimension Configuration
-- =============================================================================

-- Apply per-dimension time speed, sky, hazards
core.register_on_enter_dimension(function(player, dim_name)
    local pname = player:get_player_name()
    local world = nexus.dimensions[dim_name]

    if world then
        -- Set time speed for this dimension
        if world.time_speed and world.time_speed ~= 72 then
            -- Time speed is set differently per dimension
            -- set_dimension_time takes (dimension_name, time_value, time_speed)
            -- For now, just set the time to a reasonable value
        end

        -- Hazards
        if world.hazards then
            for _, hazard in ipairs(world.hazards) do
                if hazard == "heat" then
                    -- Heat damage handled by nexus_worldmanager
                elseif hazard == "toxic_fog" then
                    -- Toxic fog handled by nexus_worldmanager
                end
            end
        end

        core.chat_send_player(pname, core.colorize("#00BFFF",
            "Entering " .. (world.description or dim_name) .. "..."))
    end
end)

core.register_on_leave_dimension(function(player, dim_name)
    core.log("action", "[nexus] " .. player:get_player_name() ..
        " left dimension: " .. dim_name)
end)

-- =============================================================================
-- Utility API
-- =============================================================================

--- Get info about a dimension
function nexus.dimensions.get_info(dim_name)
    return nexus.dimensions[dim_name]
end

--- List all registered nexus dimensions
function nexus.dimensions.list()
    local result = {}
    for name, info in pairs(nexus.dimensions) do
        if type(info) == "table" and info.galaxy then
            result[name] = info
        end
    end
    return result
end

--- Check if a dimension is same-galaxy as current
function nexus.dimensions.same_galaxy(dim_name)
    local info = nexus.dimensions[dim_name]
    return info and info.galaxy == GALAXY_NAME
end
