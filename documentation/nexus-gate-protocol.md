# Nexus Gate Protocol v1.0

## Gate-to-Gate Travel, Item Transfer, and Gate Lifecycle

**Status:** Design phase — extends `nexus-api-spec.md`.
**Codename:** `nexus` (neutral development name)

---

## 1. The Problem This Solves

The base spec designed travel as **player→galaxy** (spawn at world spawn). This is wrong for a Stargate game. Travel must be:

1. **Gate→gate** — you arrive at a specific gate's position, facing the right direction
2. **Validated** — if the destination gate is destroyed, unpowered, or blocked, travel fails
3. **Linked** — an open connection (wormhole) between two gates, through which multiple things can pass

Additionally, players should be able to **throw items through an open gate** without traveling themselves. This is a fundamentally different mechanism:

| | Player Transfer | Item Transfer |
|---|---|---|
| **Mechanism** | Connection hop (proxy moves the client) | Data transfer (destroy at origin, create at destination) |
| **Latency** | ~100-500ms (hop process) | ~50-200ms (HTTP round-trip) |
| **What moves** | The player's connection | A serialized item |
| **Requires link?** | One-time hop | Gate link must be active |

---

## 2. Core Concepts

### 2.1 Gate

A gate is a physical structure in the world (a multi-node construct or single special block). Each gate has:

- **Address** — unique identifier (e.g. `"alpha:g1"`). Development placeholder; will be symbol-based dialing in the final game.
- **Position** — the block coordinates and a defined **arrival point** (where players/items emerge)
- **Facing** — the direction the gate faces (determines arrival orientation)
- **State** — `inactive`, `outgoing` (dialing), `linked` (wormhole open), `broken`
- **Power** — whether the gate has sufficient energy (checked by the energy system mod)
- **Galaxy** — which server it's on

### 2.2 Gate Link (The Wormhole)

A gate link is an **active connection** between two gates. While linked:

- Players can walk through either gate and arrive at the other
- Items thrown into either gate emerge at the other
- The link has a direction (one-way or bidirectional)
- The link has a duration (timed, or until manually closed)

The link is tracked by the **proxy** (central authority), not by either server. This prevents split-brain when gates are on different galaxies.

### 2.3 The Three Things That Can Travel

| Entity | How | API |
|--------|-----|-----|
| **Players** | Connection hop + state sync | `nexus.gate.travel_player()` |
| **Items** | Data transfer (serialize → recreate) | `nexus.gate.send_item()` |
| **Entities** (future) | Data transfer (serialize → recreate) | `nexus.gate.send_entity()` (v2) |

For v1: players and dropped items only. Projectiles, vehicles, mobs are future work.

---

## 3. Gate Registry

Gates must be registered with the proxy so it can route links and validate destinations. The proxy is the source of truth for gate existence and state.

### 3.1 Gate Registration (Lua → Proxy)

When a gate is constructed or a server starts:

```lua
--- Register a gate with the proxy. Called when a gate structure is completed,
--- or on server startup for all existing gates.
--- @param gate table  Gate definition (see below)
--- @return boolean success
--- @return string? error
nexus.gate.register({
    address = "alpha:g1",           -- unique gate address
    label = "Alpha Gate 1",         -- display name
    position = vector.new(100, 64, -200),  -- gate center block
    arrival_offset = vector.new(0, 0, -2), -- where entities emerge (relative to position)
    facing = 0,                     -- yaw in degrees (arrival direction)
    galaxy = "alpha",               -- this server's galaxy name
})
```

### 3.2 Gate Deregistration

When a gate is destroyed:
```lua
nexus.gate.unregister("alpha:g1")
```

The proxy immediately breaks any active links involving that gate and notifies the linked partner.

### 3.3 Gate State Updates

Power state, obstruction status, etc.:
```lua
nexus.gate.update_state("alpha:g1", {
    powered = true,
    obstructed = false,
})
```

### 3.4 Proxy Gate Registry (Internal)

```json
{
  "alpha:g1": {
    "address": "alpha:g1",
    "label": "Alpha Gate 1",
    "galaxy": "alpha",
    "position": {"x": 100, "y": 64, "z": -200},
    "arrival_offset": {"x": 0, "y": 0, "z": -2},
    "facing": 0,
    "powered": true,
    "obstructed": false,
    "registered_at": 1718200000,
    "last_heartbeat": 1718200030
  }
}
```

