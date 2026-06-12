# Stargate: Ascension — Design Document v3

## Vision
A Minecraft 1.21.1 NeoForge modpack about **discovery through technology**. Start in a vanilla+ Overworld. Find a massive alien ring in ancient ruins — no controls, no manual, no power. Build tech, write code, pour energy into the unknown. When it works, it opens a portal to another world. The knowledge you find there changes everything.

No quest book. No hand-holding. Learn by exploring, finding data crystals and floppy disks, and reverse-engineering Ancient technology.

---

## The Stargate

### Finding the Gate
- Spawns in an ancient ruin structure within ~500 blocks of spawn
- Structure is partially collapsed/buried — clearly ancient
- **No DHD present** — there is no clicky dial interface
- Just a silent ring covered in strange symbols
- Stargate Journey naturally spawns these as worldgen structures (various biome variants)

### The Power Problem
- Gate requires **massive energy** to establish a wormhole
- Coal/wood power is technically possible but wildly impractical
  - IE coal generator: maybe runs the gate for 2-3 seconds
  - You'd need warehouses full of coal generators to buffer enough power
- **Create** kinetic→FE (via Create Crafts & Additions) is the first realistic approach
- **Immersive Engineering** biodiesel is the first *practical* approach
- **Naquadah** (discovered Tier 1) changes everything — but you don't know that yet

### No DHD = You Must Program
The Milky Way gate's CC: Tweaked API is **physical**:
```lua
-- Your first janky dial attempt
local gate = peripheral.find("stargate")
gate.engageSymbol(1)
gate.engageSymbol(5)  
gate.engageSymbol(12)
gate.engageSymbol(7)
gate.engageSymbol(3)
gate.engageSymbol(22)
gate.engageSymbol(9)
-- Point of origin (symbol 0)
gate.engageSymbol(0)
-- Did it work?
print(gate.isStargateConnected())
```

Later, players write sophisticated auto-dialers:
```lua
-- An evolved program, weeks later
local ADDRESSES = {
  home = {1, 5, 12, 7, 3, 22, 9, 0},
  desert = {4, 8, 15, 16, 23, 42, 1, 0},
  -- More discovered over time
}

function dial(name)
  local addr = ADDRESSES[name]
  if not addr then error("Unknown: " .. name) end
  if gate.getStargateEnergy() < POWER_THRESHOLD then
    error("Insufficient power!")
  end
  for _, sym in ipairs(addr) do
    gate.engageSymbol(sym)
  end
end
```

### The Non-Programmer Path: Found Floppy Disks
Not everyone wants to write Lua. The alternative: **find programs on floppy disks.**

CC: Tweaked has a built-in **Treasure Disk** system — floppy disks with pre-written Lua programs that spawn in dungeon loot. The mod auto-injects these into vanilla dungeon chests, mineshafts, and strongholds. We extend this:

**Our custom treasure disks** (via resource pack or KubeJS) appear in:
- **When Dungeons Arise** dungeon chests (massive roguelike dungeons)
- **YUNG's Better Dungeons/Strongholds** loot
- Any dungeon mod's loot tables (KubeJS injection)
- Off-world structure loot
- Boss drops

#### Discoverable Programs (Tiered)

**Tier 0 — Basic Computing (Found in Overworld dungeons)**
- `"startup"` — Basic computer boot script, teaches print/peripheral.wrap
- `"gate_status"` — Reads gate energy, chevrons, connection status. Teaching tool.
- `"first_dial"` — A hardcoded dialer for ONE address (the first known address). Not flexible, but it works.

**Tier 1 — Getting Practical (Found in Tier 1 structures/dungeons)**
- `"simple_dialer"` — Enter an address as arguments, it dials. First "real" tool.
- `"power_monitor"` — Monitors gate energy, warns when sufficient for activation
- `"gate_logger"` — Records all gate events to a file. Debugging/learning tool.

**Tier 2 — Automation (Found in Tier 2+ structures)**
- `"auto_dialer"` — Saved address database, one-command dialing
- `"address_scanner"` — Attempts random dials, logs which connect (EXTREMELY expensive on power)
- `"return_program"` — Auto-dials home on a timer, safety net for expeditions

**Tier 3+ — Advanced**
- `"network_hub"` — Manage multiple gate connections, routing
- `"expedition_scanner"` — Probe a world before stepping through (read dimension data)
- `"gate_alert"` — Incoming wormhole detection, security lockdown

**Design principle**: Found programs are *good enough*. Players who learn to code can write better versions. Non-programmers can still progress by finding better disks. Both paths are valid.

---

## The Data Crystal System

Instead of a quest book, information comes from **data crystals** — in-world items.

### Crystal Types

**Knowledge Crystals** (Blue)
- Right-click to read — displays text in chat
- Teach mechanics: "Naquadah ore can be refined in an Arc Furnace to produce..."
- Found in: structures, dungeon loot, boss drops

