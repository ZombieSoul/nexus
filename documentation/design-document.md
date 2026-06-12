# Stargate: Ascension — Modpack Design Document

## Vision
A Minecraft 1.21.1 NeoForge modpack centered around **Stargate-based tiered dimensional progression**. Players discover an ancient Stargate near spawn — unpowered, mysterious, and locked. Through tech progression (Create → Immersive Engineering → Mekanism), CC: Tweaked programming, and exploration, players power up their gate, discover addresses, and dial into progressively more dangerous dimensions containing unique resources needed to advance further.

*Inspired by TownCraft's spirit of exploration + tech, rebuilt around Stargate mythology.*

---

## The Stargate System

### Core Mod: **Stargate Journey** (`sgjourney`)
Open-source, actively maintained for 1.21.1 NeoForge. Features:
- Stargates spawn as ancient structures in the world — **cannot be crafted** (initially)
- **Symbol-based dialing** — Milky Way & Pegasus symbol sets
- **Address system** — valid symbol sequences connect to dimensions
- **Naquadah** — power resource for generators
- **CC: Tweaked integration** — ComputerCraft peripherals for programmatic gate control
- **Auto-dialer** items for saved addresses
- **Built-in dimensions**: Abydos, Chulak, Cavum Tenebrae, Lantea
- **Energy system**: Power cells, fusion cores, zero-point modules

### Our Custom Extensions (via KubeJS + custom mod)
- **Address discovery**: Symbols/glyphs found as rare loot in structures, boss drops, or crafted from dimensional materials
- **Tier-gated addresses**: You can *dial* any address but the gate won't connect without sufficient power tier
- **Mining dimensions**: Procedurally generated worlds (RFTools Dimensions or custom) for resource gathering at each tier
- **Themed progression dimensions**: Hand-crafted experiences for boss fights and story progression

---

## Dimensional Tiers

### Tier 0 — The Overworld ("Earth")
**Difficulty:** Easy | **Gate Status:** Found but unpowered
- Enhanced with **Terralith** for 100+ biomes, real exploration
- The Stargate spawns within ~500 blocks of origin, in a buried ancient structure
- **Early game loop**: Survive → Build basic tech → Discover Naquadah → Power the gate
- **Tech path**: Create (kinetic) → Immersive Engineering (power gen) → Naquadah Generator
- **CC: Tweaked**: First computers, learn to interface with the gate
- Resources: Vanilla ores + Naquadah (rare, deep underground)
- **Gate requirement to unlock Tier 1**: Build a Naquadah generator + dial first known address (found in a temple/structure)
- **Key mods**: Create, IE, CC: Tweaked, Terralith, TaCZ (guns), Immersive Aircraft

### Tier 1 — Abydos ("The Desert World")
**Difficulty:** Medium | **Gate Status:** First off-world connection
- Built-in Stargate Journey dimension OR custom desert dimension
- Desert ruins, ancient temples, sandstorms
- **Unique resources**: Desert crystals, sand-forged alloys, ancient tech scraps
- New ores that require Tier 1 processing (Create additions)
- **Boss**: Temple guardian boss drops symbol fragments for next address
- **Mining dimension**: A parallel barren world for resource extraction
- **Gate requirement for Tier 2**: Collect all symbol fragments → assemble address → power upgrade needed

### Tier 2 — Twilight Forest ("The Dark Forest")
**Difficulty:** Medium-Hard | **Gate Status:** Requires advanced power
- **Twilight Forest** — dense forests, lich towers, structured boss chain
- **Unique resources**: Steeleaf, Fiery Ingot, Twilight-imbued materials
- Boss-gated *within* the dimension (Naga → Lich → Hydra → Knight Phantom → Ur-Ghast)
- Materials needed for Tier 3 armor and Naquadah refining
- **CC: Tweaked**: Automated Stargate dialing, logging expeditions
- **Gate requirement for Tier 3**: Defeat the final TF boss, craft dimensional key

### Tier 3 — The Aether + BetterEnd ("Sky Realms")
**Difficulty:** Hard | **Gate Status**: Requires heavy power infrastructure
- **The Aether** — floating islands, unique mobs, dungeon crawling
- **BetterEnd + Nullscape** — alien End biomes, bizarre terrain
- **Unique resources**: Aetherium, End crystal alloys, gravity-defying metals
- **Advanced tech unlocks**: Mekanism processing, AE2 digital storage
- **Bosses**: Aether boss, enhanced Ender Dragon
- **Gate requirement for Tier 4**: Craft a Zero Point Module (top-tier power source)

