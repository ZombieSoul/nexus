# Nexus Space Protocol v1.0

## Spacecraft Travel, Zone Topology, and the Unified Travel Model

**Status:** Design phase — extends `nexus-api-spec.md` and `nexus-gate-protocol.md`.
**Codename:** `nexus`

---

## 1. The Unified Travel Model

We now have **two ways to travel between zones**, both built on the same nexus backend:

| | Gate Travel | Space Travel |
|---|---|---|
| **Trigger** | Walk into a linked gate | Reach orbital altitude in a spacecraft |
| **Speed** | Instant (wormhole) | Travel time (fly there) |
| **Requirements** | Functional gate at both ends | A spacecraft, fuel |
| **Risk** | Low (established wormhole) | High (space hazards, combat) |
| **Use case** | Routine travel | Reaching un-gated worlds, repairing broken gates, exploration |
| **Payload** | Player + inventory | Player + inventory + **the ship itself** |

**This is the core gameplay loop:** Gates are the fast lane (when they work). Space travel is the slow, dangerous alternative (when gates are broken, or for reaching places without gates). The tension between the two drives progression — you want gates because space is dangerous, but you need ships to build and repair gates.

---

## 2. Zone Topology

### 2.1 The Zone Hierarchy

Each galaxy has three zone types. Each zone is a server (or server group) behind the proxy:

```
GALAXY ALPHA                         GALAXY BETA
├── alpha_surface  (the planet)      ├── beta_surface  (the planet)
├── alpha_orbit    (space above)     ├── beta_orbit    (space above)
└── [shared] hyperspace (between galaxies)
```

### 2.2 Zone Definitions

| Zone | Description | Travel In | Travel Out |
|------|-------------|-----------|------------|
| **Surface** | The planet. Where bases, gates, and resources are. | Land from orbit, gate from another surface | Launch to orbit (altitude + ship) |
| **Orbit** | Space around a planet. Docking, ship-to-ship combat, orbital stations. | Launch from surface, hyperspace from another orbit | Land on surface, hyperspace to another orbit |
| **Hyperspace** | The transit zone between galaxies. The "long flight." | Hyperspace jump from any orbit | Exit to destination orbit |

### 2.3 Travel Matrix

```
                    ┌─────────────┐
                    │  SURFACE    │
                    │  (planet)   │
                    └──┬───────┬──┘
              launch   │       │  land
            (altitude) │       │ (dock)
                       ▼       │
                    ┌──────────┐
                    │  ORBIT   │
                    │ (space)  │
                    └──┬───────┘
             hyperspace │
              (jump)    │
                         ▼
                    ┌──────────────┐
                    │  HYPERSPACE  │ ── exit ──► destination ORBIT
                    │  (transit)   │
                    └──────────────┘

Gate (surface↔surface): instant, bypasses orbit and hyperspace entirely
```

**Gate travel shortcuts the entire space layer.** That's the point — gates are the reward for investing in infrastructure. Space travel is the baseline that gates make obsolete.

### 2.4 Proxy Server Config (Updated)

```json
{
  "Servers": {
    "alpha_surface": { "Addr": "127.0.0.1:30000", "MediaPool": "alpha" },
    "alpha_orbit":   { "Addr": "127.0.0.1:30001", "MediaPool": "alpha" },
    "beta_surface":  { "Addr": "127.0.0.1:30002", "MediaPool": "beta" },
    "beta_orbit":    { "Addr": "127.0.0.1:30003", "MediaPool": "beta" },
    "hyperspace":    { "Addr": "127.0.0.1:30004", "MediaPool": "core" }
  }
}
```

Each surface+orbit pair shares a media pool (same textures/models). Hyperspace has its own minimal pool (stars, ship, HUD).

---

## 3. The Spacecraft

### 3.1 Design Philosophy

The ship is **your ship.** It has:
- A type/class (scout, hauler, fighter — determined by how you built it)
- Health/damage state
- Fuel level
- Cargo inventory
- Modifications/upgrades

It transfers with you between zones. You don't get a different ship in orbit — you fly YOUR ship up, and YOUR ship appears in orbit.

### 3.2 Ship as a Luanti Entity

The ship is a `LuaEntity` the player attaches to (like boats/minecarts in Luanti):