---

## 4. Gate Links

### 4.1 Establishing a Link (Dialing)

```lua
--- Attempt to establish a link from one gate to another.
--- This is the "dialing" action. Validates the destination gate exists,
--- is powered, unobstructed, and not already linked.
--- @param from_address string   Origin gate address
--- @param to_address string     Destination gate address
--- @param opts? table           { duration = 38, direction = "bidirectional" }
--- @return boolean success
--- @return string? error        "DESTROYED" | "UNPOWERED" | "OBSTRUCTED" | "BUSY" | "UNREACHABLE"
nexus.gate.establish_link("alpha:g1", "beta:g1", {
    duration = 38,           -- seconds; nil = manual close only
    direction = "bidirectional",  -- or "oneway"
})
```

**Validation sequence (in the proxy):**
1. Does `to_address` exist in registry? → `UNREACHABLE` if not
2. Is `to_address`'s server reachable? → `UNREACHABLE` if galaxy server not running
3. Is `to_address` powered? → `UNPOWERED`
4. Is `to_address` obstructed? → `OBSTRUCTED`
5. Is `to_address` already linked? → `BUSY`
6. All checks pass → create link, notify both gates

**On success:** both gates' servers receive a mod channel notification: `"link_established:alpha:g1<->beta:g1"`. Both gates visually open (event horizon activates).

### 4.2 Link Object

```json
{
  "link_id": "lnk_a1b2",
  "gate_a": "alpha:g1",
  "gate_b": "beta:g1",
  "direction": "bidirectional",
  "opened_by": "alice",
  "opened_at": 1718200000,
  "expires_at": 1718200038,
  "state": "active"
}
```

### 4.3 Closing a Link

```lua
--- Close a gate link. Called when a gate is shut down manually,
--- or automatically when the link timer expires.
--- @param address string   Either gate in the link
nexus.gate.close_link("alpha:g1")
```

### 4.4 Querying Link State

```lua
--- Get the active link for a gate, if any.
--- @param address string
--- @return table? link   Link object or nil if not linked
nexus.gate.get_link("alpha:g1")
-- Returns: { remote_address = "beta:g1", remote_galaxy = "beta", 
--            remote_pos = {...}, direction = "bidirectional", expires_in = 20 }
```

---

## 5. Player Travel (Gate→Gate)

### 5.1 Updated Travel API

The base spec's `nexus.travel(player, galaxy)` is replaced with gate-based travel:

```lua
--- Travel a player through a linked gate to the destination gate.
--- The gate must have an active link. Player is placed at the
--- destination gate's arrival point with correct facing.
--- @param player ObjectRef|string
--- @param gate_address string     The gate the player is entering
--- @return boolean success
--- @return string? error
nexus.gate.travel_player(player, "alpha:g1")
```

Game code typically doesn't call this directly. Instead, a **gate pad trigger** detects the player entering the gate area and calls it automatically (see §5.3).

### 5.2 Arrival Position Calculation

The player must emerge at the destination gate facing the right direction:

```lua
-- When restoring the player on the destination galaxy:
local link = nexus.gate.get_link("beta:g1")  -- this gate's link
local dest_gate = nexus.gate.get_info("beta:g1")

-- Calculate arrival position
local arrival_pos = vector.add(dest_gate.position, dest_gate.arrival_offset)

-- Set player position and facing
player:set_pos(arrival_pos)
player:set_look_horizontal(math.rad(dest_gate.facing))

-- Brief protection so they don't immediately take fall damage
player:set_velocity({x = 0, y = 0, z = 0})
```

**Arrival offset** is defined per-gate at registration. Typically 2 blocks in front of the gate, 1 block up (so you "step out" onto the gate platform).

### 5.3 Gate Pad Trigger (Auto-Travel)

Players shouldn't click a button to travel — they should walk into an open gate. This is an area trigger:

```lua
-- Globalstep that checks for players in active gate zones
local function check_gate_entries(dtime)
    for address, gate in pairs(nexus.gate.get_linked_gates()) do
        local link = nexus.gate.get_link(address)
        if link and link.state == "active" then
            -- Check for players within the gate's trigger radius
            local objects = core.get_objects_inside_radius(gate.position, 1.5)
            for _, obj in ipairs(objects) do
                if obj:is_player() then
                    local pname = obj:get_player_name()
                    -- Don't re-trigger if already traveling
                    if not nexus.internal.is_in_transit(pname) then
                        nexus.gate.travel_player(pname, address)
                    end
                end
            end
        end
    end
end

core.register_globalstep(check_gate_entries)
```

**Anti-loop protection:** When a player arrives at a destination gate, they're flagged `in_transit` for 2 seconds. This prevents them from immediately triggering the return gate and bouncing back.

### 5.4 The Full Player Travel Flow (Revised)

```
PLAYER WALKS INTO LINKED GATE (Alpha)
│
├─ 1. Globalstep detects player in gate trigger radius
├─ 2. Check: gate has active link? player not already in transit?
├─ 3. Flag player as in_transit (prevent re-trigger)
├─ 4. Capture state (inventory, meta, extensions)
├─ 5. Include target gate address in state: { arrival_gate = "beta:g1" }
├─ 6. POST /nexus/depart → proxy stores state
├─ 7. Plugin: cc.Hop("beta") → connection transfers
│
│   ─── player arrives on Beta server ───
│
├─ 8. on_joinplayer fires
├─ 9. GET /nexus/state/alice → receive state
├─ 10. Restore inventory + meta + extensions
├─ 11. Look up arrival gate: state.arrival_gate = "beta:g1"
├─ 12. Calculate arrival position from gate registry
├─ 13. Teleport player to arrival_pos with correct facing
├─ 14. Set 2-second anti-loop protection
├─ 15. DELETE /nexus/state/alice → cleanup
├─ 16. nexus.on_arrive callbacks fire
```

---

## 6. Item Transfer Through Gates

This is the key new subsystem. Items don't use the connection-hop mechanism — they're **destroyed at origin and recreated at destination**.

### 6.1 Design Principles

1. **Items feel instant.** An item thrown into a gate should emerge at the destination within ~1 second (localhost). Cross-server adds network latency.
2. **Velocity is preserved and transformed.** An item thrown fast should exit fast. Direction is mapped to the destination gate's facing.
3. **The link must be active.** Items only travel through open gates. No link, no transfer.
4. **Items are queued at the proxy.** If the destination server is briefly unavailable, items are held and delivered when it's back (within the link duration).

### 6.2 Item Transfer API

```lua
--- Send an item through a linked gate. The item entity is removed
--- at origin and recreated at the destination gate's arrival point.
--- @param gate_address string     Gate the item is entering
--- @param itemstack ItemStack     The item to transfer
--- @param velocity? vector        Item's velocity (for physics continuity)
--- @param owner? string           Player who threw it (for anti-dupe tracking)
--- @return boolean success
nexus.gate.send_item("alpha:g1", ItemStack("default:diamond 5"), 
                     {x = 0, y = 5, z = -3}, "alice")
```

Game code usually doesn't call this directly — a **gate item sensor** detects dropped items entering the gate area and calls it (see §6.4).

### 6.3 Item Transfer Flow

```
ITEM THROWN INTO LINKED GATE (Alpha)
│
├─ 1. Gate item sensor detects item entity in gate radius
├─ 2. Verify: gate has active link, item not already captured
├─ 3. Capture item data: { itemstring, count, wear, meta, velocity, age }
├─ 4. Remove the item entity (itemstack:take_item, entity:remove())
├─ 5. POST /nexus/item → proxy stores item for destination
│      Body: { link_id, destination_gate, item, velocity, owner }
│
│   ─── proxy processes ───
│
├─ 6. Proxy stores item in a per-link queue
├─ 7. Proxy pushes mod channel notification to destination server:
│      "item_arrived:beta:g1"
│
│   ─── destination server receives notification ───
│
├─ 8. Destination Lua: on mod channel message, fetch pending items
├─ 9. GET /nexus/item/beta:g1 → returns queued items
├─ 10. For each item:
│      ├─ Calculate arrival position (gate arrival_offset)
│      ├─ Transform velocity to destination gate's facing
│      ├─ core.add_item(arrival_pos, itemstack)
│      ├─ Set velocity on the new item entity
│      └─ Preserve item age (so it doesn't reset the despawn timer)
└─ 11. DELETE /nexus/item/beta:g1 (clear the queue)
```

