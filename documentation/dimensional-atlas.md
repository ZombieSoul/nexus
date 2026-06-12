# Dimensional Atlas — Stargate: Ascension

## Dimension Roles & Hierarchy

Not every dimension is a progression gate. Some are alternatives, some are resources, some are just options. The design principle is: **the player discovers what works, not us telling them.**

---

## Tier 0 — The Overworld ("Earth")
**Power Tier:** None → Basic | **Gate Status:** Found, unpowered, no DHD

Vanilla+ with Terralith. Standard Minecraft start. The Stargate is out there somewhere — ancient ruins, partially buried, a mystery waiting.

- No DHD — must use CC: Tweaked to interface
- Tech path: Create → Immersive Engineering → first computers
- Overworld dungeons (When Dungeons Arise, YUNG's) contain floppy disks with basic gate programs
- First data crystal found in the gate ruin contains the first known address
- **Goal**: Power up, write or find a dialing program, step through

---

## Tier 1 — Abydos ("The Desert World")
**Power Tier:** Basic | **Gate Status:** First wormhole

**Built into Stargate Journey** — a desert planet with 3 biomes:
- **Desert** — vast sand dunes, the primary landscape
- **Sand Spires** — towering sandstone formations (high erosion parameter)
- **Oasis** — rare temperate zones with water and vegetation

**Structures:**
- Ancient city ruins (multiple NBT structure pieces)
- Cartouche monuments — stone tablets containing addresses to OTHER dimensions (Nether, End, other planets)
- Stargate on a pedestal (with DHD on-site)

**Our additions via KubeJS/Custom Mod:**
- Inject Naquadah ore generation underground
- Data crystals in temples teaching Naquadah processing
- Temple boss encounters (enhanced mobs via L2 Hostility)
- Boss drops = symbol fragments for next address
- **THE discovery**: Naquadah makes gate power practical instead of desperate

**Why it works as Tier 1:** It's a complete, ready-made desert dimension with ruins and exploration. We enhance it rather than replace it. The cartouche monuments even contain addresses to other worlds — built-in address discovery!

---

## Chulak ("The Homestead Option")
**Power Tier:** N/A | **Role:** Alternate base dimension, optional

**Built into Stargate Journey** — a forest planet with 2 biomes:
- **Chulak Plains** — dry, open grasslands
- **Chulak Forest** — temperate forests with good tree coverage

**Structures:**
- Stargate on a pedestal — **with a DHD present and functional**
- Cartouche monuments containing addresses (to Abydos, Nether, End, other worlds)

**Why it's brilliant as an option:**
- **Has a working DHD** — no CC: Tweaked needed to dial from here
- Safe, pleasant biome — good for building a secondary base
- Cartouche gives you free addresses to explore
- A player who dials here from Earth could theoretically skip the whole "learn CC programming" arc and just live here
- But: you still need to power Earth's gate to get home, and Chulak has no Naquadah...
- **Creates interesting choices**: Do you live on Chulak where dialing is easy? Or stay on Earth where the resources are?

**Design intent:** Options without railroading. Chulak is the "easy mode" gate world. It's safe and has a DHD. But it doesn't advance your tech — you need Abydos for that.

---

## Cavum Tenebrae ("The Crushed World")
**Power Tier:** High | **Role:** Extreme hazard dimension / high-tier mining

**Built into Stargate Journey** — a planet being torn apart by a nearby black hole.

**What it actually generates:**
- **Sea level: 128** (half the world is below "water" level)
- **Default block: Deepslate** — the entire world is made of deepslate
- **Default fluid: LAVA** — lava oceans, not water
- **Single biome**: "Shattered Crust" — no vegetation, no passive mobs, no precipitation
- **Sky color**: Dark reddish-purple (992561)
- **Fog color**: Dark, oppressive (332314)
- **Aggressive terrain**: x2 horizontal, x4 vertical noise scaling = extreme jagged terrain
- **No natural mob spawning** (empty spawner lists)
- **Rich ores**: Iron, gold, redstone, diamond, lapis, copper — all pushed upward
- **Custom diamond generation**: Extra diamond veins in upper layers (sgjourney:ore_diamond_upper)
- **Lava springs everywhere**

**This place is HELL.** A deepslate world with lava oceans, shattered terrain, and diamond-rich deposits. The vertical noise x4 means massive cliffs and voids. No natural mob spawning means the danger is environmental — falling, lava, darkness.

**Uses in our pack:**
- **Late-game mining dimension**: Come here for diamonds and deepslate when Overworld is tapped
- **Address discovered mid-game** from a cartouche or data crystal
- Environmental hazards require fire protection gear at minimum
- The lava fluid + deepslate aesthetic is completely unique
- Could place Naquadah here too as the "hard mode" alternative to Abydos

---

## Lantea ("The Drowned Gate")
**Power Tier:** Advanced | **Role:** Water challenge dimension

**Built into Stargate Journey** — an ocean planet. Atlantis's resting place.

**What it actually generates:**
- **Sea level: 256** — in a 512-height world, HALF the world is underwater
- **Single biome**: Lantean Deep Ocean
- **Pegasus Stargate** variant (different from Milky Way gates — different symbol set, different dialing)
- **Lantean Outpost structure** spawns in the ocean — the Atlantis gate room
- **Gate and DHD are protected** (can't be broken)
- **Uses a Pegasus stargate variant** called "atlantis"

**The gameplay:**
- You dial Lantea. The gate opens. You step through...
- **Into an underwater structure.** The gate room is submerged or partially submerged.
- You need to either:
  - Drain the area (Create pumps, IE pipes)
  - Use water breathing
  - Build submarine equipment
- The Pegasus gate uses a DIFFERENT symbol set — you need to discover those symbols too
- The outpost contains unique Ancient technology, data crystals, maybe even a Zero Point Module
- A fixed base in the ocean could become an underwater headquarters

**Uses in our pack:**
- **Tier 3-4 challenge**: Advanced water engineering needed
- Introduces the Pegasus gate system (second symbol set to learn)
- Atlantis outpost as a dungeon to explore and claim
- Story significance: This is where the Ancients lived
- Could contain endgame-related lore and technology

---

## Nether & End ("Vanilla Enhanced")
Enhanced by Incendium, BetterNether, BetterEnd, Nullscape.

- The Nether and End are accessible through Stargate Journey cartouches (Abydos and Chulak both list them as addresses)
- This means players can dial INTO the Nether/End instead of using portals — alternate access
- Enhanced worldgen makes these worth exploring
- Standard resources plus dimension-specific materials
- The End Dragon fight enhanced via mods

---

## Twilight Forest ("The Dark Forest")
**Power Tier:** Intermediate | **Role:** Tier 2 progression dimension

Classic Twilight Forest. Dense, dark, structured boss progression.

- Naga → Lich → Hydra → Knight Phantom → Ur-Ghast
- Each boss drops unique materials + data crystal fragments
- Steeleaf, Fiery Ingot needed for Tier 3 gear
- Address discovered via Abydos boss drops or data crystal fragments
- The address to TF is gated behind completing Tier 1 content

---

## The Aether ("Sky Realms")
**Power Tier:** Advanced | **Role:** Tier 3 sky dimension

Floating islands, unique mobs, dungeon crawling. Accessible alongside BetterEnd.

- Requires Tier 2 materials for survival here
- Aether dungeons contain advanced data crystals
- Unique Aether materials for Tier 3-4 gear

---

## The Undergarden + Deeper and Darker ("The Abyss")
**Power Tier:** High | **Role:** Tier 4 hostile dimension

Underground horror dimensions. Environmental hazards. Lethal mobs.

- Requires Tier 3 armor for protection
- Living metals, soul-forged alloys
- Deepest data crystals
- L2 Hostility at maximum scaling

---

## Tier 5 — The Void (Custom / Endgame)
**Power Tier:** Extreme | **Role:** Final challenge

Custom dimension or RFTools. Boss rush. Ultimate rewards. Learn to build Stargates.

---

## RFTools Mining Dimensions (Procedural)

When a player dials an address that isn't any known dimension, RFTools generates a random world. These are the **mining dimensions** — potentially resource-rich, potentially deadly.

**Hazard possibilities:**
- Flooded (gate underwater)
- Toxic atmosphere (damage over time)
- Eternal darkness
- Scorched (lava/fire)
- Void islands
- Unstable terrain
- Dense hostile mobs

**Risk/reward:** Random addresses = random worlds. Good ones are goldmines. Bad ones are death traps. CC programs can probe before entering.

---

## Dimensional Web (How They Connect)

```
                        ┌──────────────┐
                        │   OVERWORLD   │ (find gate, no DHD)
                        │   "Earth"     │
                        └──────┬───────┘
                               │ first dial
                    ┌──────────┼──────────┐
                    ▼          ▼          ▼
              ┌──────────┐ ┌────────┐ ┌──────────┐
              │  ABYDOS   │ │ CHULAK │ │ (random   │
              │ "Desert"  │ │"Homest"│ │  mining    │
              │ Tier 1    │ │ Option │ │  worlds)  │
              │ +Naquadah │ │ +DHD   │ │  RFTools  │
              └─────┬─────┘ └───┬────┘ └──────────┘
                    │           │
         ┌──────────┼─────┬────┘
         ▼          ▼     ▼
   ┌───────────┐ ┌──────┐ ┌─────────────────┐
   │CAVUM TEN. │ │NETHER│ │   TWILIGHT      │
   │"Crushed"  │ │Enhncd│ │   FOREST        │
   │Hazard/Mine│ │      │ │   Tier 2        │
   └───────────┘ └──────┘ └────────┬────────┘
                                   │
                        ┌──────────┼──────────┐
                        ▼          ▼          ▼
                  ┌──────────┐ ┌───────┐ ┌─────────┐
                  │ AETHER   │ │  END  │ │ LANTEA  │
                  │"Sky"     │ │Enhncd │ │"Drowned"│
                  │Tier 3    │ │       │ │Challnge │
                  └────┬─────┘ └───────┘ └─────────┘
                       │
              ┌────────┼────────┐
              ▼        ▼        ▼
        ┌──────────┐ ┌──────┐ ┌──────────┐
        │UNDERGARD.│ │DEEP  │ │  THE VOID │
        │"Abyss"   │ │DARK  │ │  Endgame  │
        │Tier 4    │ │Tier 4│ │  Tier 5   │
        └──────────┘ └──────┘ └──────────┘
```

**Key insight**: The cartouche monuments in Abydos and Chulak contain addresses to the Nether, End, and other worlds. This means:
- The Nether and End are discoverable through exploration, not just vanilla portals
- Players who find Chulak first get a different experience than those who find Abydos first
- Multiple paths through the content, not a single railroad