```lua
core.register_entity("nexus:spacecraft", {
    initial_properties = {
        visual = "mesh",
        mesh = "spacecraft.obj",
        textures = {"spacecraft.png"},
        physical = true,
        collide_with_objects = true,
        collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
        hp_max = 100,
        -- Ship is pointable so you can interact/mount
        pointable = true,
    },

    -- Ship runtime state (NOT initial_properties — these are dynamic)
    ship_type = "scout",        -- determined by construction
    fuel = 100,                 -- 0-100
    max_fuel = 100,
    cargo = {},                 -- serialized inventory
    owner = "",                 -- player who owns this ship
    velocity_cache = {x=0,y=0,z=0},
    
    on_activate = function(self, staticdata, dtime_s)
        -- Restore from staticdata (used for both server save AND zone transfer)
        if staticdata and staticdata ~= "" then
            local data = core.deserialize(staticdata)
            self.ship_type = data.ship_type
            self.fuel = data.fuel
            self.cargo = data.cargo
            self.owner = data.owner
        end
    end,
    
    get_staticdata = function(self)
        -- This is called on unload, server save, AND before zone transfer
        return core.serialize({
            ship_type = self.ship_type,
            fuel = self.fuel,
            cargo = self.cargo,
            owner = self.owner,
        })
    end,
    
    on_step = function(self, dtime, moveresult)
        -- Physics, fuel consumption, movement controls
        nexus.ship.flight_step(self, dtime)
    end,
    
    on_rightclick = function(self, clicker)
        -- Mount the ship
        local pname = clicker:get_player_name()
        clicker:set_attach(self.object, "", {x=0, y=0, z=0}, {x=0, y=0, z=0})
        self.driver = pname
    end,
})
```

### 3.3 Ship Construction (Decided: Progressive Shipyard)

**Decision:** Ships are built at a **shipyard structure** that constructs the spacecraft progressively as you feed it materials.

**The shipyard is a multi-block structure** with a controller block that holds a formspec inventory. Players insert materials (hull plating, engine parts, fuel tank, control systems) and the ship visibly takes shape as requirements are met. This is a crafting-and-assembly experience, not an instant spawn.

**How it works:**

1. **Build the shipyard.** A 3×3 platform of shipyard blocks with a controller in the center. It has a build inventory visible via right-click formspec.
2. **Insert materials in stages.** The formspec shows required components and current progress:
   ```
   ┌─ Shipyard: Scout Class ─────────────────┐
   │ Hull Frame:    [████████████] 60/60  ✓  │
   │ Hull Plating:  [██████░░░░░░] 24/40     │
   │ Engine:        [✓] 1/1                ✓  │
   │ Fuel Tank:     [✓] 1/1                ✓  │
   │ Control Sys:   [░░░░░░░░░░░░] 0/12      │
   │                                          │
   │ Progress: 72%   [Launch when complete]   │
   └──────────────────────────────────────────┘
   ```
3. **Visual progress.** As stages complete, the ship model assembles in-world above the shipyard (frame → plating → engine → complete). Players see their ship being built.
4. **Launch.** When all requirements are met, the "Launch" button activates. The ship entity spawns, the player mounts, and they can fly.

**Ship classes determine the material requirements:**

| Class | Role | Materials (more) | Stats (rough) |
|-------|------|-----------------|---------------|
| Scout | Fast, fragile, cheap | Low | Low HP, low cargo, high speed |
| Hauler | Slow, tough, big cargo | Medium | High HP, high cargo, low speed |
| Fighter | Combat-focused | High | Medium HP, weapons, medium speed |

**Why progressive construction instead of instant craft:**
- It's a **milestone moment.** Building your first ship should feel like an achievement, not a button click.
- It creates a **resource sink** that anchors the early game economy.
- It's **visually rewarding** — you watch the ship come together.
- It naturally gates progression: you can't rush to space until you've gathered and assembled.

**Persistence:** The shipyard structure is a node with metadata (the build inventory). If a player walks away mid-build, progress is saved. Abandoned shipyards can be found by other players and completed/claimed (FFA ships — see §12).

**Repair:** The same shipyard can repair a damaged ship. Dock the ship at the shipyard (fly into its pad), and the formspec shows damage; insert repair materials to restore hull integrity.

### 3.4 Ship State Format