**Why mod channel for notification, HTTP for data:** Mod channel messages are tiny and instant — perfect for "hey, something arrived." But item data (with metadata) can be large. HTTP has no size limit. This split gives us instant notification + unlimited payload.

### 6.4 Gate Item Sensor

Dropped items are `__builtin:item` entities. We detect them entering the gate area:

```lua
-- Runs on globalstep, checks for item entities in active gate zones
local timer = 0
core.register_globalstep(function(dtime)
    timer = timer + dtime
    if timer < 0.2 then return end  -- check 5x/second (not every frame)
    timer = 0
    
    for address, gate in pairs(nexus.gate.get_linked_gates()) do
        local objects = core.get_objects_inside_radius(gate.position, 1.5)
        for _, obj in ipairs(objects) do
            local ent = obj:get_luaentity()
            if ent and ent.name == "__builtin:item" then
                -- This is a dropped item in the gate zone
                local itemstack = ItemStack(ent.itemstring)
                local velocity = obj:get_velocity()
                
                -- Send through gate (if not already being captured)
                if not ent._gate_captured then
                    ent._gate_captured = true  -- prevent double-capture
                    nexus.gate.send_item(address, itemstack, velocity)
                    obj:remove()  -- remove from origin
                end
            end
        end
    end
end)
```

**Anti-dupe:** The `_gate_captured` flag on the entity prevents the same item from being sent twice if the globalstep fires again before `obj:remove()` takes effect.

### 6.5 Velocity Transformation

When an item emerges at the destination gate, its velocity should reflect the throw direction, rotated to match the destination gate's facing:

```lua
local function transform_velocity(velocity, origin_facing, dest_facing)
    -- Rotate velocity vector by the difference in gate facings
    local angle_diff = math.rad(dest_facing - origin_facing)
    local cos_a = math.cos(angle_diff)
    local sin_a = math.sin(angle_diff)
    return {
        x = velocity.x * cos_a - velocity.z * sin_a,
        y = velocity.y,  -- vertical unchanged
        z = velocity.x * sin_a + velocity.z * cos_a,
    }
end
```

This means: if you throw an item "into" the gate (away from you), it exits the destination gate "out of" the gate (away from it). The wormhole preserves the throw.

---

## 7. Gate Destruction & Failure Handling

### 7.1 Gate Destroyed While Inactive

No special handling. The gate is unregistered from the proxy. Any saved gate data (known addresses, dialing history) remains in the world's mod storage.

### 7.2 Gate Destroyed While Linked

This is the critical failure case. The gate's server detects destruction (node `on_destruct` callback) and notifies the proxy immediately:

```lua
-- In the gate block's on_destruct
core.register_node("gate_travel:gate_ring", {
    on_destruct = function(pos)
        local address = nexus.gate.address_at(pos)
        if address then
            -- Notify proxy: gate is gone
            nexus.gate.unregister(address)
            -- Proxy breaks the link, notifies partner gate
        end
    end,
})
```

**Proxy response to gate destruction:**
1. Remove gate from registry
2. Find any active link involving this gate
3. Break the link
4. Push mod channel notification to partner gate's server: `"link_broken:beta:g1:DESTROYED"`
5. Partner gate closes its event horizon, plays "connection lost" effect

**Items in transit when gate destroyed:** Items queued at the proxy for the destroyed gate's link are returned to the origin gate's position (if origin still exists) or dropped at the proxy's last known position. No item duplication.

### 7.3 Player In Transit When Destination Gate Destroyed

This is the race condition. The player already hopped; the destination gate is now gone.

**Handling:**
1. Player arrives on destination galaxy (`on_joinplayer`)
2. State restoration proceeds normally
3. Lua mod looks up `state.arrival_gate = "beta:g1"`
4. Queries proxy: `GET /nexus/gate/beta:g1` → returns `404 DESTROYED`
5. **Fallback:** spawn at world spawn with message: *"Destination gate lost. Emergency arrival."*
6. Log the incident for admin review

**Player in transit when ORIGIN gate destroyed:** No problem. The player already left. They arrive at destination normally. The origin gate being gone just means they can't dial back.

### 7.4 Gate Unpowered Mid-Link