### Tier 4 — The Undergarden + Deep Dark ("The Abyss")
**Difficulty:** Very Hard | **Gate Status**: Requires Zero Point Module
- **The Undergarden** — hostile underground dimension, environmental hazards
- **Deeper and Darker** — Sculk-infested deep realm
- **Unique resources**: Living metals, soul-forged alloys, forgotten materials
- Mobs are lethal, environmental damage, darkness mechanics
- **L2 Hostility** scales mobs to extreme levels
- **Gate requirement for Tier 5**: Harvest living metals, craft the final address key

### Tier 5 — The Void / Custom Endgame
**Difficulty:** Extreme | **Gate Status**: Requires all previous tech
- Custom dimension (our mod) — or **RFTools Dimensions** for procedural endgame
- **Bosses of Mass Destruction** encounters as final challenges
- Unique endgame rewards: creative-flight items, ultimate weapons, cosmetic
- "Win the pack" moment
- Optionally: Stargate construction — learn to BUILD your own Stargates

---

## Address Discovery System

This is a key custom mechanic we build. Here's how it works:

### Symbol Fragments
- Found as rare loot in dungeon chests, structure loot, boss drops
- Each fragment reveals one symbol on the dialing device
- Higher-tier symbols only drop in higher-tier dimensions
- **KubeJS** controls drop tables and loot injection

### Address Assembly
- Players collect 7 symbols per dimension address
- The gate interface shows discovered vs undiscovered symbols
- Wrong addresses = gate fails to connect (kawoosh and nothing)
- **CC: Tweaked** can be used to brute-force test addresses (but costs energy!)

### Address Sources
| Tier | How addresses are discovered |
|------|------------------------------|
| 1 | Complete symbol tablet found in Overworld ancient temple |
| 2 | Symbol fragments drop from Tier 1 bosses + rare structure loot |
| 3 | Requires combining materials from 2+ dimensions to craft a decoder |
| 4 | Address fragments hidden in dimension-specific structures |
| 5 | Address revealed only after completing a multi-dimension quest chain |

### Mining Dimensions (Parallel worlds)
- Each tier has a "mining world" address — procedurally generated, resource-rich
- **RFTools Dimensions** or custom KubeJS worldgen
- Mining dimensions are hazardous but not boss-focused
- Resources respawn/regenerate (chunk reset?) or are simply abundant
- Separate from progression dimensions

---

## Tech Progression Stack

### Power Generation Tiers
| Stage | Power Source | Output | Mods |
|-------|-------------|--------|------|
| Early | Create kinetic → IE dynamo | Low | Create, IE |
| Mid | IE diesel/biodiesel, Create additions | Medium | IE, Create Additions |
| Mid-Late | Naquadah Generator | High | Stargate Journey |
| Late | Mekanism fusion reactor | Very High | Mekanism |
| Endgame | Zero Point Module | Extreme | Stargate Journey |

### Processing Tiers
| Stage | Processing | Mods |
|-------|-----------|------|
| Early | Create crushing, mixing, pressing | Create |
| Mid | IE arc furnace, crusher | Immersive Engineering |
| Mid-Late | Mekanism enrichment, injection, etc. | Mekanism |
| Late | AE2 autocrafting, storage network | AE2 |
| Endgame | Custom recipes (our mod) | Custom |

### CC: Tweaked Progression
| Stage | What you do with computers |
|-------|---------------------------|
| Early | Basic gate control — dial, disconnect, read status |
| Mid | Automated dialing sequences, power monitoring |
| Mid-Late | Stargate network logging, address database |
| Late | Full automation — AE2 integration, auto-expedition systems |
| Endgame | Custom programs that interact with all dimensions |

---

## Custom Mods We'll Need to Build

### 1. **Stargate Ascension** (core custom mod)
- Symbol fragment system (items, loot injection)
- Address discovery/decoding mechanics
- Tier-gated dimension access (power requirements)
- Mining dimension generation (tied to RFTools or standalone)
- Custom worldgen structures containing address clues
- Dimensional ore registration (new ores per tier)
- Integration with Stargate Journey's API

### 2. **Tiered Materials** (could be part of core mod)
- New material system: Celestite (T2), Voidglass (T3), Abyssalite (T4), Eternium (T5)
- Armor/tool sets with tier-appropriate stats
- Processing chains integrated with Create/Mekanism
- Material properties (radiation resistance, dimension-specific bonuses)