```json
{
  "entity_type": "nexus:spacecraft",
  "ship_type": "scout",
  "health": 85,
  "max_health": 100,
  "fuel": 73,
  "max_fuel": 100,
  "owner": "alice",
  "position": {"x": 0, "y": 1500, "z": 0},
  "velocity": {"x": 0, "y": 5, "z": 12},
  "rotation": {"x": 0, "y": 1.57, "z": 0},
  "cargo": {
    "main": { "size": 16, "slots": { "1": {"name":"default:iron", "count":30} } }
  },
  "upgrades": ["nexus:shield_mk1", "nexus:warp_drive"]
}
```

---

## 4. Ship Transfer Protocol

The ship transfers as **data** (like items in the gate protocol), while the player transfers as a **connection hop**. On arrival, the ship is recreated and the player is attached.

### 4.1 The Transfer Flow

```
PLAYER IN SHIP REACHES ORBITAL ALTITUDE (or triggers hyperspace)
│
├─ 1. Altitude trigger detects threshold crossed (in ship, not on foot)
├─ 2. Validate: ship has fuel, player is the driver, destination zone exists
├─ 3. Capture player state (inventory, meta, extensions) — same as gate travel
├─ 4. Capture ship state (serialize entity via get_staticdata + position/velocity)
├─ 5. Detach player from ship (clean up before hop)
├─ 6. Remove ship entity from origin server
├─ 7. POST /nexus/depart with state + ship data
│      state.extensions.ship = { ... ship state ... }
├─ 8. Plugin: cc.Hop(destination_zone) → player connection transfers
│
│   ─── player arrives on destination zone ───
│
├─ 9. on_joinplayer fires
├─ 10. GET /nexus/state/alice → receive state
├─ 11. Restore player inventory + meta
├─ 12. Check: does state.extensions.ship exist?
├─ 13. YES → recreate ship:
│      ├─ core.add_entity(arrival_pos, "nexus:spacecraft", ship_staticdata)
│      ├─ Set ship velocity and rotation from state
│      ├─ Attach player to ship: player:set_attach(ship_obj, ...)
│      └─ Player is flying again, in their ship, in the new zone
├─ 14. DELETE /nexus/state/alice
├─ 15. nexus.on_arrive callbacks fire
```

### 4.2 Ship as a State Extension

The ship piggybacks on the existing state system. It's just another registered handler:

```lua
-- Register ship state handler (runs on both surface and orbit servers)
nexus.state.register_handler("ship", {
    capture = function(player)
        local ship = nexus.ship.get_player_ship(player)
        if not ship then return nil end
        
        local entity = ship:get_luaentity()
        return {
            entity_type = "nexus:spacecraft",
            ship_type = entity.ship_type,
            health = entity.object:get_hp(),
            fuel = entity.fuel,
            cargo = nexus.ship.serialize_cargo(entity),
            owner = entity.owner,
            position = ship:get_pos(),
            velocity = ship:get_velocity(),
            rotation = ship:get_rotation(),
            upgrades = entity.upgrades or {},
        }
    end,
    
    restore = function(player, data)
        if not data then return end  -- player had no ship
        
        -- Wait for the world around spawn to load
        core.after(0.5, function()
            local pos = data.position or player:get_pos()
            local staticdata = core.serialize({
                ship_type = data.ship_type,
                fuel = data.fuel,
                cargo = data.cargo,
                owner = data.owner,
                upgrades = data.upgrades,
            })
            local ship_obj = core.add_entity(pos, data.entity_type, staticdata)
            if ship_obj then
                ship_obj:set_velocity(data.velocity or {x=0,y=0,z=0})
                ship_obj:set_rotation(data.rotation or {x=0,y=0,z=0})
                ship_obj:set_hp(data.health or 100)
                -- Attach player
                player:set_attach(ship_obj, "", {x=0,y=5,z=0}, {x=0,y=0,z=0})
                -- Store reference for flight controls
                nexus.ship.bind(ship_obj, player:get_player_name())
            end
        end)
    end,
})
```

**This is the elegant part.** The ship transfer requires **zero new protocol.** It's a state extension handler — exactly the mechanism designed in §3.2 of the base spec. The nexus system was built to be extensible, and this is the proof.

### 4.3 Arrival Position

Unlike gate travel (arrive at a specific gate), space travel arrival is **free-form**:
- **Launch (surface→orbit):** Arrive at the orbital altitude directly above the launch point. If you launched at (X, Z), you arrive in orbit at (X, orbit_altitude, Z).
- **Land (orbit→surface):** Arrive at the surface directly below the orbit position.
- **Hyperspace (orbit→orbit):** Arrive at a designated entry point in the destination orbit (a "hyperspace beacon" or default position).

