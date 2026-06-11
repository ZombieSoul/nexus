# Tiered Dimensions Modpack — Design Document

## Vision
A Minecraft 1.21.1 NeoForge modpack centered around **tiered dimensional progression**. Players start in an enhanced Overworld, then unlock progressively harder dimensions, each containing unique resources needed to tackle the next tier. Inspired by TownCraft's spirit of exploration and tech, but rebuilt around dimensional gating.

---

## Dimensional Tiers (Draft)

### Tier 0 — The Overworld (Starting Zone)
**Difficulty:** Vanilla-easy | **Purpose:** Foundation, early tech, basic survival
- Enhanced with **Terralith** for vastly better biomes and exploration
- All vanilla ores + basic tech resources
- Early game: stone → iron → diamond gear progression
- Tech tree starts here (Create basics, Immersive Engineering)
- Guns become available mid-tier (TaCZ)
- **Goal:** Defeat a regional boss or complete a questline to earn the "key" to Tier 1

### Tier 1 — The Nether (Expanded)
**Difficulty:** Medium | **Purpose:** First challenge dimension
- Enhanced with **Incendium** for massive Nether overhaul
- **Deeper and Darker** — new Sculk dimension accessible from deep dark
- Unique resources: Nether alloys, soul-infused materials, blaze-derived power
- **L2 Hostility** scales mob difficulty
- **Goal:** Defeat a Nether boss, gather enough resources to craft Tier 2 portal

### Tier 2 — The Twilight Forest
**Difficulty:** Medium-Hard | **Purpose:** Adventure + exploration focus
- Classic **Twilight Forest** — dense forests, lich towers, boss progression
- Unique resources: Steeleaf, Fiery Ingot, Twilight-specific materials
- Boss-gated progression (Naga → Lich → Hydra → etc.)
- Contains materials needed for Tier 3 gear
- **Goal:** Clear the Twilight Forest boss chain, craft dimensional key

### Tier 3 — The Aether / Skylands
**Difficulty:** Hard | **Purpose:** Sky dimension, advanced materials
- **The Aether** + **Deep Aether** — floating islands, unique mobs
- Enhanced End with **Nullscape** for alien/bizarre terrain
- **BetterEnd** for End overhaul with unique biomes and resources
- Unique resources: Aetherium, End crystals, gravity-defying materials
- Advanced tech (Mekanism, AE2) needed to process these materials
- **Goal:** Defeat Aether/End bosses, craft gateway to Tier 4

### Tier 4 — The Undergarden / Deep Realms
**Difficulty:** Very Hard | **Purpose:** Underground horror, endgame materials
- **The Undergarden** — dark, hostile underground dimension
- **Dimensional Doors** — liminal pocket dimensions with rare loot
- Unique resources: Forgotten metals, living materials, soul-forged alloys
- Mobs hit hard, environmental hazards
- **Goal:** Survive long enough to gather materials for final tier

### Tier 5 — The Void / Endgame
**Difficulty:** Extreme | **Purpose:** Final challenge, ultimate rewards
- Custom dimension (we build this) or use **RFTools Dimensions**
- Boss rush encounters using **Bosses of Mass Destruction**
- Unique resources: God-tier materials, cosmetic rewards, creative-flight items
- **Goal:** Beat the final boss, unlock creative conveniences, "win" the pack

---

## Core Mod Categories

### 🔧 Tech & Automation
| Mod | Role |
|-----|------|
| **Create** (+ addons) | Core tech, kinetic power, early-mid automation |
| **Immersive Engineering** | Mature tech tree, power gen, multiblocks |
| **Mekanism** | Late-game tech, advanced processing |
| **Applied Energistics 2** | Digital storage, autocrafting |
| **Immersive Aircraft** | Early flight for dimension exploration |

### ⚔️ Combat & Adventure
| Mod | Role |
|-----|------|
| **TaCZ** (Timeless & Classics Zero) | Guns and firearms |
| **Mowzie's Mobs** | High-quality animated boss encounters |
| **Bosses of Mass Destruction** | Epic boss fights |
| **Alex's Mobs** | Diverse creature ecosystem |
| **L2 Hostility** | Mob difficulty scaling by dimension/area |
| **Ars Nouveau** | Magic combat option alongside tech |