### 3. **Stargate Programs** (CC: Tweaked Lua programs pack)
- Pre-written CC programs players can find/discover:
  - Gate dialer with saved addresses
  - Power monitor and auto-dialer
  - Address brute-forcer (expensive!)
  - Expedition logger
  - Dimension scanner (shows ore types in connected world)
- Found as loot items (floppy disks?) rather than given freely

---

## Supporting Mod List (Curated)

### 🔧 Tech & Power
| Mod | Purpose |
|-----|---------|
| Create (+ Create Crafts & Additions) | Early tech, kinetic power, FE bridge |
| Immersive Engineering | Mid-tier tech, multiblocks, power |
| Mekanism (+ Generators, Tools) | Late-game tech, advanced processing |
| Applied Energistics 2 | Digital storage, autocrafting |
| CC: Tweaked (+ Advanced Peripherals) | Computer control, Stargate programming |
| XNet | Networking, logistics |
| RFTools (Base, Power, Builder, Dimensions) | Mining worlds, power, building |

### ⚔️ Combat & Mobs
| Mod | Purpose |
|-----|---------|
| TaCZ (Timeless & Classics Zero) | Guns and firearms |
| Immersive Aircraft | Early flight for exploration |
| Mowzie's Mobs | Boss-quality animated mobs |
| Bosses of Mass Destruction | Epic boss encounters |
| Alex's Mobs | Creature diversity |
| L2 Hostility | Mob difficulty scaling by area |

### 🌍 Dimensions & Worldgen
| Mod | Purpose |
|-----|---------|
| **Stargate Journey** | THE transportation system |
| Terralith | Overworld biome overhaul |
| Incendium | Nether overhaul |
| Nullscape | End overhaul |
| BetterEnd | End enhancement |
| BetterNether | Nether enhancement |
| Twilight Forest | Tier 2 progression dimension |
| The Aether | Tier 3 sky dimension |
| The Undergarden | Tier 4 hostile dimension |
| Deeper and Darker | Tier 4 deep dimension |
| Dimensional Doors | Bonus mystery dimensions |

### 🔐 Progression & UI
| Mod | Purpose |
|-----|---------|
| KubeJS | Custom recipes, gating, loot, events |
| FTB Quests | Quest book / progression guide |
| JEI | Recipe viewing |
| Waystones | Intra-dimensional teleportation |

### 🧰 Utilities & QoL
| Mod | Purpose |
|-----|---------|
| Sophisticated Storage | Tiered storage |
| Supplementaries | QoL blocks |
| Curios / Accessories | Accessory slots |
| Sinytra Connector | Fabric mod compatibility |

---

## Player Journey (Narrative Flow)

1. **Awakening** — Spawn in the Overworld. Explore, survive. Find ancient ruins with strange symbols.
2. **Discovery** — Find the Stargate. It's massive, inert, mysterious. A DHD sits nearby — dark, no power.
3. **First Power** — Build basic tech (Create water wheels, IE wires). Connect power to the gate complex.
4. **First Dial** — The DHD lights up. You found a complete address tablet. You dial. The kawoosh. Another world.
5. **Abydos** — A desert world. Ancient structures. New resources. A boss guards deeper secrets.
6. **The Address Book** — Defeating the boss gives symbol fragments. Piece by piece, you discover new addresses.
7. **Tech Escalation** — Each dimension demands better gear, better power, better automation. Mekanism. AE2.
8. **The Forest** — Twilight Forest. Dense, dark, bosses guard progress within the dimension itself.
9. **The Sky** — Aether. End. Floating islands and alien landscapes. Advanced materials.
10. **The Abyss** — Undergarden. Hostile, lethal. The rarest materials. Only the prepared survive.
11. **The Void** — The final address. The ultimate challenge. Beat it, and you learn to build your own Stargates.
12. **Mastery** — You are no longer exploring. You are building. Your own gates. Your own worlds. Your own journey.

---

## Open Questions
- [ ] Stargate Journey's built-in dimensions — use them or override with our own?
- [ ] Mining dimensions: RFTools Dimensions or custom KubeJS worldgen?
- [ ] How many symbol fragments per address? (7 is Stargate canon)
- [ ] Can players build Stargates in endgame or always find them?
- [ ] Multiplayer considerations — shared gates, faction gates?
- [ ] How hard should the Overworld early game be? (Before first gate activation)
- [ ] Do we want a quest book (FTB Quests) or more discovery-based (no hand-holding)?
- [ ] Sinytra Connector stability for Fabric-only mods on NeoForge?
- [ ] Underground start like TownCraft, or normal surface start?
- [ ] What's the pack name? (Stargate: Ascension is a placeholder)