**Address Crystals** (Gold)  
- Contain complete or partial Stargate addresses
- Some have all 7+1 symbols, some have fragments with missing symbols
- Found in: deep structures, boss drops, crafted from fragments

**Symbol Crystals** (Green)
- Reveal a specific symbol and its position in the dialing sequence
- The "alphabet" of gate addresses
- Found in: scattered throughout all dimensions, rare

**Technology Crystals** (Red)
- Unlock recipe knowledge — triggers Minecraft advancements
- "The Ancients combined Naquadah with steel in a precise ratio..."
- Unlocks the recipe in JEI and makes it craftable
- **This replaces quest rewards** — the knowledge IS the reward

**Log Crystals** (White)
- Story/lore entries — journal entries from previous gate travelers
- "Day 47: The desert world has deposits of a strange metal. It hums when touched..."
- Atmospheric, world-building, hints at what's ahead

### Implementation
- Custom items via **KubeJS** startup scripts
- Right-click → chat message with formatted text
- KubeJS loot injection places them in dungeon chests across all dungeon mods
- Technology crystals trigger `Advancement` unlocks via KubeJS events
- Crystals can chain: Crystal A hints at Crystal B's location

---

## Dimensional Tiers

### Tier 0 — The Overworld ("Earth")
**Difficulty:** Vanilla-easy | **Gate Status:** Found, unpowered, no DHD

Vanilla+ with Terralith. Normal Minecraft until you find the gate ruin.

