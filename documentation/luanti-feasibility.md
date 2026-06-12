# Luanti Port Feasibility Assessment

## ⚠️ Critical Finding: Luanti Has No Real Dimension System

**This is the single biggest risk for our concept on Luanti.** Deep-dive research (June 2026) revealed:

### The Problem
Luanti has **no native dimension support**. A Luanti world is ONE continuous vertical space (Y from -30927 to +30927, ~62000 blocks total). There are no separate dimension instances like Minecraft has (DIM-1, DIM1, separate chunk storage, separate seeds).

### How Luanti Mods Fake Dimensions (Y-Stacking)
Both VoxeLibre (the MC clone) and the multidimensions mod use the **same trick**: they stack "dimensions" at different Y-coordinate ranges in the single world, with dead void between them.

Evidence from VoxeLibre source (`mcl_worlds/init.lua`):
```lua
-- "Dimension" is literally just a Y-coordinate check
function mcl_worlds.pos_to_dimension(pos)
    local _, dim, dim_id = y_to_layer(pos.y)  -- reads Y value
    return dim, dim_id
end
-- Overworld = high Y, End = middle Y, Nether = low Y, void between
```

The multidimensions mod does the same — `register_dimension(name, def)` assigns each dimension a `dim_y` (start Y) and `dim_height`, and they stack vertically.