This means position is **continuous across zones** — your X/Z coordinates are preserved. Only the server (and therefore the world) changes.

---

## 5. Zone Transitions (The Triggers)

### 5.1 Launch: Surface → Orbit

```lua
--- Triggered when a player in a ship crosses the orbital altitude threshold.
--- This is an upward transition.
local ORBITAL_THRESHOLD = 1500  -- Y coordinate; configurable per zone

core.register_globalstep(function(dtime)
    for _, player in ipairs(core.get_connected_players()) do
        local pos = player:get_pos()
        local ship = nexus.ship.get_player_ship(player)
        
        if ship and pos.y >= ORBITAL_THRESHOLD then
            -- Player is in a ship, above the threshold → launch
            nexus.zone.transfer(player, "alpha_orbit", {
                trigger = "launch",
                preserve_xz = true,  -- keep X/Z coordinates
                arrival_y = ORBITAL_THRESHOLD + 100,  -- arrive well into orbit
            })
        end
    end
end)
```

**Fuel check:** Launching requires fuel. If the ship is out of fuel, the threshold is a hard ceiling — the ship can't climb past it (enforced by the ship's flight physics, not just the transfer).

### 5.2 Land: Orbit → Surface

```lua
--- Triggered when a player in a ship descends below the orbital floor.
local ORBITAL_FLOOR = 1400  -- slightly below threshold to prevent flicker

core.register_globalstep(function(dtime)
    for _, player in ipairs(core.get_connected_players()) do
        local pos = player:get_pos()
        local ship = nexus.ship.get_player_ship(player)
        
        if ship and pos.y <= ORBITAL_FLOOR then
            nexus.zone.transfer(player, "alpha_surface", {
                trigger = "land",
                preserve_xz = true,
                arrival_y = ORBITAL_FLOOR - 100,  -- arrive in upper atmosphere
            })
        end
    end
end)
```

**Hysteresis:** The threshold (1500) and floor (1400) are different values to prevent oscillation — a player bobbing at the boundary won't rapid-fire transfers.

### 5.3 Hyperspace Jump: Orbit → Orbit

Hyperspace is player-initiated, not altitude-triggered. The player selects a destination and the ship jumps:

```lua
--- Initiate a hyperspace jump to another galaxy's orbit.
--- Requires: ship with hyperspace drive upgrade, sufficient fuel.
--- @param player ObjectRef|string
--- @param destination_orbit string   e.g. "beta_orbit"
--- @return boolean success
--- @return string? error
nexus.ship.hyperspace_jump(player, "beta_orbit")
```

**The jump sequence:**
1. Validate: ship has hyperspace drive + fuel for the jump
2. Transfer to `hyperspace` zone (the transit server)
3. Player flies through hyperspace (visual: starfield streaking, timer counts down)
4. **Hyperspace events can occur** (see §5.5 — danger time, encounters)
5. After travel time (or on reaching exit point), transfer to `destination_orbit`
6. Arrive at destination orbit's entry point

This is **two transfers** (orbit → hyperspace → orbit), but each uses the same mechanism. The hyperspace zone is a thin server — just stars, the ship, and a HUD. It exists to give travel a sense of duration and danger.

### 5.5 Hyperspace Events (Built-In Danger Time)

**Decision:** Hyperspace travel time is **not just a waiting period** — it has built-in danger time so that encounters and events can happen along the way. Travel isn't a loading screen; it's gameplay.

**Travel duration:** Fixed minimum (so the danger window always exists), plus the player must fly to an exit point. Rough target: **30-60 seconds** of active travel for a standard jump, long enough for events but short enough to not be tedious.

**The exit mechanic:** The player doesn't just wait for a timer. They must fly toward an exit beacon visible in the hyperspace tunnel. They can fly straight (boring, safe, faster) or take evasive action (slower, survives events). This gives the player agency over their own risk.

**Event system:** During the flight, the hyperspace zone can spawn encounters based on a weighted event table. Events are throttled (not constant) so there's tension between calm and danger:

| Event | Effect | Player Response |
|-------|--------|----------------|
| **Clear passage** | Nothing happens — reach exit safely | Fly straight |
| **Turbulence** | Ship is buffeted, course deviates, minor damage | Steer against the drift |
| **Energy surge** | Drains shields/fuel; bright flash | Ride it out or reroute |
| **Debris field** | Asteroid-like obstacles in the tunnel | Dodge |
| **Hyperspace creature** (future) | Something lives in hyperspace; attacks | Fight or flee |
| **Signal anomaly** | Distress beacon, derelict ship, anomaly | Investigate (risk) or ignore |

**Event scheduling (design):**
- At least one event per jump (so hyperspace is never trivial), weighted toward low-severity
- Higher-tier jumps (further galaxies) → more events, higher severity
- Nav computer upgrade → earlier warning of upcoming events (HUD shows "turbulence ahead")
- Events are **per-player-instance** in hyperspace (each traveler gets their own tunnel) — no cross-player interference in v1

**Why danger time matters:** Without it, hyperspace is a loading screen. With it, hyperspace is the risk that makes gates valuable. A player whose ship is barely holding together should dread hyperspace; a player in a well-equipped ship should feel competent surviving it. That tension is the gameplay.

**Failure in hyperspace:** If the ship is destroyed in hyperspace, the player is ejected into the destination orbit in a life pod (§8.2) — they survive but lose the ship. This prevents hyperspace from being a hard wall while keeping the consequences real.

### 5.6 The Generic Zone Transfer API

All three triggers call the same function:

```lua
--- Transfer a player to a different zone. This is the underlying mechanism
--- for launch, land, hyperspace, and could support other transitions.
--- @param player ObjectRef|string
--- @param destination_zone string    Server name in proxy config
--- @param opts table                 { trigger, preserve_xz, arrival_y, arrival_pos }
--- @return boolean success
--- @return string? error
nexus.zone.transfer(player, destination_zone, opts)
```

**Options:**
- `preserve_xz = true` — keep the player's X/Z coordinates on arrival (for launch/land)
- `arrival_y = N` — override the Y coordinate on arrival
- `arrival_pos = vector` — exact arrival position (overrides preserve_xz)
- `trigger = "launch" | "land" | "hyperspace" | "custom"` — for logging and callbacks

---

## 6. Space Dangers

Space is dangerous. That's why gates are valuable. The danger design:

### 6.1 Environmental Hazards

| Hazard | Zone | Effect |
|--------|------|--------|
| **Asteroid fields** | Orbit | Collisions damage ship; dense fields block flight paths |
| **Solar radiation** | Orbit (near sun) | Drains ship shields; requires shielding upgrade |
| **Debris fields** | Orbit (after battles) | Navigation hazard; can contain salvageable scrap |
| **Hyperspace instability** | Hyperspace | Random course deviations; requires active piloting or nav computer |
| **Fuel exhaustion** | Any zone in space | Ship goes dead; drift until rescue or refuel |

### 6.2 Combat

Ship-to-ship combat in orbit and hyperspace:
- Ships have weapons (forward-facing, like classic space sims)
- Ships have shields (absorb damage before hull)
- Hull damage reduces ship health; ship destruction = player ejects (and must be rescued)
- **PvP is zone-dependent:** Safe orbits (near friendly stations) disable PvP; deep space enables it

### 6.3 Death in Space

If a player dies in space (ship destroyed, suffocation):
- They respawn at their **last docked station** (orbit) or **home base** (surface)
- Their ship is destroyed (but cargo may drop as salvageable wreckage)
- This is harsher than surface death (where you might keep some items) — space is dangerous by design

### 6.4 Energy System Integration

Space travel is fuel-gated. The energy system (separate design) provides:
- Ship fuel (consumed by flight, launches, hyperspace jumps)
- Station power (for orbital docks, repair bays)
- Gate power (for surface gates — the link between the two systems)

**The progression loop:**
```
Mine resources → refine fuel → fly to orbit → hyperspace to new galaxy →
land on planet → build/repair gate → use gate for instant travel next time
```

Gates are the culmination of space investment. You do the dangerous space journey ONCE to set up a gate, then use the gate forever.

---

## 7. Integration With Gate System

### 7.1 The Relationship

| You have a gate | You don't have a gate |
|-----------------|----------------------|
| Instant travel between worlds | Must travel by ship through space |
| Low risk | High risk |
| Requires energy at both ends | Requires fuel |

