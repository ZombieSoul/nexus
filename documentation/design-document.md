# Stargate: Ascension — Modpack Design Document

## Vision
A Minecraft 1.21.1 NeoForge modpack about **discovery through technology**. You start in a vanilla+ Overworld. Then you find it — a massive, silent ring of unknown material, buried in ancient ruins. No controls. No manual. No power. To activate it you'll need to build tech, write code, and pour enormous amounts of energy into something you don't fully understand. When it finally works, it opens a portal to another world — and that's when the game really begins.

No quest book. No hand-holding. You learn by exploring, reading data crystals, and reverse-engineering ancient technology.

---

## The Stargate Problem

### Finding the Gate
- A Stargate spawns in an ancient ruin structure within ~500 blocks of spawn
- The structure is partially buried/collapsed — it's clearly been here a long time
- **No DHD (Dial Home Device)** is present — there's no clicky interface
- No symbols are labeled, no documentation, just a silent ring with strange markings

### Powering the Gate
- The gate requires **massive energy** to operate (Stargate Journey native behavior)
- Early power (coal generators, basic IE) is theoretically sufficient but **extremely impractical**
- A single gate activation might drain days of coal power generation
- This creates the first major tech goal: build enough power infrastructure
- **Create** (kinetic → FE via Create Crafts & Additions) is the first viable path
- **Immersive Engineering** biodiesel is the first *practical* path
- **Naquadah** (discovered in Tier 1) makes gate operation trivial — but you don't know that yet

### Dialing Without a DHD
Since there's no DHD, players **must use CC: Tweaked** to interface with the gate. The mod's API exposes low-level Milky Way gate control:
- `rotateClockwise(symbol)` / `rotateAntiClockwise(symbol)` — physically rotate the inner ring
- `openChevron()` / `closeChevron()` — lock symbols into position
- `engageSymbol(symbol)` — engage a symbol via the interface
- `getStargateEnergy()` — check current power level
- `getChevronsEngaged()` — how many symbols locked
- `isStargateConnected()` — did it work?
- `disconnectStargate()` — shut it down

**Players literally write Lua programs to dial addresses.** The first program is probably:
```lua
-- A desperate first attempt
peripheral.call("stargate", "engageSymbol", 1)
peripheral.call("stargate", "engageSymbol", 5)
peripheral.call("stargate", "engageSymbol", 12)
-- ...hope for the best
```

Later programs become sophisticated auto-dialers with saved address databases.

### Discovering Addresses
- Addresses are **not given** — they must be discovered
- **Data crystals** found in structures and dungeons contain fragments: symbol sequences, partial addresses, hints
- The first complete address is found in the **same ruin complex as the gate** (but deeper in, behind a puzzle or mini-boss)
- Subsequent addresses come from: boss drops, deep structure exploration, combining fragments
- Wrong addresses either fail to connect (kawoosh and nothing) or connect to **hazardous mining worlds** (see below)

---

## Dimensional System

### Progression Dimensions (Hand-Crafted / Themed)
These are the story dimensions. Each has unique resources, challenges, and leads to the next.

#### Tier 0 — The Overworld ("Earth")
**Power Tier:** None → Basic | **Gate Status:** Discovered, unpowered

You spawn in a vanilla+ world enhanced by Terralith. Normal Minecraft. Explore, survive, build. One day you stumble into ancient ruins and find something impossible — a giant stone ring covered in alien symbols. 

**Gameplay loop:**
- Vanilla survival + tech progression (Create → Immersive Engineering)
- Find the gate ruin, recognize it's significant
- Realize it needs power — massive amounts of it
- Build CC: Tweaked computers to interface with it
- Find data crystal #1 somewhere deeper in the ruin complex (contains the first known address)
- Write your first dialing program
- Power up. Dial. Step through.

**Key resources:** Vanilla ores, Create components, IE materials
**Tech unlocked:** Create, IE basics, CC: Tweaked basics, first power generation

---

#### Tier 1 — "The Desert Temple" (Abydos or Custom)
**Power Tier:** Basic | **Gate Status:** First off-world connection

A desert world with buried temples, sandstorms, and ancient ruins. The first data crystal's address leads here. This is where you learn the rules of off-world exploration.

**Gameplay loop:**
- Explore desert temples — they contain more data crystals
- Fight temple guardians (enhanced mobs, L2 Hostility scaling)
- **Discover Naquadah** — a strange ore found deep underground here
- Data crystals teach you about Naquadah generators (dramatically easier gate power)
- The temple boss drops symbol fragments for the next address
- First exposure to: dimension-specific ores, hostile environments

**Key resources:** Naquadah (game-changer for gate power), desert crystals, ancient tech scraps
**Tech unlocked:** Naquadah generators, IE mid-tier, Create mid-tier
**Discovery:** Naquadah makes gate operation practical — this is the "ah-ha" moment