### The 10-Year Open Feature Request
True dimensions have been requested since 2016:
- **Issue [#4428](https://github.com/luanti-org/luanti/issues/4428):** "Different Dimensions / Other worlds"
- **207 comments**, labeled **"Concept approved"** + **"High priority"**
- **Still open and unimplemented after 10 years**
- The server-transfer PR (#11175) was **closed and NOT merged**
- No multiworld mod ecosystem exists (zero search results)

### What This Means For Us
Our concept needs 15+ distinct dimensions across 4+ galaxies. Options:

| Approach | How It Works | Verdict |
|----------|-------------|--------|
| **Y-stacking** | Stack all dimensions vertically in one world | Proven for 3 (VoxeLibre). Unproven for 15+. Shared seed, shared sky cycle |
| **Separate worlds per galaxy** | Each galaxy = different world folder; transfer player between them | No API exists. Must build it. Loading screens between galaxies |
| **Fork Luanti engine** | Implement true dimensions in C++ | The Luanti team hasn't done this in a decade. Not realistic |

### The Silver Lining: Limitation As Design
If we combine Y-stacking (within a galaxy) with separate worlds (per galaxy), the limitation actually maps to our power scaling:
- **Intra-galaxy dial** (100K FE) = Y-teleport within a world (instant, cheap)
- **Intergalactic dial** (100B FE / ZPM) = world transfer (loading screen, expensive)

The technical constraint ENFORCES the game design. But it's still more work than MC where dimensions just exist natively.

---

## Executive Summary

**The dimension situation is the make-or-break question for Luanti.** Lua is native and beautiful for our gate-programming concept, but Luanti has NO native dimension system — only Y-coordinate stacking tricks. For a concept built on 15+ dimensions across multiple galaxies, this is a genuine architectural deficit.

**Revised Recommendation:** The dimension problem needs to be solved (or accepted) before committing to Luanti. See the "Dimension Architecture" section below for the hybrid approach that could work. If the Y-stacking limitation is acceptable, Luanti becomes viable. If not, Minecraft is the only path.

---

## The Lua Advantage (Where Luanti Wins)

This is the one genuinely compelling reason to consider Luanti:

| Aspect | Minecraft (CC: Tweaked) | Luanti |
|--------|------------------------|--------|
| Gate control programming | Nested Lua VM inside Java | **Native Lua** — the whole game is Lua |
| Modding language | Java (complex toolchain) | **Lua** (one file, instant reload) |
| Custom gate/portal logic | C++ mod or data-driven JSON | **Lua script** — full control |
| Dimension creation | JSON datapacks + noise configs | **Lua mapgen API** — programmatic |
| Energy systems | Forge Energy (Java interfaces) | **Lua — define your own** |
| Computer peripherals | CC: Tweaked's API layer | **Direct game API access** |

The "write code to control the Stargate" concept is *more powerful* in Luanti because you're not constrained to CC: Tweaked's peripheral API — your Lua programs could directly manipulate the game world. No Stargate mod means we'd build the gate itself in Lua, giving us total creative freedom over the dialing/power mechanics.

**But:** Freedom to build everything = obligation to build everything.

---

## What Exists in Luanti (The Foundation)

### Base Game: VoxeLibre (ex-MineClone2)
- **716,000 downloads** — the dominant MC-clone game
- Full survival mode: hunger, combat, ores, farming, enchanting
- Nether with portals (any enclosed shape)
- Redstone-equivalent (mesecons)
- Minecarts, villagers, structures
- **Verdict:** Solid Minecraft-like base. Comparable to vanilla MC 1.13-ish in depth.

### Tech Mods (Available but Shallow)
| Mod | Equivalent | Depth |
|-----|-----------|-------|
| **Technic** | IC2 / early Mekanism | Electricity, machines, ore processing. Mature but old-school. |
| **Mesecons** | Redstone | Digital circuitry, wires, pistons, programmable controllers |
| **Pipeworks** | Item Pipes | Item transport tubes, sorting |
| **Digtron** | (unique) | Modular tunnel-boring machines — genuinely cool, no MC equivalent |

### Computers
| Mod | Equivalent | Status |
|-----|-----------|--------|
| **LWComputers** | CC: Tweaked | Programmable computers, robots, floppy disks, screens. Functional but niche (7K downloads). |
| **Computertest** | CC: Tweaked | WIP ComputerCraft clone (3.8K downloads) |

### Dimensions
| Mod | Equivalent | Status |
|-----|-----------|-------|
| **Multidimensions** | (basic) | Adds dimensions, customizable mapgen. Bare-bones framework. |
| **Cloudlands** | Skylands/Aether | Floating islands. Single biome. |
| **Nether variants** | Nether | Several WIP options, none polished |

---

## What's MISSING in Luanti (The Gaps)

This is where the reality hits. Our design depends heavily on these, and none exist:

### ❌ No Stargate Mod
Zero results. We'd build the entire gate system from scratch in Lua — portals, dialing, symbol system, energy requirements, CC integration. This is the biggest single piece of work.

### ❌ No Quality Dimension Mods
- No Twilight Forest equivalent (dungeon-crawl adventure dimensions)
- No Aether, no Undergarden, no Deeper and Darker
- No BetterEnd/BetterNether (biome overhauls)
- The multidimensions mod is a *framework*, not content. We'd generate every dimension ourselves.

### ❌ No Sophisticated Tech Trees
- No Create (kinetic engineering, factories)
- No Mekanism (late-game processing)
- No Applied Energistics 2 (digital storage, autocrafting)
- No Immersive Engineering (multiblocks, power)
- Technic is the only real option, and it's a 2014-era IC2 clone

### ❌ No Quest/Guide Systems
- No FTB Quests (but we don't want that anyway)
- No Patchouli (guidebooks)
- No JEI (recipe viewer)

### ❌ Minimal Mob/Boss Ecosystem
- Mobs Redo (framework) + add-ons, but nothing like Alex's Mobs or Mowzie's Mobs
- Bosses are rare and simple (a few "ethereal bosses" with basic AI)
- No L2 Hostility (difficulty scaling)
- No Bosses of Mass Destruction

### ❌ No RFTools Dimensions
No procedural mining-world generation. We'd write our own dimension generator in Lua.

### ❌ No Worldgen Overhaul Mods
- No Terralith (biome overhaul)
- No Incendium, Nullscape
- Luanti has decent mapgen but nothing matching these

### ❌ No Sinytra/Compatibility Layer
Luanti is its own ecosystem. Mods are Lua and generally compatible, but there's no cross-platform bridging.

---

## Effort Comparison: What You'd Build

### On Minecraft NeoForge (Our Current Plan)
| Component | Source |
|-----------|--------|
| Stargate mechanics | ✅ Stargate Journey (existing mod) |
| Gate programming | ✅ CC: Tweaked + SGJ peripheral (existing) |
| Dimension framework | ✅ SGJ data-driven + RFTools |
| Dimensions (themed) | ✅ Twilight Forest, Aether, Undergarden, etc. |
| Tech progression | ✅ Create, IE, Mekanism, AE2 |
| Worldgen | ✅ Terralith, Incendium, etc. |
| Mobs/Bosses | ✅ Alex's Mobs, Mowzie's, BoMD |
| **We build:** | Data crystals, KubeJS scripts, custom galaxy JSON, 1-2 custom dimensions, CC treasure disks |

### On Luanti
| Component | Source |
|-----------|--------|
| Stargate mechanics | 🔨 **Build from scratch** (Lua) |
| Gate programming | 🔨 **Build from scratch** or adapt LWComputers |
| Dimension framework | 🔨 **Adapt multidimensions + build galaxy system** |
| Dimensions (themed) | 🔨 **Build all of them** (mapgen + structures + mobs) |
| Tech progression | ⚠️ Technic exists, but **no Create/Mekanism/AE2** — build the rest |
| Worldgen | 🔨 **Build biome overhauls** |
| Mobs/Bosses | 🔨 **Build most of them** |
| **We build:** | *Everything* |

---

## The Honest Scale

### Minecraft Pack: ~Custom Content = 20%
- 80% is assembling and configuring existing mods
- 20% is KubeJS scripts, data crystals, galaxy JSON, custom mod pieces
- **Estimated effort:** Medium. Weeks to playable, months to polished.

### Luanti Port: ~Custom Content = 80%+
- 20% is assembling VoxeLibre + Technic + Mesecons + a few others
- 80% is writing mods from scratch:
  - Stargate mod (portals, dialing, symbols, energy) — **months alone**
  - Dimension system with galaxies — **months**
  - Multiple hand-crafted dimensions (forest, desert, sky, abyss) — **months**
  - Tech tree expansion (Create-like kinetics, AE2-like storage) — **months**
  - Boss encounters with real AI — **months**
  - Worldgen/biome content — **months**
- **Estimated effort:** A *full game development project*, not a modpack. A year+ for a small team.

---

## Where Luanti Could Actually Shine

If we *did* pursue this, here's the strategic angle:

### 1. Total Creative Control
No Stargate mod means we invent our own gate mythology. Not bound to SGJ's Milky Way/Pegasus canon. The "Ancients" lore could be entirely ours.

### 2. Native Lua = Better Programming Gameplay
The gate-control programming could be deeper than CC: Tweaked allows. Players' programs could interface with *any* game system, not just a peripheral API.

### 3. Free & Open = Broader Audience
No Minecraft purchase required. Servers are free to run. This genuinely opens the pack to people who can't/won't buy MC.

### 4. Lighter Performance
Luanti runs on potatoes. Our pack could reach low-end hardware and older machines.

### 5. Simpler Distribution
One download (game + modpack), no launcher/NeoForge setup, no mod conflicts.

---

## Strategic Options

### Option A: Minecraft-First, Luanti-Later (Recommended)
1. Build the NeoForge pack as designed — fast iteration, existing mods
2. Prove the gameplay loop is fun
3. If it's great and there's demand, *then* evaluate a Luanti port
4. The design doc and game design transfer; only the implementation changes

### Option B: Prototype Core Mechanics in Luanti
1. Build a *minimal* Luanti prototype: gate + one dimension + basic tech + Lua programming
2. Validate the "discover and program the gate" loop in the simplest possible form
3. Use this to decide if the full port is worth it
4. **Risk:** Scope creep. The prototype becomes the project.

### Option C: Dual-Track (Not Recommended)
1. Develop both simultaneously
2. **Problem:** Halves your velocity on both. The Luanti version will always lag badly.

### Option D: Luanti-Only (Not Recommended for This Concept)
1. Abandon Minecraft, build entirely in Luanti
2. **Problem:** You're building a game, not a modpack. The concept depends on a depth of content (dimensions, tech trees, mobs) that Luanti can't provide without years of foundational work.

---

## The Real Question

It's not "can we build this in Luanti?" — we can, given enough time.

It's: **"Is replicating the *experience* worth building a game engine's worth of content from scratch?"**

For this specific design — which leans heavily on existing dimension mods, tech trees, and the Stargate Journey mod — the answer is probably no, at least not as a first step.

**The strongest play:** Build it on Minecraft first. If the concept proves out and there's appetite for a free version, a Luanti port of the *core mechanics* (gate + dialing + dimensions + programming) could be a compelling standalone project — a "Stargate: Luanti Edition" that's a different, smaller, but free experience.

---

## Dimension Architecture: How To Solve It On Luanti

This is THE technical problem. Three approaches, ranked by feasibility:

### Approach 1: All-In-One-World (Y-Stacking) — Simplest
Put every dimension in a single world at different Y ranges.

```
Y +30000  ┌─ Void (Tier 5 endgame)           ─┐ ~3000 blocks
          │  (dead void gap)                   │
Y +24000  ├─ Aether / Sky Realms (Tier 3)    ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y +18000  ├─ Overworld ("Earth", Tier 0)     ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y +12000  ├─ Twilight Forest (Tier 2)        ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y  +6000  ├─ Abydos (Tier 1, desert)         ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y       0 ├─ Nether (vanilla)                ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y  -6000  ├─ Cavum Tenebrae (crushed world)  ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y -12000  ├─ Undergarden (Tier 4)            ─┤ ~3000 blocks
          │  (dead void gap)                   │
Y -30000  └─ End / Lantea / etc.             ─┘
```

**Pros:** Simple. One world. Instant teleportation (just move Y). The multidimensions mod already does this.
**Cons:**
- Shared world seed (mitigated: offset noise per dimension so they look different)
- Shared day/night cycle (mitigated: override sky per Y-range — VoxeLibre does this)
- ~62000 blocks total = tight for 15+ dimensions (need ~2000-3000 blocks each)
- All chunks load in one world = higher memory/ram usage
- Dimensions aren't independent (one corrupts, all affected)
- **Galaxy concept doesn't exist** — everything is "the same world," just different elevations

**Verdict:** Works for a SMALL number of dimensions (3-6). Clunky for our full 15+ concept. No galaxy separation.

### Approach 2: Hybrid (Separate Worlds Per Galaxy) — Best Fit ✅
Each galaxy is a separate Luanti world (folder). Dimensions within a galaxy are Y-stacked.

```
milky_way/          ← World folder (Galaxy 0)
  ├── Overworld     (Y: +15000 to +19000)
  ├── Abydos        (Y:  +5000 to  +9000)
  ├── Chulak        (Y:  -1000 to  +3000)
  ├── Nether        (Y:  -9000 to  -5000)
  ├── End           (Y: -19000 to -15000)
  └── Twilight Frst (Y: -26000 to -22000)

pegasus/            ← World folder (Galaxy 1, needs ZPM to reach)
  ├── Lantea        (Y: +10000 to +16000, ocean world)
  └── Custom dims   (Y-stacked)

andromeda/          ← World folder (Galaxy 2)
  └── Tier 4 dims   (Y-stacked)

void/               ← World folder (Galaxy 3, endgame)
  └── Tier 5 dims   (Y-stacked)
```

**How Stargate travel works:**
- **Intra-galaxy dial** (100K FE): `player:set_pos(new_y)` — instant teleport within world
- **Intergalactic dial** (100B FE / ZPM): transfer player to a different world folder

**The world-transfer mechanic we'd build:**
1. Save player inventory, health, metadata to a shared state file
2. Disconnect from current world / save & exit
3. Load destination world
4. Restore player state at destination Stargate coordinates
5. In singleplayer: brief loading screen (like MC dimension travel)
6. On server: world switching or multiple server instances

**Pros:**
- Galaxy separation is REAL (separate worlds)
- Power scaling maps perfectly (cheap = Y-teleport, expensive = world switch)
- Each galaxy can have its own worldgen seed, its own rules
- Memory: only one galaxy's chunks loaded at a time
- Maps to our design's intent (galaxies are distant, require ZPM)

**Cons:**
- **No API exists for this** — we build the world-transfer system from scratch
- Loading screen between galaxies (acceptable — MC has this too)
- Inventory syncing is the hard part (player state must persist across worlds)
- Server setup is more complex (multiple worlds to manage)

**Verdict:** This is the approach that turns Luanti's limitation into our feature. Most work, best result.

### Approach 3: Server Cluster (Proper Multiworld) — Most Complex
Run each galaxy as a separate Luanti server process. Stargate = server transfer.

**Pros:** True isolation. Each galaxy scales independently. Can run on different hardware.
**Cons:** Massive ops overhead. Only viable for a hosted server, not singleplayer. The transfer PR (#11175) was never merged.

**Verdict:** Server-only, not suitable for a downloadable modpack. Disqualified.

---

## Technical Notes (If We Do Pursue Luanti)

### Luanti Modding Basics
- Mods are Lua scripts (`init.lua` + `mod.conf`)
- No compilation — edit and reload
- Full game API access (nodes, entities, mapgen, formspecs/GUIs)
- Dimensions = Y-stacked mapgen regions (NOT separate instances)
- Energy = define your own system (no standard like Forge Energy)

### What a Luanti Stargate Mod Would Need
- Portal nodes with custom rendering
- Dialing logic (symbol sequences, validation)
- Energy storage & transfer system
- Intra-world teleportation (Y-range jump) — trivial
- **Cross-world transfer system** — must be built from scratch
- Computer integration (wrap LWComputers or build own)
- Address book / discovery system
- Estimated: with AI assistance, 2-4 weeks for core gate + single-world travel; +2-4 weeks for cross-world transfer system

### Resources
- Luanti modding docs: https://api.luanti.org/
- Rubenwardy's modding book: https://rubenwardy.com/minetest_modding_book/
- multidimensions mod: reference for Y-stacking implementation
- VoxeLibre `mcl_worlds`: reference for dimension sky/weather override