### 7.2 Repairing Broken Gates (The Core Mission)

When a gate is destroyed (§7 of gate protocol), players can't gate to that world. To fix it:

1. Fly to the destination world by ship (surface → orbit → hyperspace → orbit → land)
2. Navigate to the broken gate site
3. Repair or rebuild the gate (requires materials + crafting)
4. Re-register the gate with the proxy
5. Gate links can be re-established

This is a **mission structure:** "Gate Beta-1 is down. Fly there and repair it." It's dangerous because space is dangerous, and rewarding because the gate makes future travel trivial.

### 7.3 Gate Construction on New Worlds

To establish a NEW gate link to an un-gated world:
1. Fly there by ship (the first voyage — dangerous, unknown)
2. Construct a gate from materials
3. Register the gate with the proxy
4. Dial back to your home gate to establish the link
5. Now both worlds have instant gate access

**First contact is always by ship.** Gates come after. This is the exploration loop.

---

## 8. Failure Handling (Space-Specific)

### 8.1 Transfer Failure Mid-Launch

If the hop fails (destination server down):
- Player stays on origin server
- Ship is NOT removed (the entity removal happens after hop succeeds, with rollback)
- Player gets error: "Orbital transfer failed. Destination unreachable."
- Ship may be at the altitude threshold — physics continue normally

**Implementation detail:** Ship removal must happen AFTER hop confirmation, or we risk losing the ship on a failed transfer. The state machine handles this:

```
1. Capture state (ship data serialized)
2. POST /depart
3. WAIT for depart confirmation (not async for ship transfers)
4. Remove ship entity
5. Hop
6. If hop fails → respawn ship from captured data (rollback)
```

### 8.2 Ship Lost in Transfer

If the transfer succeeds but ship recreation fails on destination:
- Player arrives without a ship (floating in space — bad!)
- Emergency: spawn a "life pod" entity the player can attach to
- Life pod has minimal flight capability (slow, no weapons) — enough to reach a station
- Log the incident; the ship data is retained in state for manual recovery

### 8.3 Player Disconnects in Space

If a player disconnects while in a ship in orbit/hyperspace:
- Ship entity saves to world (via `get_staticdata`)
- On reconnect, player spawns at the ship's position (if same zone) or last station
- Ship is not lost — it persists in the world like any entity

---

## 9. Updated HTTP API

Adds zone transfer endpoints to the proxy plugin:

### `POST /nexus/zone/transfer`
```json
{
  "player": "alice",
  "destination_zone": "alpha_orbit",
  "trigger": "launch",
  "state": { /* full state including ship extension */ },
  "arrival": { "preserve_xz": true, "y": 1600 }
}
```

Same response/cleanup pattern as `/depart`. The proxy validates the destination zone exists and is reachable.

### `GET /nexus/zones`
Returns all zones and their relationships:
```json
{
  "zones": [
    { "name": "alpha_surface", "galaxy": "alpha", "type": "surface", "available": true },
    { "name": "alpha_orbit", "galaxy": "alpha", "type": "orbit", "available": true },
    { "name": "hyperspace", "galaxy": null, "type": "transit", "available": true }
  ]
}
```

### `GET /nexus/zones/:galaxy`
Returns the zones for a specific galaxy:
```json
{
  "galaxy": "alpha",
  "surface": "alpha_surface",
  "orbit": "alpha_orbit"
}
```

---

## 10. Updated Lua API Summary

### Travel Functions (Complete Set)

```lua
-- Gate travel (instant, requires linked gates)
nexus.gate.travel_player(player, gate_address)
nexus.gate.establish_link(from, to, opts)
nexus.gate.close_link(gate_address)
nexus.gate.send_item(gate_address, itemstack, velocity, owner)

-- Zone travel (space travel, altitude/hyperspace triggered)
nexus.zone.transfer(player, destination_zone, opts)
nexus.ship.hyperspace_jump(player, destination_orbit)

-- Ship management
nexus.ship.get_player_ship(player)     -- get the ship entity a player is piloting
nexus.ship.bind(ship_obj, player_name) -- associate ship with player
nexus.ship.serialize_cargo(entity)     -- get cargo as transferable data
```

### State Handlers (Registered)

| Handler | Captures | Used By |
|---------|----------|---------|
| `core` | HP, breath, physics | All travel |
| `inventory` | Player inventory | All travel |
| `player_meta` | Player metadata | All travel |
| `ship` | Ship entity state | Space travel only |
| *(extensible)* | Custom game state | Any mod |