- Tech path: Create → Immersive Engineering → first CC: Tweaked computers
- First data crystal found deeper in the ruin (contains first known address)
- Overworld dungeons (When Dungeons Arise, YUNG's) contain floppy disks with basic gate programs
- **Goal**: Power up, write or find a dialing program, step through

### Tier 1 — "The Desert World" (Abydos or Custom)
**Difficulty:** Medium | **Gate Status:** First wormhole

Stargate Journey's Abydos is a **desert planet with 3 biomes**: desert, sand spires, and oases. It has ancient city structures and cartouche monuments. We can use this as-is or enhance it.

- **The Naquadah Discovery**: Data crystal in a desert temple explains Naquadah generators
- Naquadah ore found underground — changes gate power from "desperate" to "easy"
- Temple boss drops symbol fragments for next address
- **This is the "ah-ha" moment**: everything about the gate gets easier after this

**Decision needed**: Use Stargate Journey's Abydos dimension (ready-made, fits canon, has structures) or build a custom desert dimension with our own worldgen?

### Tier 2 — "The Dark Forest" (Twilight Forest)
**Difficulty:** Medium-Hard | **Gate Status:** Requires Naquadah power

The Twilight Forest. Built-in boss chain progression. Dense, dark, dangerous.

- Naga → Lich → Hydra → Knight Phantom → Ur-Ghast
- Each boss drops unique materials + data crystal fragments
- Steeleaf, Fiery Ingot needed for Tier 3 gear
- Final TF boss reveals complete address for Tier 3

### Tier 3 — "Sky Realms" (Aether + BetterEnd)
**Difficulty:** Hard | **Gate Status:** Requires advanced power

Floating islands, alien landscapes. Multiple sub-dimensions.

- The Aether: dungeon crawling, sky fortresses
- BetterEnd/Nullscape: enhanced End dimension
- Resources require Mekanism-tier processing
- AE2 becomes essential

### Tier 4 — "The Abyss" (Undergarden + Deeper and Darker)
**Difficulty:** Very Hard | **Gate Status:** Heavy Naquadah + fusion

Hostile underground dimensions. Environmental hazards. Lethal mobs.

- Requires Tier 3 armor for environmental protection
- Living metals, soul-forged alloys
- Deepest data crystals reveal the final address

### Tier 5 — "The Void" (Endgame)
**Difficulty:** Extreme | **Gate Status:** Everything you've built

Final dimension. Boss rush. Ultimate rewards.

- Beat it: learn to **construct your own Stargates**
- Build a gate network across all your worlds
- Creative-flight items, ultimate tools, cosmetic rewards

---

## Mining Dimensions (Procedural)

**RFTools Dimensions** generates random worlds when players dial unknown addresses.

### The Hazard System
Random conditions make mining worlds challenging:
- **Flooded** — gate underwater, possibly hundreds of blocks deep
- **Toxic atmosphere** — damage without proper armor
- **Eternal darkness** — constant mob spawning
- **Scorched** — fire/lava surface
- **Void islands** — thin platforms over void
- **Unstable** — random cave-ins
- **Hostile life** — dense, high-level mob spawning

### Risk/Reward Loop
- Random addresses → random worlds → unknown danger level
- CC programs can "probe" before stepping through
- Better gear = safer expeditions
- Good mining worlds are incredibly valuable
- Death = items stranded in a hostile dimension

---

## Mod List

### Core System
| Mod | Role |
|-----|------|
| **Stargate Journey** | Gate mechanics, Naquadah, CC integration, built-in dimensions |
| **CC: Tweaked** | Computer control, treasure disk system |
| **Advanced Peripherals** | Extended CC capabilities |
| **RFTools Dimensions** | Procedural mining worlds |
| **RFTools (Base/Power/Utility)** | RFTools ecosystem |
| **KubeJS** | Custom recipes, loot, crystals, gating |

### Tech & Power
| Mod | Role |
|-----|------|
| Create (+ Crafts & Additions) | Early kinetic tech, FE bridge |
| Immersive Engineering | Mid-tier power, multiblocks |
| Mekanism (+ Generators, Tools) | Late-tier processing, fusion |
| Applied Energistics 2 | Digital storage, autocrafting |
| XNet | Networking |

### Dimensions & Worldgen
| Mod | Role |
|-----|------|
| Terralith | Overworld overhaul (100+ biomes) |
| Incendium | Nether overhaul |
| Nullscape | End overhaul |
| BetterEnd | End biomes + materials |
| Twilight Forest | Tier 2 dimension |
| The Aether | Tier 3 sky dimension |
| The Undergarden | Tier 4 hostile dimension |
| Deeper and Darker | Tier 4 deep dimension |

### Dungeons & Exploration
| Mod | Role |
|-----|------|
| When Dungeons Arise | Massive roguelike dungeons (floppy disk source) |
| YUNG's Better Dungeons | Enhanced dungeon generation |
| YUNG's Better Strongholds | Stronghold overhaul |
| YUNG's Better Mineshafts | Mineshaft overhaul |
| YUNG's Better Desert Temples | Desert temple overhaul |
| Dungeons and Taverns | Additional dungeon variants |

### Combat & Mobs
| Mod | Role |
|-----|------|
| TaCZ | Guns and firearms |
| Immersive Aircraft | Exploration flight |
| Mowzie's Mobs | Boss encounters |
| Bosses of Mass Destruction | Endgame bosses |
| Alex's Mobs | Creature diversity |
| L2 Hostility | Mob difficulty scaling |

### Utilities
| Mod | Role |
|-----|------|
| JEI | Recipe viewing |
| Sophisticated Storage | Tiered storage |
| Supplementaries | QoL blocks |
| Waystones | Intra-dimension teleport |
| Sinytra Connector | Fabric mod compat |

---

## Custom Content We Build

### 1. Stargate Ascension Mod (Java/NeoForge)
- Data Crystal items (5 types, each with GUI/read mechanic)
- Symbol Fragment collectibles
- Custom worldgen structures (ruin variants, crystal caches)
- Dimensional ores (Naquadah variants, Celestite, Abyssalite, Eternium)
- Tiered armor/tools from dimension-specific materials
- Address discovery/decoding mechanics
- Environmental hazard system (toxic atmosphere, etc.)
- Integration with Stargate Journey API

### 2. KubeJS Scripts
- Data crystal loot injection across all dungeon mods
- Custom recipes (cross-mod interactions, tier gating)
- Technology crystal → advancement unlock triggers
- Dimension-specific ore generation config
- Boss drop tables
- Gate power scaling per dimension tier

### 3. CC: Tweaked Treasure Disk Pack
- Custom floppy disk programs (tiered discovery)
- Resource pack adds our programs to CC: Tweaked's treasure disk system
- Programs found in dungeons across all dimensions

---

## Reward Philosophy

**The reward IS the knowledge. You don't get quest rewards. You get smarter.**

| What you do | What you get |
|-------------|-------------|
| Find ancient ruins | Data crystal with gate knowledge |
| Figure out CC: Tweaked | Gate opens — another world |
| Explore Overworld dungeons | Floppy disks with gate control programs |
| Survive the desert world | Naquadah — gate power is now practical |
| Beat Twilight Forest bosses | Address to the Sky Realms |
| Find a safe mining world | Unlimited ore access |
| Survive a hazardous mining world | Rare materials, unique loot |
| Find technology crystals | Recipe unlocks (gated behind knowledge) |

---

## Open Decisions
- [ ] **Use Stargate Journey's Abydos/Chulak dimensions?** They're ready-made but simple (desert + forest). We could enhance them or build custom.
- [ ] **Pack name** — "Stargate: Ascension" is a placeholder
- [ ] **The Ancients lore** — flesh out as pack develops
- [ ] **How many random mining dimensions?** RFTools can generate infinite; do we limit?
- [ ] **CC: Tweaked learning curve** — is the first floppy disk ("startup" + "gate_status") enough to teach non-programmers?
- [ ] **Do data crystals have a GUI** (book-like) or just chat output? GUI is more polished but more dev work
- [ ] **Technology crystal recipe unlocks** — KubeJS advancement trigger vs. custom unlock system?
