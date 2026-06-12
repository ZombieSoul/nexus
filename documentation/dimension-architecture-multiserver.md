# Dimension Architecture: The Multi-Server Model (EQEmu Approach)

## The Insight

User observation (June 2026): *"Isn't a dimension just another server running the world? Like EverQuest zones / EQEmu. If that could be done efficiently that might be another way to handle dimensions."*

**This is exactly right, and it's precisely what the Luanti engine team is building.**

---

## The Evidence

### PR #14129: `transfer_player` function
- **URL:** https://github.com/luanti-org/luanti/pull/14129
- **Status:** Open, **Concept approved**, updated **Dec 2025**
- **Author:** sfence (rebased from grapereader's original #11175)
- **The author's stated use case** (verbatim):
  > "Transferring to another server can be used in worlds that have dimensions... like space and planets, normal world and nether... etc... It can be good for performance requirements because every dimension can run on different HW."
  >
  > "It is not related until you want to sync inventories for example. **(fly to moon, mine metals, return back to planet and build some technic staff for example)**"

**That last example is LITERALLY our Stargate gameplay loop.** The Luanti engine team designed this feature for exactly the kind of game we're making.

### What's blocking it
- Blocked on **PR #14196** (password security refactor — stops passwords sitting in plaintext in memory)
- #14196 is **"Ready for Review"**, updated **May 2026**
- sfence (Feb 2025): "I do not expect this to move forward soon"
- Target was Luanti 5.12; we're now on **5.16.1** — so it slipped, but it's not abandoned
- **Realistic timeline:** Could land in Luanti 5.17-5.18 (late 2026 / 2027), or we use the proxy now

### The proxy that works TODAY
**`mt-multiserver-proxy`** (https://github.com/HimbeerserverDE/mt-multiserver-proxy)
- Written in Go, ★35, **updated May 2026** (actively maintained)
- Reverse proxy that links multiple Luanti servers
- Clients connect to the proxy; proxy forwards to backend dimension servers
- Transfer happens transparently to the player
- **Works with current Luanti** — no need to wait for #14129

---

## The Architecture

```
                    ┌─────────────────────────┐
                    │     PROXY / BROKER       │
                    │  (mt-multiserver-proxy   │
                    │   OR native transfer     │
                    │   when #14129 lands)     │
                    └────────────┬─────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            │                    │                    │
            ▼                    ▼                    ▼
  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
  │   MILKY WAY      │ │     PEGASUS      │ │    ANDROMEDA     │
  │   server :30000  │ │   server :30001  │ │   server :30002  │
  │                  │ │                  │ │                  │
  │ (Y-stacked dims: │ │ (Y-stacked dims: │ │ (Y-stacked dims: │
  │  Overworld,      │ │  Lantea ocean,   │ │  Tier 4 content, │
  │  Abydos, Chulak, │ │  custom Pegasus  │ │  Undergarden-    │
  │  Nether, End,    │ │  worlds)         │ │  style worlds)   │
  │  Twilight Forest)│ │                  │ │                  │
  │                  │ │  REQUIRES ZPM    │ │  REQUIRES ZPM +  │
  │  CHEAP DIALING   │ │  to reach (100B  │ │  address found   │
  │  (100K FE, inter-│ │  FE intergalactic│ │  in Pegasus      │
  │  stellar Y-jump) │ │  server switch)  │ │  content)        │
  └──────────────────┘ └──────────────────┘ └──────────────────┘
```

### How Stargate Travel Maps

| Action | Energy Cost | Technical Implementation |
|--------|-------------|--------------------------|
| **Dial within galaxy** (Abydos→Chulak) | 100K FE (interstellar) | Y-coordinate teleport within server (instant) |
| **Dial new galaxy** (Milky Way→Pegasus) | **100B FE** (intergalactic / ZPM) | **Server transfer** via proxy/native API |
| **Dial unknown address** (RFTools-style) | 100K FE | Transfer to procedurally-spawned ephemeral server |

**The technical constraint ENFORCES the game design.** Cheap dialing = fast Y-jump within one server. Expensive dialing = full server transfer with loading screen. The loading screen IS the "wormhole travel" moment.

---

## The State-Sync Problem (The Real Work)

EQEmu solved this decades ago: a shared character database that all zone servers read/write. We need the same. When you dial Pegasus, your inventory, health, research progress, and known addresses must come with you.

### The sfence/appgurueu Design (from PR discussion)
Server-to-server state sync is **left to mods**, deliberately. The engine provides:
- `transfer_player(name, address, port)` — moves the client
- **HTTP API** — mods use this to sync state between servers

### Our State-Sync Architecture
```
┌─────────────┐     HTTP/JSON      ┌──────────────────┐
│  Galaxy     │ ◄────────────────► │   SHARED STATE   │
│  Server     │                    │   SERVICE        │
│  (Milky Way)│                    │                  │
└─────────────┘                    │  - Player invent.│
                                   │  - Known addresses│
┌─────────────┐     HTTP/JSON      │  - Tech progress │
│  Galaxy     │ ◄────────────────► │  - ZPM charges   │
│  Server     │                    │  - Quest flags   │
│  (Pegasus)  │                    │                  │
└─────────────┘                    └──────────────────┘
```

**Implementation (Lua mod, ships with the game):**
1. On transfer: mod serializes player state → POST to shared state service
2. Shared state service = tiny bundled HTTP server (or simple file-based for local)
3. On arrival at new server: mod GETs player state → restores inventory/progress
4. Verified via HMAC-SHA256 shared secret (per red-001's suggestion in PR discussion)

**This is the bulk of the custom engineering.** It's well-defined work: serialize, transfer, restore. AI-assisted, this is weeks not months.

---

## Singleplayer = Local Server (Decided)

**Decision (June 2026): Client-server is the primary and only architecture.**

No hybrid code paths. No Y-stack fallback. The multi-server model is the model.

### How "singleplayer" works
There is no separate singleplayer mode. To play solo, the player **runs the server locally and connects to it as the only client.** This is handled by a launcher script that:
1. Starts the proxy broker
2. Starts the galaxy server processes (localhost ports)
3. Connects the client to `localhost:30000`

From the player's perspective: click "Play," the launcher does the rest, they're in the game. From the system's perspective: it's identical to a multiplayer server with one player. **One code path, tested one way.**

### Why this is the right call
- **Eliminates the biggest complexity** — no dual Y-stack/multi-server backend to maintain
- **Aligns with Luanti culture** — hosted server is the norm; singleplayer is just local hosting
- **Matches EQEmu exactly** — EQEmu is server-first too; solo players run their own server
- **State sync is the same code** whether local or remote
- **Resource cost is honest** — the player's machine runs N galaxy servers. Fine for modern hardware with 2-3 active galaxies. We lazy-start galaxy servers on first dial so only visited galaxies consume resources

### The launcher (ships with the game)
```
play.sh / play.bat
  ├── Starts mt-multiserver-proxy on :30000
  ├── Registers galaxy servers (config-driven)
  ├── Spawns Milky Way server immediately (home galaxy)
  ├── Spawns other galaxies on first dial (lazy)
  ├── Launches Luanti client → connects to localhost:30000
  └── On exit: saves & stops servers
```

Config file (`galaxies.conf`) lets server admins add/remove galaxies, set ports, bind addresses for real multi-host deployments. Local players never touch it — defaults just work.

---

## Decision Matrix: Where This Leaves Us

| Question | Answer |
|----------|--------|
| Does Luanti support multi-server dimensions? | **Yes, today, via proxy.** Native support coming (PR #14129) |
| Is this a hack or the intended design? | **Intended.** Engine team explicitly designed `transfer_player` for "dimensions like space and planets" |
| Does our power scaling map to it? | **Perfectly.** Y-jump = cheap, server-transfer = expensive (ZPM) |
| Is state sync solved? | **By us, in Lua.** Well-defined work, not research |
| Can we start now? | **Yes.** Proxy works on current Luanti 5.16 |
| Singleplayer? | **Hybrid approach.** Y-stack locally, multi-server on dedicated hosts |
| Risk? | **Moderate.** Depends on proxy stability + our state-sync implementation. Both tractable |

---

## Revised Effort Estimate (Multi-Server Approach)

| Component | Effort (AI-assisted) |
|-----------|---------------------|
| Stargate mod (portal, dialing, symbols) | 2-3 weeks |
| Energy system (generation, storage, tiered costs) | 1-2 weeks |
| Y-stacked dimension framework (within galaxy) | 1-2 weeks |
| **Multi-server transfer + state sync** | **3-4 weeks** (the new piece) |
| Data crystals + loot | 1 week |
| Computer/programming integration | 1-2 weeks |
| First galaxy content (5-6 dimensions) | 3-4 weeks |
| **Vertical slice MVP** | **~3-4 months** |

This is longer than the "couple months" optimistic estimate, but it's a *real* timeline for a *working* game, not a toy. Committing to client-server-only (no hybrid) keeps it clean — one backend to build and test.

---

## Comparison: Multi-Server vs Pure Y-Stack

| | Multi-Server (EQEmu) | Pure Y-Stack |
|---|---|---|
| Galaxy separation | ✅ Real (separate processes) | ❌ Fake (all one world) |
| Performance | ✅ Scales per dimension | ❌ One world, one bottleneck |
| Power-scaling mapping | ✅ Perfect (cheap jump vs expensive transfer) | ⚠️ Forced (all just Y-teleports) |
| Loading screens as travel moment | ✅ Natural | ❌ None (instant) |
| Singleplayer | ✅ Local server (one code path) | ✅ Native |
| Implementation complexity | ⚠️ Higher (state sync) | ✅ Lower |
| Future-proofing | ✅ Aligns with engine roadmap (#14129) | ⚠️ Dead-end architecture |
| Authentic to Stargate feel | ✅ Wormhole = loading screen | ❌ Teleport = no drama |

**The multi-server model wins across the board** now that singleplayer is just local hosting.

---

## Recommendation (Committed)

**The EQEmu / multi-server model is THE architecture. Client-server only, no hybrid.** Singleplayer = run the server locally.

This is:
1. What the engine team is building toward (#14129)
2. Workable today via the proxy
3. A perfect match for our power-scaling design
4. Authentic to the Stargate fantasy (wormhole travel = server transfer)
5. **One code path** — no singleplayer/server branching to maintain

**Next step:** Prototype the transfer + state sync on a local 2-server setup. Prove the player can dial from Milky Way server to Pegasus server and arrive with their inventory intact. That's the riskiest piece, and de-risking it unlocks everything else.