### Callbacks

```lua
nexus.on_depart(fn(player, destination))      -- before any departure
nexus.on_arrive(fn(player, origin, state))     -- after any arrival + restore
nexus.on_travel_failed(fn(player, reason, stage))

-- Zone-specific
nexus.zone.on_launch(fn(player, from_zone, to_zone))   -- surface→orbit
nexus.zone.on_land(fn(player, from_zone, to_zone))     -- orbit→surface
nexus.zone.on_hyperspace(fn(player, to_zone))          -- entering hyperspace
```

---

## 11. Build Order (Space System)

Adds to the existing build order (base spec + gate protocol):

| Step | Component | Validates | Est. Effort |
|------|-----------|-----------|-------------|
| 1-17 | *(base + gate systems)* | Gate travel + item transfer works | 34 hrs |
| **18** | Zone config in proxy | Multiple zones per galaxy route correctly | 1 hr |
| **19** | Ship entity (registration, physics, attachment) | Player can build/mount/fly a ship | 4 hrs |
| **20** | Ship state handler (capture/restore) | Ship serializes correctly | 2 hrs |
| **21** | Launch trigger (altitude threshold) | Fly up → arrive in orbit with ship | 2 hrs |
| **22** | Land trigger (orbital floor) | Fly down → arrive on surface with ship | 1 hr |
| **23** | Zone transfer endpoint + flow | Ship survives cross-zone transfer | 3 hrs |
| **24** | Hyperspace zone + jump sequence | Orbit → hyperspace → destination orbit | 3 hrs |
| **25** | Ship rollback on failed transfer | Failed hop doesn't lose the ship | 2 hrs |
| **26** | Space hazards (asteroids, basic combat) | Space is dangerous | 4 hrs |
| **27** | Integration: full space→gate repair mission | Fly to broken gate, repair it, dial home | 3 hrs |

**Total: ~25 hours** for the space system (on top of the 34 for base + gates = **~59 hours total**).

---

## 12. Design Decisions (Locked)

All previously-open questions are now decided.

1. **Ship building: PROGRESSIVE SHIPYARD (Decided).** Ships are built at a multi-block shipyard structure that constructs the spacecraft progressively as the player feeds it materials. Visual assembly, staged requirements, a milestone moment — not instant craft. See §3.3 for full detail.

2. **Players per ship: ONE (v1).** One player per ship (pilot) for v1. The entity attachment system supports multi-crew later. Flight control model for multiple roles is complex and deferred.

3. **Orbit server scope: COMPACT, EXPANDABLE (Decided).** Orbit is a compact zone (roughly 2000×2000×400 blocks) — enough to be a real space arena, small enough to stay performant and focused. **The zone config is data-driven** so additional/larger zones can be added if players find space fun. Start simple, expand based on playtesting.

4. **Hyperspace travel time: BUILT-IN DANGER TIME (Decided).** Hyperspace is not a timer — it has active danger time with events and encounters along the way. Roughly 30-60 seconds of travel with a player-flown exit mechanic. See §5.5 for the full event system design.

5. **Ship theft: FFA FOR NOW (Decided).** Ships are free-for-all in v1 — no ownership system. Anyone can mount an unattended ship. An ownership/permission system is a separate concern that can be layered on later (it's a general anti-griefing system that would also apply to chests, bases, etc.). For now, keep ships with you or accept the risk. **Wreckage (from destroyed ships) is always FFA salvage.**

6. **NPCs in space: NONE in v1.** No pirates, aliens, or automated defenses in v1. The danger comes from environmental hazards (asteroids, radiation, hyperspace events) and PvP. NPCs are v2+ content design.

7. **Multiple planets per galaxy: ONE IN v1, API-READY (Decided).** Each galaxy has exactly one planet (one surface zone) in v1. **The zone topology API is designed to support multiple planets per galaxy** (each planet = a surface zone reachable via orbital flight). Adding planets is a config + content change, not an architecture change. The `nexus.zone` API and proxy config already treat zones generically.

8. **Docking stations: ONE SPAWN STATION in v1.** Each orbit has a single safe spawn station where players arrive and can dock. Player-built orbital stations are v2 (it's just building blocks in the orbit world — the protocol supports it).
