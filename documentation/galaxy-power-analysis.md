# Galaxy & Power Scaling — Technical Analysis

## TL;DR — The Tier System Is Built In

Stargate Journey already implements a **three-tier power scaling system** based on distance:

| Connection Type | Energy to Connect | Energy/Tick (Maintain) | After Max Time |
|----------------|-------------------|------------------------|----------------|
| **System-wide** (same solar system) | 50,000 FE | 5 FE/t | 50,000 FE/t |
| **Interstellar** (same galaxy, diff system) | 100,000 FE | 50 FE/t | 5,000,000 FE/t |
| **Intergalactic** (different galaxy) | **100,000,000,000 FE** (100B) | **50,000 FE/t** | **5,000,000,000 FE/t** |

**Stargate energy capacity:** 1,000,000,000,000 FE (1 trillion)
**Max receive rate:** Effectively unlimited (10^17 FE/t)

---

## The Galaxy API (Fully Data-Driven)

### Yes — Destinations Are Extensible Via Datapack

Galaxies, solar systems, symbols, and addresses are all **JSON files in custom registries**. We can add our own via a datapack bundled with the modpack.

### Galaxy Definition (Simple JSON)
```json
// data/sgascension/sgjourney/galaxy/void_galaxy.json
{
    "name": "galaxy.sgascension.void",
    "type": "sgjourney:large_galaxy",
    "default_symbols": "sgascension:void_symbols"
}
```

### Galaxy Types (Determines Symbol Count = Address Difficulty)
| Type | Symbols | Canonical Example |
|------|---------|-------------------|
| `dwarf_galaxy` | 36 | Pegasus |
| `medium_galaxy` | 39 | Milky Way |
| `large_galaxy` | 42 | Andromeda |
| `giant_galaxy` | 45 | M87 |
| `supergiant_galaxy` | 48 | IC 1101 |

More symbols = harder to brute-force addresses = naturally "higher tier."

### Solar System Definition (Connects Dimensions to Galaxies)
```json
// data/sgascension/sgjourney/solar_system/void_nexus.json
{
    "name": "solar_system.sgascension.void_nexus",
    "symbols": "sgascension:void_symbols",
    "symbol_prefix": 18,
    "extragalactic_address": {
        "address": [42, 7, 19, 3, 28, 11, 35],
        "randomizable": true
    },
    "addresses": [
        {
            "galaxy": "sgascension:void",
            "address": {
                "address": [3, 14, 27, 8, 22, 15],
                "randomizable": true
            }
        }
    ],
    "point_of_origin": "sgascension:void_origin",
    "dimensions": ["sgascension:void_dimension"]
}
```

**Key fields:**
- `extragalactic_address` — The **8-symbol address** to reach this from another galaxy (requires 100B FE!)
- `addresses` — Within-galaxy addresses (only 100K FE if same galaxy)
- `symbol_prefix` — How many symbols prefix this system's addresses
- `dimensions` — Which Minecraft dimension keys belong here

---

## Built-in Galaxy Roster

Stargate Journey ships with **7 galaxies**:

| Galaxy | Type | Contains |
|--------|------|----------|
| **Milky Way** | Medium (39) | Earth, Abydos, Chulak, Cavum Tenebrae |
| **Pegasus** | Dwarf (36) | Lantea (Atlantis), Athos |
| **Andromeda** | Large (42) | (Empty — ready for content) |
| **Ida** | Dwarf (36) | (Empty — Asgard home in canon) |
| **Othala** | Dwarf (36) | (Empty — Asgard galaxy) |
| **Kaliem** | Medium (39) | (Empty — mod author's custom) |
| **Triangulum** | Dwarf (36) | (Empty) |

**5 of 7 galaxies are empty** — they exist as registries but have no solar systems or dimensions. Perfect canvas for our custom content.

---

## Power Sources (The Tech Gate)

### Available Power Generators
| Power Source | Output | Capacity | Era |
|-------------|--------|----------|-----|
| Coal Generator (IE) | ~40 FE/t | small | Tier 0 — "The Coal Burn" |
| Create kinetic→FE | varies | small | Tier 0 |
| IE Biodiesel Generator | ~256 FE/t | medium | Tier 0-1 |
| **Naquadah Generator Mk I** | **1,000 FE/t** | **100,000 FE** | **Tier 1** |
| **Naquadah Generator Mk II** | **1,200 FE/t** | **1,200,000 FE** | **Tier 2** |
| Fusion Core | 100,000 FE/fuel unit | 65,536 fuel | Tier 3 |
| **ZPM (Zero Point Module)** | **100,000,000,000 FE/entropy** | — | **Tier 3+** |

### Energy Storage
| Storage | Capacity |
|---------|----------|
| Small Naquadah Battery | 5,000,000 FE (5M) |
| **Large Naquadah Battery** | **1,000,000,000 FE (1B)** |
| Stargate Internal Buffer | 1,000,000,000,000 FE (1T) |

---

## The Math: Why This Works Perfectly

### Interstellar Dial (Same Galaxy) — 100,000 FE
```
Naquadah Mk I:  100,000 ÷ 1,000 FE/t  = 100 ticks (5 seconds)
Coal Generator: 100,000 ÷ 40 FE/t     = 2,500 ticks (2 minutes)
```
**Verdict:** Trivial once you have Naquadah. Painful but possible with coal.

### Intergalactic Dial (Cross-Galaxy) — 100,000,000,000 FE
```
Naquadah Mk II: 100,000,000,000 ÷ 1,200 FE/t = 83,333,333 ticks
              = 1,388,888 seconds = 16 DAYS of continuous generation

ZPM (1 entropy level): 100,000,000,000 FE = EXACTLY ONE DIAL
```
**Verdict:** A ZPM gives you exactly one intergalactic connection per charge. This is literally the show's mechanic. Naquadah alone would take 16 days of constant generation to fill the buffer for one dial. The player MUST find/build a ZPM to reach other galaxies.

---

## How Our Tier System Maps to Galaxies

### Galaxy 0 — The Milky Way (Tier 0-2)
**Dialing cost:** Interstellar (100,000 FE)

Contains everything in the "early to mid game":
- **Earth** (Overworld, Tier 0)
- **Abydos** (Desert, Tier 1 — Naquadah discovery)
- **Chulak** (Forest, optional homestead)
- **Cavum Tenebrae** (Crushed World, hazard mining)
- **Twilight Forest** (Tier 2 progression)
- **Nether & End** (vanilla enhanced)

**Power era:** Coal → Naquadah. Everything is reachable with a single Naquadah generator.

### Galaxy 1 — Pegasus (Tier 3)
**Dialing cost:** Intergalactic (100,000,000,000 FE = needs ZPM)

- **Lantea** (Atlantis — the underwater outpost)
- Custom Pegasus dimensions we add

**Power era:** ZPM required. The tech gate from Milky Way → Pegasus is the jump from 100K to 100B FE. This forces the player to:
1. Discover ZPM technology (via data crystals)
2. Build ZPM infrastructure (ZPM Hub)
3. Charge a ZPM (find entropy sources)
4. Use one ZPM charge to dial Pegasus

### Galaxy 2 — Andromeda / Custom (Tier 4)
**Dialing cost:** Intergalactic (100B — same as Pegasus)

Once ZPM infrastructure exists, Andromeda is accessible. We populate it with Tier 4 content (Undergarden-level challenges). The gate isn't power — it's finding the 8-symbol extragalactic address.

### Galaxy 3+ — Our Custom Galaxies (Tier 5)
We create new galaxies (supergiant type = 48 symbols = hardest to address) for endgame content. Power cost stays at 100B (intergalactic), but the address discovery is gated behind progression.

---

## Address Discovery Across Galaxies

The `extragalactic_address` is a **7-symbol + 1 extra chevron** address (8 symbols total). The 8th chevron is what makes it intergalactic.

**Config:** `allow_interstellar_8_chevron_addresses` defaults to `false` — meaning 8-chevron addresses are **only for intergalactic travel**. This is exactly what we want.

### How Players Discover Extragalactic Addresses
1. **Data crystals** found in deep structures contain 8-symbol sequences
2. **Boss drops** from Tier 2+ bosses give symbol fragments
3. **Cartouche monuments** in Abydos/Chulak list some addresses (but NOT the 8-symbol extragalactic ones — those must be discovered through progression)
4. The address to Pegasus/Lantea is found through a multi-step quest chain involving:
   - Data crystals from multiple Milky Way dimensions
   - Combining fragments in a crafting system
   - Using a CC: Tweaked program to decode the assembled fragments

---

## Custom Galaxy Plan

### Galaxies We Add
| Galaxy | Type | Content | Address Found In |
|--------|------|---------|------------------|
| (Pegasus - existing) | Dwarf | Lantea + custom | Tier 2 boss chain |
| Andromeda | Large (42 sym) | Tier 4 content | Pegasus data crystals |
| **The Void** | Supergiant (48 sym) | Tier 5 endgame | Multi-galaxy quest |

### Creating a Galaxy (Steps)
1. **Define galaxy** — JSON in `data/sgascension/sgjourney/galaxy/`
2. **Define symbol set** — JSON in `data/sgascension/sgjourney/symbols/`
3. **Define point of origin** — JSON in `data/sgascension/sgjourney/point_of_origin/`
4. **Define solar system(s)** — JSON linking dimensions to the galaxy
5. **Define dimension(s)** — Standard MC dimension JSON or RFTools
6. **Define worldgen** — Biomes, noise settings, structures
7. **Hide the address** — Only obtainable through data crystal fragments

All of this is **datapack-driven** — no Java mod required for the galaxy/address system itself. We only need custom Java for:
- Data crystal items
- Custom worldgen features
- Environmental hazard mechanics
- GUI for reading crystals

---

## Config Tweaks for Our Pack

```toml
# config/stargate-journey-common.toml

[server]
    # Keep interstellar cheap (Naquadah era)
    interstellar_connection_energy_cost = 100000
    
    # Keep intergalactic at 100B (ZPM requirement)
    intergalactic_connection_energy_cost = 100000000000
    
    # Disable 8-chevron for intra-galaxy (preserve the intergalactic distinction)
    allow_interstellar_8_chevron_addresses = false
    
    # Keep wormhole time reasonable
    max_wormhole_open_time = 228  # 38 minutes (canon)
    
    # Two-way travel disabled by default (like the show)
    two_way_wormholes = "CREATIVE_ONLY"
```

---

## Open Questions Resolved
- ✅ **Does Stargate Journey have a destination API?** Yes — fully data-driven galaxies, solar systems, symbols, and addresses. Extensible via datapack.
- ✅ **Can we tier by galaxy?** Yes — intergalactic connections cost 100B FE (ZPM territory), interstellar cost 100K (Naquadah territory).
- ✅ **Does power naturally gate progression?** Yes — the jump from 100K to 100B forces a massive tech upgrade (Naquadah → ZPM).
- ✅ **Can we add custom galaxies?** Yes — JSON files. 5 empty galaxies already exist as templates.

## Open Questions Remaining
- [ ] Do we use existing empty galaxies (Ida, Othala, Triangulum) or create new ones?
- [ ] How many dimensions per galaxy? (Pegasus should have more than just Lantea)
- [ ] The ZPM charging mechanic — how do players "find entropy"? Need to research ZPM implementation
- [ ] Should we bump intergalactic cost HIGHER than 100B for our custom galaxies? (Config allows up to Long.MAX_VALUE)
- [ ] Can KubeJS intercept the dialing event to add item requirements (e.g., "must hold a specific crystal")?
