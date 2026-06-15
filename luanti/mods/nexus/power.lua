-- nexus/power.lua
-- Power interface for the nexus travel system.
--
-- This module defines the CONTRACT between nexus (the gate/travel system)
-- and any power provider mod. Nexus itself does NOT implement power
-- generation or storage — it only checks whether a gate can afford a
-- given operation.
--
-- By default (no provider registered), all gates are FREE. This keeps
-- nexus usable standalone for creative/sandbox play. Set
--   nexus.require_power = true
-- in the server config to enforce power checks.
--
-- A power provider mod implements two callbacks and registers itself:
--
--   local my_provider = {
--       name = "nexus_power",
--       -- Can this gate afford to travel at this tier?
--       check = function(gate_address, tier)
--           return my_storage_has_enough(gate_address, tier)
--       end,
--       -- Consume power for this trip. Return false to abort travel.
--       consume = function(gate_address, tier)
--           return drain_my_storage(gate_address, tier)
--       end,
--   }
--   nexus.power.register_provider(my_provider)
--
-- Tiers map to travel distance (see nexus.power.TIER below).

nexus.power = {}

-- Configuration: if false, power checks are always bypassed (gates free)
-- regardless of whether a provider is registered.
local REQUIRE_POWER = nexus._config.require_power

-- The registered power provider, or nil if none.
local provider = nil

-- =============================================================================
-- Power Tiers
-- =============================================================================
-- Tiers map travel distance to power cost. A power provider uses these to
-- determine how much energy a trip requires.

nexus.power.TIER = {
    SAME_WORLD   = 1,  -- instant local teleport (cheap)
    SAME_GALAXY  = 2,  -- cross-world within same galaxy (interstellar)
    CROSS_GALAXY = 3,  -- cross-galaxy (intergalactic — most expensive)
}

--- Human-readable tier names (for chat messages).
local TIER_LABELS = {
    [1] = "intra-world",
    [2] = "interstellar",
    [3] = "intergalactic",
}

--- Determine the power tier for a route.
--- @param from_galaxy string  Origin galaxy
--- @param from_world string   Origin world
--- @param to_galaxy string    Destination galaxy
--- @param to_world string     Destination world
--- @return number tier  (1, 2, or 3)
--- @return string label (human-readable)
function nexus.power.tier_for(from_galaxy, from_world, to_galaxy, to_world)
    local tier
    if to_galaxy ~= from_galaxy then
        tier = nexus.power.TIER.CROSS_GALAXY
    elseif to_world ~= from_world then
        tier = nexus.power.TIER.SAME_GALAXY
    else
        tier = nexus.power.TIER.SAME_WORLD
    end
    return tier, TIER_LABELS[tier]
end

-- =============================================================================
-- Provider Registration
-- =============================================================================

--- Register a power provider.
--- Only one provider can be active at a time (last registration wins).
--- @param p table  Must implement check(gate_addr, tier) and consume(gate_addr, tier)
function nexus.power.register_provider(p)
    assert(type(p) == "table", "power provider must be a table")
    assert(type(p.check) == "function", "provider.check(gate_addr, tier) must be a function")
    assert(type(p.consume) == "function", "provider.consume(gate_addr, tier) must be a function")
    provider = p
    core.log("action", "[nexus] power provider registered: " ..
        tostring(p.name or "(unnamed)"))
end

--- Is a power provider currently active and enforcing?
function nexus.power.has_provider()
    return REQUIRE_POWER and provider ~= nil
end

--- Get the active provider (for debugging/introspection).
function nexus.power.get_provider()
    return provider
end

-- =============================================================================
-- Power Check & Consume
-- =============================================================================
-- These are called by the gate system before/at travel.
-- If no provider or require_power is false, they always succeed (gates free).

--- Check whether a gate can afford to travel at the given tier.
--- @param gate_address string  The gate the player is departing from
--- @param tier number          Power tier (1-3)
--- @return boolean can_afford
--- @return string? error_msg   Reason if false
function nexus.power.check(gate_address, tier)
    if not REQUIRE_POWER then return true end
    if not provider then return true end
    local ok = provider.check(gate_address, tier)
    if not ok then
        return false, "Insufficient power for " ..
            (TIER_LABELS[tier] or "tier " .. tier) .. " travel"
    end
    return true
end

--- Consume power for a travel operation.
--- Called right before the actual hop/teleport begins.
--- @param gate_address string  The gate the player is departing from
--- @param tier number          Power tier (1-3)
--- @return boolean consumed
function nexus.power.consume(gate_address, tier)
    if not REQUIRE_POWER then return true end
    if not provider then return true end
    return provider.consume(gate_address, tier)
end

core.log("action", "[nexus] power interface loaded — " ..
    (REQUIRE_POWER and "required" or "optional (gates free by default)"))