If the energy system removes power from a gate while linked:
1. Gate state update: `powered = false`
2. Proxy breaks the link (same as destruction, but reason = `UNPOWERED`)
3. Partner gate closes, shows "power loss" effect
4. Players/items in transit complete their current transfer (link closure doesn't retroactively cancel an in-progress hop)

### 7.5 Server Crash / Disconnect

If a galaxy server crashes while it has linked gates:
1. Proxy detects server disconnect (existing proxy mechanism)
2. All links involving that server's gates are broken
3. When server restarts, it re-registers its gates
4. Links are NOT auto-restored (players must re-dial)

### 7.6 Failure Summary Table

| Scenario | Origin Gate | Dest Gate | Player In Transit | Items In Transit |
|----------|-------------|-----------|-------------------|------------------|
| **Dest gate destroyed (pre-hop)** | Stays open, shows error | N/A | Travel fails, player stays | N/A |
| **Dest gate destroyed (post-hop)** | Unaffected | Gone | Emergency spawn at world spawn | Returned to origin |
| **Origin gate destroyed (post-hop)** | Gone | Unaffected | Arrives normally | N/A |
| **Dest gate unpowered** | Closes link | Closes link | Current hop completes | Returned to origin |
| **Dest server crashes** | Closes link | Offline | Emergency spawn | Held at proxy, expire with link |
| **Proxy restarts** | Links lost | Links lost | State from SQLite, spawn at last gate | Item queue lost (accept this tradeoff) |

---

## 8. HTTP API Additions

New endpoints on the proxy plugin (extends §5 of base spec):

### `POST /nexus/gate/register`
Register or update a gate.
```json
{ "address": "alpha:g1", "label": "Alpha Gate 1", "galaxy": "alpha",
  "position": {"x":100,"y":64,"z":-200}, "arrival_offset": {"x":0,"y":0,"z":-2},
  "facing": 0, "powered": true, "obstructed": false }
```

### `DELETE /nexus/gate/:address`
Unregister a gate (destroyed). Breaks active links.

### `POST /nexus/gate/:address/state`
Update gate power/obstruction state.
```json
{ "powered": false, "obstructed": true }
```

### `GET /nexus/gate/:address`
Query gate info. Returns `404` if not found.
```json
{ "address": "beta:g1", "galaxy": "beta", "powered": true, 
  "linked": true, "link_partner": "alpha:g1" }
```

### `POST /nexus/link`
Establish a gate link (dialing).
```json
{ "from": "alpha:g1", "to": "beta:g1", "duration": 38, "direction": "bidirectional" }
```
**Response:** `200 { "link_id": "lnk_a1b2", "state": "active" }` or `409 { "error": "BUSY", "message": "Destination gate already linked" }`

### `DELETE /nexus/link/:gate_address`
Close a link involving this gate.

### `POST /nexus/item`
Send an item through a link.
```json
{ "link_id": "lnk_a1b2", "entry_gate": "alpha:g1", 
  "item": { "name": "default:diamond", "count": 5, "wear": 0, "meta": {} },
  "velocity": {"x":0,"y":5,"z":-3}, "owner": "alice" }
```

### `GET /nexus/item/:gate_address`
Fetch queued items for a gate (called after mod channel notification).
```json
{ "items": [
  { "item": {...}, "velocity": {...}, "owner": "alice", "entry_gate": "alpha:g1" }
]}
```

### `DELETE /nexus/item/:gate_address`
Clear the item queue after successful retrieval.

---

## 9. Mod Channel Protocol

The proxy pushes notifications to galaxy servers via the `"nexus"` mod channel. Messages are tiny (just event type + identifiers). Full data is fetched via HTTP.

### 9.1 Message Format

All messages are strings: `"<event>:<param1>:<param2>:..."`

| Message | Meaning | Recipient Action |
|---------|---------|-----------------|
| `link_established:alpha:g1:beta:g1` | Link created | Both gates open event horizon |
| `link_broken:alpha:g1:DESTROYED` | Link ended | Close event horizon, show reason |
| `item_arrived:beta:g1` | Item queued for this gate | Fetch items via HTTP |
| `player_incoming:beta:g1:alice` | Player arriving at this gate | Prepare arrival point, clear obstructions |
| `gate_state_changed:alpha:g1` | Gate power/obstruction changed | Update visual indicators |

### 9.2 Reliability

Mod channel messages are **fire-and-forget**. If a server misses one (e.g., during hop), the state can be recovered:
- Items: the queue persists at the proxy; a periodic heartbeat fetches pending items
- Links: servers periodically query their link state via HTTP as a fallback

This dual-path (mod channel for speed + HTTP polling for reliability) ensures no silent failures.

---

## 10. Updated State Format

The player state format (§4 of base spec) gains a gate travel section:

```json
{
  "version": 1,
  "format": "nexus-state",
  "player": "alice",
  "origin": "alpha",
  "destination": "beta",
  "timestamp": 1718200000,
  "request_id": "a1b2c3d4",
  "gate_travel": {
    "departure_gate": "alpha:g1",
    "arrival_gate": "beta:g1",
    "origin_facing": 0,
    "dest_facing": 180
  },
  "core": { "hp": 18, "breath": 10 },
  "inventory": { ... },
  "player_meta": { ... },
  "extensions": { ... }
}
```

The `gate_travel` section tells the destination server exactly where to place the player and what facing to apply.

---

## 11. Updated Build Order

Adds gate and item subsystems to the base spec's build order:

| Step | Component | Validates | Est. Effort |
|------|-----------|-----------|-------------|
| 1-8 | *(base spec: proxy plugin, state, travel core)* | Core transfer works | 15 hrs |
| **9** | Gate registry (register/unregister/query) | Gates tracked by proxy | 2 hrs |
| **10** | Gate links (establish/close/validate) | Wormhole opens between gates | 3 hrs |
| **11** | Gate→gate player travel (arrival positioning) | Player arrives at exact gate pos | 2 hrs |
| **12** | Gate pad trigger (auto-travel on walk-in) | Walk into gate → travel | 1 hr |
| **13** | Item transfer (send/fetch/recreate) | Item thrown through gate emerges at dest | 3 hrs |
| **14** | Velocity transformation | Items exit with correct physics | 1 hr |
| **15** | Destruction & failure handling | Destroyed gate breaks link, safe fallback | 3 hrs |
| **16** | Mod channel notifications | Real-time link/item events | 2 hrs |
| **17** | Integration: full gate-to-gate test | Click→dial→walk through→arrive→throw item | 2 hrs |

**Total: ~34 hours** (base 15 + gate system 19). Still each step independently testable.

---

## 12. Open Questions

1. **Gate as single block or multi-node structure?** A full Stargate ring is ~20+ blocks. Registration needs to handle multi-node gates (one address, multiple positions). v1 prototype: single block. Production: multi-node with a "master" block holding the registration.

2. **Multiple items thrown rapidly — batch or stream?** If a player dumps a chest into a gate, that's many items. The item sensor should batch items per tick and send them in one HTTP request to avoid flooding the proxy. API supports this: `POST /nexus/item` accepts an array.

3. **Item ownership and anti-dupe.** When an item is thrown through a gate, we track the owner. This is for logging and anti-exploit (e.g., preventing item dupe glitches). Should the destination item retain the original owner metadata? Yes — preserve item metadata fully.

4. **Link directionality: BIDIRECTIONAL (Decided).** Gates are bidirectional. Both players and items can travel in either direction through an established link. Rationale: one-way links would require indicating to players whether a gate is currently transmitting or receiving — a whole additional UI/UX complexity that would frustrate players. Bidirectional is simpler to understand, more player-friendly, and matches our game format. (Classic Stargate is one-way, but our game is not classic Stargate — it's our own lore, TBD.) The protocol field `direction` remains in the data model for future special-case gates, but the default and only supported mode in v1 is `"bidirectional"`.

5. **Gate obstruction.** What counts as "obstructed"? A block on the gate pad? A player standing on it? A mob? Needs a clear rule for the validation check. Recommend: any solid block or entity in the arrival zone = obstructed.

6. **What about liquids (water flowing through)?** Stargate lore: wormholes prevent matter from entering the wrong way, but let energy through. For our game: liquids do NOT transfer through gates (only players and items). Document as a design rule.

7. **Energy cost per transfer.** Does throwing 100 items through a gate cost more energy than 1? Does a player traveling cost more than an item? This ties into the energy system design (separate doc). The protocol supports per-transfer cost hooks.