### 🌍 Dimensions & Worldgen
| Mod | Role |
|-----|------|
| **Terralith** | Overworld biome overhaul (100+ biomes) |
| **Incendium** | Nether biome overhaul |
| **Nullscape** | End dimension overhaul |
| **BetterEnd** | End enhancement with new biomes |
| **BetterNether** | Nether enhancement (with Incendium?) |
| **Twilight Forest** | Classic adventure dimension |
| **The Aether** | Sky dimension |
| **The Undergarden** | Dark underground dimension |
| **Deeper and Darker** | Sculk dimension |
| **Dimensional Doors** | Pocket dimensions, mystery |
| **Immersive Portals** | Seamless dimension transitions (if stable on 1.21.1 NeoForge) |

### 🔐 Progression & Gating
| Mod | Role |
|-----|------|
| **KubeJS** | Custom recipes, dimension access gating, quest logic |
| **FTB Quests** | Visual quest book for guiding players |
| **JEI** | Recipe viewing |
| **Custom Portal API Reforged** | Custom portal creation per dimension |
| **L2 Hostility** | Mob scaling tied to dimension tier |
| **Silent's Power Scale** or **RPG Mob Leveling** | Difficulty scaling |
| **Dimensional Structure Restrict** | Control what generates per dimension |

### 🧰 Utilities
| Mod | Role |
|-----|------|
| **Waystones** | Teleportation network within dimensions |
| **Curios / Accessories** | Accessory/bauble slots |
| **Sophisticated Storage** | Tiered storage solutions |
| **Supplementaries** | QoL blocks and items |

---

## Progression Gating Strategy

The key challenge is **dimensional gating** — making sure players can't skip ahead. Options:

### Option A: Item-locked Portals (Recommended)
Each dimension's portal requires a specific item crafted from the *previous* dimension's unique resources. KubeJS handles this:
- Tier 1 portal frame requires items only found in Overworld boss drops
- Tier 2 portal requires Nether-exclusive alloys
- etc.

### Option B: KubeJS Event Blocking
Use KubeJS `player.tick` or dimension change events to block players from entering dimensions unless they have an advancement/item.

### Option C: Custom Portal API
Use **Custom Portal API Reforged** to define portals with custom activation items — cleanest integration.

### Recommended: Hybrid Approach
- **Custom Portal API** for portal mechanics (what item activates, portal color, etc.)
- **KubeJS** for recipe gating (portal activation items require previous tier resources)
- **FTB Quests** for player guidance (questlines that walk through each tier)

---

## Custom Mods We'll Need to Build

### 1. **Dimensional Ascension** (working title)
- Registers 1-2 completely custom dimensions with unique worldgen
- Custom portal blocks with tier-specific activation
- Integrates with the tiered ore/material system
- Could include a "dimensional nexus" hub structure

### 2. **Tiered Materials** (working title)
- New ore types: Celestite (T2), Voidstone (T3), Abyssalite (T4), Eternium (T5)
- Armor/tool sets per tier with increasing stats
- Material processing recipes requiring previous-tier equipment
- Integration with Create/Mekanism processing chains

### 3. **Dimensional Mobs** (if needed)
- Custom mobs per dimension tier if existing mods don't cover it
- Tier-specific boss encounters
- Mob scaling linked to dimension

---

## Open Questions / Needs Discussion
- [ ] Exact number of tiers (5 is a lot — maybe 3-4 is better?)
- [ ] Which dimensions are must-haves vs nice-to-have?
- [ ] Guns: TaCZ vs Scorched Guns — which feels right?
- [ ] Magic path: Ars Nouveau as parallel progression to tech?
- [ ] Multiplayer vs single player focus?
- [ ] How "hard" should the early game be? Hardcore lite or casual?
- [ ] Do we want a custom starting dimension (underground spawn) like TownCraft?
- [ ] Quest book style: guided linear quests or branching exploration?

---

## Tech Stack Summary
- **MC:** 1.21.1
- **Loader:** NeoForge
- **Cross-loader:** Sinytra Connector (for Fabric-only mods)
- **Scripting:** KubeJS (recipes, gating, custom behaviors)
- **Quests:** FTB Quests
- **Custom Mods:** Java/NeoForge MDK
