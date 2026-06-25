-- nexus/glyphs.lua
-- Glyph address system — player-facing address representation.
--
-- Players never see internal route strings like "milkyway:earth:g10_20".
-- Instead, every gate address has a deterministic glyph sequence:
-- a series of 3, 5, or 7 colored geometric symbols.
--
-- 12 symbols (color + shape):
--   1  circle_red       ●
--   2  triangle_orange  ▲
--   3  square_yellow    ■
--   4  diamond_green    ◆
--   5  pentagon_cyan    ⬠
--   6  hexagon_blue     ⬡
--   7  star_violet      ★
--   8  cross_magenta    ✦
--   9  crescent_white   ☾
--  10  spiral_pink      ◎
--  11  dotdiamond_lime  ◈
--  12  ring_amber       ◯
--
-- Glyph counts: 3 (same-world), 5 (same-galaxy), 7 (cross-galaxy)

nexus.glyphs = {}

local GLYPH_NAMES = {
    "circle_red",
    "triangle_orange",
    "square_yellow",
    "diamond_green",
    "pentagon_cyan",
    "hexagon_blue",
    "star_violet",
    "cross_magenta",
    "crescent_white",
    "spiral_pink",
    "dotdiamond_lime",
    "ring_amber",
}

-- Unicode symbols for chat display
local GLYPH_SYMBOLS = {
    "●", "▲", "■", "◆", "⬠", "⬡",
    "★", "✦", "☾", "◎", "◈", "◯",
}

-- Color hex for chat display
local GLYPH_COLORS = {
    "#FF3232", "#FF8222", "#FFDD28", "#32C846", "#28C0D2", "#325AE6",
    "#8C3CDC", "#DC34B4", "#E6E6F0", "#F096B4", "#A0E632", "#E6AA28",
}

-- Human-readable short names
local GLYPH_LABELS = {
    "Red Circle", "Orange Triangle", "Yellow Square", "Green Diamond",
    "Cyan Pentagon", "Blue Hexagon", "Violet Star", "Magenta Cross",
    "White Crescent", "Pink Spiral", "Lime Dot-Diamond", "Amber Ring",
}

local NUM_GLYPHS = 12

-- =============================================================================
-- Address ↔ Glyph Conversion
-- =============================================================================

-- Deterministic hash: string → 0..NUM_GLYPHS-1
local function hash_step(s, salt)
    local h = salt
    for i = 1, #s do
        h = (h * 31 + string.byte(s, i)) % 2147483647
    end
    return (h % NUM_GLYPHS) + 1  -- 1-based index
end

--- Convert an internal route to a glyph sequence.
--- @param route table {galaxy=, world=, gate_id=}
--- @return table indices  array of 1-12 glyph indices
--- @return table names    array of glyph name strings
function nexus.glyphs.route_to_glyphs(route)
    if not route then return {}, {} end
    local indices = {}

    -- Determine tier (glyph count) from the route
    local galaxy = route.galaxy or ""
    local world = route.world or ""
    local gid = route.gate_id or ""

    -- Check if this is same-world, same-galaxy, or cross-galaxy
    -- relative to THIS server. The caller should provide the full route;
    -- we always generate max-length glyphs based on what info is present.
    -- Same-world: only gate_id → 3 glyphs
    -- Same-galaxy: galaxy+world+gate_id → 5 glyphs
    -- Cross-galaxy: different galaxy → 7 glyphs

    local my_galaxy = nexus._config and nexus._config.galaxy_name or ""
    local my_world = nexus._config and nexus._config.world_name or ""

    local glyph_count
    if galaxy ~= my_galaxy and galaxy ~= "" then
        glyph_count = 7  -- cross-galaxy
    elseif world ~= my_world and world ~= "" then
        glyph_count = 5  -- same-galaxy, different world
    else
        glyph_count = 3  -- same-world
    end

    -- Generate glyph indices from different parts of the route
    -- Each part is hashed with a different salt for decorrelation
    if glyph_count >= 7 then
        -- Cross-galaxy: galaxy + world + gate_id, 7 glyphs
        indices[1] = hash_step(galaxy, 1001)
        indices[2] = hash_step(galaxy, 2002)
        indices[3] = hash_step(world, 3003)
        indices[4] = hash_step(world, 4004)
        indices[5] = hash_step(gid, 5005)
        indices[6] = hash_step(gid, 6006)
        indices[7] = hash_step(galaxy .. world .. gid, 7007)
    elseif glyph_count >= 5 then
        -- Same-galaxy: world + gate_id, 5 glyphs
        indices[1] = hash_step(world, 1001)
        indices[2] = hash_step(world, 2002)
        indices[3] = hash_step(gid, 3003)
        indices[4] = hash_step(gid, 4004)
        indices[5] = hash_step(world .. gid, 5005)
    else
        -- Same-world: gate_id, 3 glyphs
        indices[1] = hash_step(gid, 1001)
        indices[2] = hash_step(gid, 2002)
        indices[3] = hash_step(gid, 3003)
    end

    -- Build names
    local names = {}
    for i, idx in ipairs(indices) do
        names[i] = GLYPH_NAMES[idx]
    end

    return indices, names
end

--- Get glyph symbols (unicode) for chat/display.
--- @param indices table  array of glyph indices (1-12)
--- @return string  space-separated unicode symbols
function nexus.glyphs.get_symbols(indices)
    local parts = {}
    for _, idx in ipairs(indices) do
        parts[#parts+1] = GLYPH_SYMBOLS[idx]
    end
    return table.concat(parts, " ")
end

--- Get colored glyph symbols for chat display.
--- @param indices table
--- @return string  colorized string
function nexus.glyphs.get_colored_symbols(indices)
    local parts = {}
    for _, idx in ipairs(indices) do
        parts[#parts+1] = core.colorize(GLYPH_COLORS[idx], GLYPH_SYMBOLS[idx])
    end
    return table.concat(parts, " ")
end

--- Get the glyph index from a glyph name.
--- @param name string  e.g. "circle_red"
--- @return number?  1-12, or nil if invalid
function nexus.glyphs.name_to_index(name)
    for i, n in ipairs(GLYPH_NAMES) do
        if n == name then return i end
    end
    return nil
end

--- Get glyph info by index.
--- @param idx number  1-12
--- @return table  {name=, symbol=, color=, label=}
function nexus.glyphs.get_info(idx)
    return {
        name = GLYPH_NAMES[idx],
        symbol = GLYPH_SYMBOLS[idx],
        color = GLYPH_COLORS[idx],
        label = GLYPH_LABELS[idx],
    }
end

--- Get all glyph info (for building UIs).
function nexus.glyphs.get_all()
    local result = {}
    for i = 1, NUM_GLYPHS do
        result[i] = nexus.glyphs.get_info(i)
    end
    return result
end

-- Expose the name list for other modules
nexus.glyphs.NAMES = GLYPH_NAMES
nexus.glyphs.SYMBOLS = GLYPH_SYMBOLS
nexus.glyphs.COLORS = GLYPH_COLORS
nexus.glyphs.COUNT = NUM_GLYPHS

core.log("action", "[nexus] glyph system loaded — " .. NUM_GLYPHS .. " symbols")