---

#### Tier 2 — "The Dark Forest" (Twilight Forest)
**Power Tier:** Intermediate (Naquadah) | **Gate Status:** Requires upgraded power

The Twilight Forest. Dense, dark, dangerous. Boss progression is built into the dimension — you must conquer each area to advance.

**Gameplay loop:**
- Navigate dense forest, find protected zones
- Boss chain: Naga → Lich → Hydra → Knight Phantom → Ur-Ghast
- Each boss drops unique materials and sometimes data crystal fragments
- Steeleaf, Fiery Ingot, and other TF materials needed for Tier 3 gear
- The final boss reveals a complete address for the next dimension

**Key resources:** Steeleaf, Fiery Ingot, Twilight-specific materials
**Tech unlocked:** Mekanism entry, advanced Create, mid-tier combat gear (TaCZ guns)

---

#### Tier 3 — "Sky Realms" (Aether + BetterEnd + Nullscape)
**Power Tier:** Advanced | **Gate Status:** Requires significant Naquadah infrastructure

Floating islands, alien landscapes, the void between worlds. Multiple sub-dimensions accessible from this tier.

**Gameplay loop:**
- **The Aether**: Dungeon crawling on floating islands, unique Aether mobs
- **BetterEnd/Nullscape**: Enhanced End dimension with alien biomes
- Resources here require advanced processing (Mekanism tier)
- Boss encounters in Aether dungeons and enhanced End
- Data crystals reveal fragments that must be combined across multiple worlds
- AE2 becomes essential for managing the growing material complexity

**Key resources:** Aetherium, End crystal alloys, gravity-defying metals
**Tech unlocked:** Mekanism full, AE2 digital storage, advanced CC programs

---

#### Tier 4 — "The Abyss" (Undergarden + Deeper and Darker)
**Power Tier:** High | **Gate Status:** Requires heavy Naquadah + fusion power

Hostile underground dimensions where the environment itself wants to kill you. Darkness, toxic atmosphere, lethal mobs.

**Gameplay loop:**
- Environmental hazards require special armor (Tier 3 materials)
- L2 Hostility cranks mob difficulty to extreme
- Living metals, soul-forged alloys — materials that seem almost alive
- Boss encounters are brutal, require preparation
- The deepest data crystal reveals the final address

**Key resources:** Living metals, soul-forged alloys, forgotten materials  
**Tech unlocked:** Fusion power, zero-point modules, ultimate gear

---

#### Tier 5 — "The Void" (Custom / Endgame)
**Power Tier:** Extreme | **Gate Status:** Requires everything you've built

The final dimension. Strange, alien, hostile. Boss rush encounters. Ultimate rewards.

**Gameplay loop:**
- Final bosses (Bosses of Mass Destruction encounters)
- Endgame materials for creative-tier items
- **The ultimate reward**: Learn to construct your own Stargates
- Build a gate network connecting all your worlds
- "Win" the pack — but the worlds are still there to explore

**Key rewards:** Creative flight, ultimate tools/armor, gate construction, cosmetic rewards

---

### Mining Dimensions (Procedural / Random)

**RFTools Dimensions** powers this system. When a player dials a random address that isn't a progression dimension, they get a procedurally generated world. These are the **mining worlds** — resource-rich but potentially deadly.

#### Hazard System
Mining worlds have random conditions that make them challenging:
- **Flooded** — gate is underwater, potentially hundreds of blocks deep
- **Toxic atmosphere** — take damage without proper armor
- **Eternal darkness** — mobs spawn constantly, visibility near zero
- **Extreme gravity** — fall damage multiplied, movement impaired
- **Scorched** — fire everywhere, lava surface, heat damage
- **Void islands** — thin platforms over infinite void
- **Unstable** — random explosions, cave-ins
- **Hostile life** — dense mob spawning, L2 Hostility at max

#### The Risk/Reward Loop
- Players discover "random" addresses through experimentation or partial data crystals
- Some are gold mines — safe-ish, rich in ores
- Some are death traps — you dial in and immediately fight to survive
- The gate is your only way back — if you die, your items are stranded there
- **CC: Tweaked programs** can probe a world before stepping through (check atmosphere, scan for threats)
- Better equipment = safer mining expeditions = better resources

#### Mining World Resources
- Ores appropriate to the player's progression tier
- Dimensional blobs (RFTools mechanic) with rare materials
- Occasionally: data crystal fragments, Naquadah deposits, ancient tech

---

## The Data Crystal System

Instead of a quest book, information comes from **data crystals** — in-world items found in structures, dropped by bosses, or crafted from fragments.

