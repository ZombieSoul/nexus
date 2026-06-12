# Luanti Port Feasibility Assessment

## Executive Summary

**Replicating this pack in Luanti is theoretically possible but practically a massive undertaking.** The core concept translates beautifully (and Lua is native), but you'd be building 70%+ of the content from scratch because the Luanti ecosystem lacks nearly every mod our design depends on.

**Recommendation:** Pursue this as a *long-term second platform*, not a parallel development. Build the Minecraft NeoForge pack first, then evaluate a Luanti port of the core mechanics once the design is proven.

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

## Technical Notes (If We Do Pursue Luanti)

### Luanti Modding Basics
- Mods are Lua scripts (`init.lua` + `mod.conf`)
- No compilation — edit and reload
- Full game API access (nodes, entities, mapgen, formspecs/GUIs)
- Dimensions = separate mapgens with `minetest.register_mapgen()`
- Energy = define your own system (no standard like Forge Energy)

### What a Luanti Stargate Mod Would Need
- Portal nodes with custom rendering
- Dialing logic (symbol sequences, validation)
- Energy storage & transfer system
- Dimension teleportation via `minetest.emerge_area` + player relocation
- Computer integration (wrap LWComputers or build own)
- Address book / discovery system
- Estimated: 3-6 months for a solo developer to reach feature-parity with SGJ's core

### Resources
- Luanti modding docs: https://api.luanti.org/
- Rubenwardy's modding book: https://rubenwardy.com/minetest_modding_book/
- Example: multidimensions mod for dimension patterns