### What Data Crystals Do
- **Knowledge crystals**: Teach the player about mechanics ("Naquadah can be refined in an Arc Furnace to produce...")
- **Address crystals**: Contain complete or partial Stargate addresses
- **Symbol crystals**: Reveal what a specific symbol looks like and its position
- **Technology crystals**: Unlock recipe knowledge (JEI integration? advancement unlock?)
- **Log crystals**: Story/lore entries — journal pages from previous gate travelers

### Implementation
- Custom items via **KubeJS** (startup scripts for registration)
- Right-click to "read" — displays text in chat or a simple GUI
- Some crystals are rare drops, some are guaranteed in specific structures
- **KubeJS loot injection** places them in dungeon chests, temple loot, boss drops
- Crystals can chain: Crystal A says "seek the temple at coordinates marked on Crystal B"
- Technology crystals could trigger **Minecraft advancements** to unlock recipes

### Discovery Over Guidance
The philosophy is: **the world teaches you, not the quest book.**

| Traditional Quest Book | Data Crystal System |
|----------------------|-------------------|
| "Craft a Naquadah Generator" | Crystal found in desert temple: "The ancients refined Naquadah ore through intense heat. A specialized generator could harness its energy..." |
| "Dial these coordinates" | Fragment found in ruins: partial symbol sequence scratched into stone, with a drawing of a forest |
| "Reward: 5 diamonds" | The knowledge itself IS the reward — Naquadah power makes everything easier |
| Checkmark when done | No checkboxes — you just... know things now |

---

## Tech Progression (Integrated with Gate System)

### Stage 1: Desperate Measures (Pre-Gate)
- Stone → Iron tools
- Create: water wheels, millstones, basic mechanical power
- CC: Tweaked: first computer, basic Lua programming
- **Goal**: Understand the gate needs power, start building infrastructure

### Stage 2: The Coal Burn (Early Gate Power)
- Immersive Engineering: coal coke oven, generator
- Create Crafts & Additions: kinetic → FE conversion
- Build massive battery banks
- CC: Tweaked: write first dialing program
- **Reality check**: Coal power CAN run the gate... for about 3 seconds
- **Goal**: Scrape together enough power for ONE gate activation

### Stage 3: The Naquadah Revolution (Post-Tier 1)
- Discover Naquadah in the desert dimension
- Naquadah generators provide 100x the power of coal
- Gate operation becomes practical, not desperate
- Immersive Engineering mid-tier: diesel, external heater
- Create mid-tier: encased fans, mechanical crafters
- **Goal**: Establish reliable off-world operations

### Stage 4: Industrial Age (Tier 2-3)
- Mekanism: full processing chains, enrichment chambers
- AE2: digital storage, autocrafting
- CC: Tweaked: sophisticated programs, gate network management
- Create: full automation of material processing
- **Goal**: Process dimension-specific materials, automate gate operations

### Stage 5: Fusion Age (Tier 4)
- Mekanism: fusion reactor
- Zero Point Modules (Stargate Journey)
- Ultimate power generation
- Full AE2 network spanning bases across dimensions
- **Goal**: Power the final gate address

---

## CC: Tweaked Integration Deep Dive

The gate is controlled through the **Stargate Interface** peripheral in CC: Tweaked. Key methods available:

### Basic Information
- `getStargateEnergy()` — current stored energy
- `getChevronsEngaged()` — symbols locked so far
- `isStargateConnected()` — wormhole status
- `isWormholeOpen()` — can you walk through?
- `getOpenTime()` — how long connection has been active
- `getStargateType()` — gate generation info

### Milky Way Dialing (Manual Ring Control)
- `rotateClockwise(symbol)` — rotate the inner ring
- `rotateAntiClockwise(symbol)` — rotate the inner ring
- `openChevron()` — open the next chevron
- `closeChevron()` — lock the chevron
- `isChevronOpen()` — chevron state

### Address Management
- `getLocalAddress()` — your gate's address
- `getConnectedAddress()` — where you're connected to
- `getDialedAddress()` — what's currently being dialed
- `engageSymbol(symbol)` — engage a symbol
- `disconnectStargate()` — close the wormhole

### Events (Asynchronous)
- Gate incoming connection events
- Chevron engagement events
- Connection/disconnection events
- Energy level change events

### Player-Written Programs (Discoverable as Data Crystals)
Players can find or craft floppy disks containing pre-written programs:
- **Basic Dialer** — enter an address, it dials
- **Energy Monitor** — alerts when power is sufficient for activation
- **Address Scanner** — attempts random dials, logs which connect (EXPENSIVE)
- **Auto-Return** — sets a timer, auto-dials home before power runs out
- **Network Database** — store and organize discovered addresses

---

## Custom Mods We'll Build

### 1. Stargate Ascension (Core Mod)
**Java / NeoForge MDK**

Registers and implements:
- **Data Crystal items** — different types (knowledge, address, symbol, tech, log)
- **Symbol Fragment items** — collectible pieces that reveal address symbols
- **Custom loot tables** — crystal drops from structures, bosses, ores
- **Dimensional ores** — new ore types per tier (Naquadah variants, Celestite, Abyssalite, Eternium)
- **Tiered armor/tools** — crafted from dimension-specific materials
- **Custom worldgen structures** — ancient ruins, temples, data crystal caches
- **Address discovery mechanics** — combining fragments, decoding systems
- **Integration with Stargate Journey API** — hook into gate events, power requirements
- **Hazard mechanics** — dimension-specific environmental effects (if KubeJS can't handle it)

### 2. KubeJS Scripts (Extensive)
- Custom recipes for all cross-mod interactions
- Loot injection for data crystals in existing structures
- Dimension-specific ore gen configuration
- Boss drop tables with tier-appropriate loot
- Gate power requirement scaling per dimension tier
- Advancement triggers for technology crystal unlocks
- Environmental hazard effects (damage over time in toxic worlds)
- Mining dimension address generation system

---

## Reward Philosophy

**The reward IS the discovery.**

| Action | Reward |
|--------|--------|
| Find and explore ancient ruins | Data crystal with gate knowledge |
| Figure out CC: Tweaked dialing | Gate opens — another world to explore |
| Survive the desert dimension | Naquadah — gate power is now easy |
| Beat the Twilight Forest bosses | Address to the Sky Realms |
| Program an auto-dialer | Never manually dial again |
| Find a safe mining world | Unlimited ore access |
| Dial a hazardous world and survive | Rare materials, unique loot |
| Process dimension-specific materials | Next-tier gear and tools |
| Build AE2 autocrafting | Full automation across dimensions |
| Reach The Void and win | Ability to build your own Stargates |

No fake rewards. No "here's 5 diamonds." The world gives you what you earned through understanding.

---

## Supporting Mod List

### Core System
| Mod | Role |
|-----|------|
| **Stargate Journey** | Gate mechanics, Naquadah, dimensions, CC integration |
| **CC: Tweaked** | Computer control, programming, automation |
| **Advanced Peripherals** | Extended CC capabilities |
| **RFTools Dimensions** | Procedural mining worlds |
| **RFTools Base/Power/Utility** | Supporting RFTools ecosystem |
| **KubeJS** | Custom recipes, loot, events, gating |

### Tech & Power
| Mod | Role |
|-----|------|
| Create (+ Crafts & Additions) | Early kinetic tech, FE bridge |
| Immersive Engineering | Mid-tier power, multiblocks |
| Mekanism (+ Generators, Tools) | Late-tier processing, fusion power |
| Applied Energistics 2 | Digital storage, autocrafting |
| XNet | Networking across dimensions |

### Dimensions & Worldgen
| Mod | Role |
|-----|------|
| Terralith | Overworld biome overhaul |
| Incendium | Nether overhaul |
| Nullscape | End overhaul |
| BetterEnd | End biomes + materials |
| Twilight Forest | Tier 2 progression dimension |
| The Aether (+ Deep Aether) | Tier 3 sky dimension |
| The Undergarden | Tier 4 hostile dimension |
| Deeper and Darker | Tier 4 deep dimension |
| Dimensional Doors | Mystery pocket dimensions |

### Combat & Mobs
| Mod | Role |
|-----|------|
| TaCZ | Guns and firearms |
| Immersive Aircraft | Exploration flight |
| Mowzie's Mobs | High-quality boss encounters |
| Bosses of Mass Destruction | Endgame bosses |
| Alex's Mobs | Creature diversity |
| L2 Hostility | Mob difficulty scaling |

### Utilities
| Mod | Role |
|-----|------|
| JEI | Recipe viewing |
| Sophisticated Storage | Tiered storage |
| Supplementaries | QoL blocks |
| Curios / Accessories | Accessory slots |
| Waystones | Intra-dimension teleportation |
| Sinytra Connector | Fabric mod compatibility |

---

## Open Questions
- [x] ~~Underground start?~~ → No, standard Overworld start
- [x] ~~Quest book?~~ → No, data crystal discovery system
- [x] ~~DHD with gate?~~ → No, forces CC: Tweaked programming
- [ ] Use Stargate Journey's built-in dimensions (Abydos, etc.) or fully custom?
- [ ] RFTools Dimensions — how much control over hazard generation? (Need testing)
- [ ] Can KubeJS handle environmental hazards (toxic atmosphere, etc.) or need custom mod?
- [ ] How many random mining world addresses should exist?
- [ ] Data crystal visual: item model, GUI for reading, or both?
- [ ] Pack name — still "Stargate: Ascension" or something else?
- [ ] What's the story? Who built the gates? Why are they here? (This matters for data crystal lore)
- [ ] Multiplayer considerations — shared gates, faction systems?
- [ ] How does the player learn CC: Tweaked? Tutorial crystal? Or figure it out?
