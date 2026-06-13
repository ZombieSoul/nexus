# Nexus API Specification v1.0

## The Foundation for Cross-Server Zone Travel

**Status:** Design phase — lock this before building.
**Codename:** `nexus` (neutral development name, will be renamed for lore)

---

## 1. Design Principles

1. **Stable Lua API, swappable transport.** Game code calls `nexus.travel()`. Whether the underlying mechanism is HTTP-to-proxy today or native `transfer_player` tomorrow, game code doesn't change.

2. **The proxy is the authority.** Player state lives in the proxy plugin during transfers. Not in a sidecar, not in a separate database — in the broker that controls hops.

3. **One process, one binary.** The Go plugin runs inside the proxy. No external sidecar processes to manage, crash, or drift out of sync.

4. **Every failure has a path.** No undefined states. Every error either rolls back or degrades gracefully.

5. **Extensible state.** Third-party mods register their own state handlers. The core carries inventory + player meta; everything else is opt-in.

---

## 2. System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    PROXY PROCESS (one binary)                   │
│                                                                │
│  ┌──────────────────┐    ┌──────────────────────────────────┐│
│  │  Proxy Core       │    │       nexus_plugin (Go)          ││
│  │  (mt-multiserver) │    │                                  ││
│  │                   │    │  • HTTP API  (:8080)             ││
│  │  • Auth           │◄──►│  • State store (in-mem + SQLite) ││
│  │  • Packet routing │    │  • Transfer state machine        ││
│  │  • cc.Hop()       │    │  • Galaxy registry               ││
│  │  • Mod channels   │    │  • Config loader                 ││
│  └──────────────────┘    └──────────────────────────────────┘│
│                                                                │
└──────────────────────────────┬─────────────────────────────────┘
                               │ HTTP (localhost)
                               │
              ┌────────────────┴────────────────┐
              │                                  │
              ▼                                  ▼
  ┌──────────────────┐               ┌──────────────────┐
  │  GALAXY ALPHA     │               │   GALAXY BETA     │
  │  (Luanti server)  │               │  (Luanti server)  │
  │                   │               │                   │
  │  ┌──────────────┐│               │┌──────────────┐  │
  │  │ nexus (Lua)  ││               ││ nexus (Lua)  │  │
  │  │              ││               ││              │  │
  │  │ • travel()   ││               ││ • on_arrive()│  │
  │  │ • state cap. ││               ││ • state rest.│  │
  │  └──────────────┘│               │└──────────────┘  │
  │                   │               │                   │
  │  Game mods        │               │  Game mods        │
  │  (gate blocks,    │               │  (gate blocks,    │
  │   energy, etc.)   │               │   energy, etc.)   │
  └──────────────────┘               └──────────────────┘
```

### Why HTTP, not mod channels, for state transfer

Mod channels have a **65535-character hard limit** per message. A player's inventory with tool wear, item metadata, and large stacks can exceed this. HTTP has no such limit, is trivially debuggable (`curl`), and provides clean request-response semantics.

The HTTP server runs **inside the proxy plugin** — it's not a separate process. It binds to localhost (or a configurable address) and serves the Nexus API to backend Luanti servers.

Mod channels remain available as an **optional enhancement** (see §10) for real-time push notifications, but are not required for the core transfer loop.

### Luanti HTTP API requirements

Each server's `minetest.conf` needs:
```ini
secure.http_mods = nexus
# The mod can now make HTTP requests to the proxy's API
```

The Lua mod uses `core.request_http_api()` to obtain an HTTP client, then calls the proxy's endpoints.

---

## 3. Nexus Lua API

This is the **stable contract** all game code depends on. Everything below this is implementation.

### 3.1 Travel Functions

```lua
--- Initiate travel to another galaxy.
--- @param player ObjectRef|string  Player object or name
--- @param destination string       Galaxy name (e.g. "beta")
--- @param opts? table              Optional: { spawn = vector, reason = string }
--- @return boolean success
--- @return string? error           Error message if failed
nexus.travel(player, destination, opts)
```

```lua
--- Check if travel is possible (galaxy exists, player is valid, not already traveling).
--- @param player ObjectRef|string
--- @param destination string
--- @return boolean can_travel
--- @return string? reason          Why not, if false
nexus.can_travel(player, destination)
```

### 3.2 State Management

```lua
--- Register a custom state handler. Called on depart (capture) and arrive (restore).
--- Multiple handlers can be registered. Core handlers (inventory, player_meta) are built-in.
--- @param name string              Unique handler name (e.g. "progress", "reputation")
--- @param handler table            { capture = fn(player)->table, restore = fn(player, data) }
nexus.state.register_handler(name, handler)
```

```lua
--- Manually capture all registered state for a player (rarely needed directly).
--- @param player ObjectRef|string
--- @return table state             The full state table
nexus.state.capture(player)
```

```lua
--- Manually restore state for a player (called automatically on arrival).
--- @param player ObjectRef|string
--- @param state table              State table from capture()
nexus.state.restore(player, state)
```

### 3.3 Callbacks

```lua
--- Called before a player departs this galaxy. 
--- Return false to cancel the travel (with reason).
--- @param handler fn(player, destination) -> boolean?, string?
nexus.on_depart(handler)
```

```lua
--- Called after a player arrives on this galaxy and state is restored.
--- @param handler fn(player, origin, state)
nexus.on_arrive(handler)
```

```lua
--- Called when a travel fails (destination unreachable, restore error, timeout).
--- @param handler fn(player, reason, stage)  
---   stage: "depart" | "hop" | "arrive" | "restore"
nexus.on_travel_failed(handler)
```

### 3.4 Galaxy Registration & Queries

```lua
--- Register this server as a galaxy. Called at mod load time.
--- @param definition table   { name = "alpha", label = "Alpha Sector", tier = 1 }
nexus.register_galaxy(definition)
```

```lua
--- Get all known galaxies (queried from the proxy).
--- This is cached and refreshed on travel events.
--- @return table[]  { {name=, label=, tier=, available=}, ... }
nexus.get_galaxies()
```

```lua
--- Get the name of this server's galaxy (from minetest.conf: nexus.galaxy_name).
--- @return string
nexus.get_current_galaxy()
```

### 3.5 Configuration

```lua
--- Set Nexus configuration. Call at mod load time, before any travel.
--- @param config table   {
---   proxy_url = "http://127.0.0.1:8080",  -- proxy API endpoint
---   timeout = 10,                          -- HTTP timeout in seconds
---   auto_sync_inventory = true,            -- carry inventory by default
---   auto_sync_hp = true,                   -- carry HP
---   spawn_fallback = vector,               -- default spawn on arrival
--- }
nexus.configure(config)
```

### 3.6 Usage Example (Game Code)

```lua
-- At mod load time:
nexus.configure({
    proxy_url = "http://127.0.0.1:8080",
})

nexus.register_galaxy({
    name = "alpha",
    label = "Alpha Sector",
    tier = 1,
})

-- Register custom game state to carry across galaxies:
nexus.state.register_handler("progress", {
    capture = function(player)
        local meta = player:get_meta()
        return {
            level = meta:get_int("progress_level"),
            known_gates = core.deserialize(meta:get_string("known_gates")) or {},
        }
    end,
    restore = function(player, data)
        local meta = player:get_meta()
        meta:set_int("progress_level", data.level)
        core:set_string("known_gates", core.serialize(data.known_gates))
    end,
})

-- A gate block that initiates travel:
core.register_node("gate_travel:anchor", {
    on_rightclick = function(pos, node, clicker)
        local pname = clicker:get_player_name()
        local galaxies = nexus.get_galaxies()
        -- Build formspec showing available destinations...
        local form = "size[8,6]"
            .. "label[1,0.5;Select destination:]"
        for i, g in ipairs(galaxies) do
            if g.name ~= nexus.get_current_galaxy() and g.available then
                form = form .. string.format(
                    "button[1,%f;6,1;goto_%s;%s (Tier %d)]",
                    1.0 + i * 0.8, g.name, g.label, g.tier
                )
            end
        end
        core.show_formspec(pname, "gate_travel:choose", form)
    end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "gate_travel:choose" then return end
    for key, _ in pairs(fields) do
        if key:match("^goto_(.+)$") then
            local dest = key:match("^goto_(.+)$")
            local ok, err = nexus.travel(player, dest)
            if not ok then
                core.chat_send_player(player:get_player_name(), "Travel failed: " .. err)
            end
            return
        end
    end
end)

-- Custom arrival handler (welcome message, spawn at gate, etc.)
nexus.on_arrive(function(player, origin)
    local pname = player:get_player_name()
    core.chat_send_player(pname, "Welcome. You arrived from " .. origin .. ".")
end)
```

**Note:** Game code never touches HTTP, JSON serialization, mod channels, or proxy internals. It calls `nexus.travel()` and registers handlers. That's it.

---

## 4. State Format

The state table is what travels with the player. It's versioned and extensible.

### 4.1 Structure

```json
{
  "version": 1,
  "format": "nexus-state",
  "player": "alice",
  "origin": "alpha",
  "destination": "beta",
  "timestamp": 1718200000,
  "request_id": "a1b2c3d4",
  "core": {
    "hp": 18,
    "breath": 10,
    "physics_override": {
      "speed": 1.0,
      "jump": 1.0,
      "gravity": 1.0
    }
  },
  "inventory": {
    "main": {
      "size": 32,
      "slots": {
        "1": { "name": "default:stone", "count": 64, "wear": 0 },
        "5": { "name": "default:pick_diamond", "count": 1, "wear": 12345,
               "meta": { "description": "My Pick" } }
      }
    },
    "craft": { "size": 9, "slots": {} }
  },
  "player_meta": {
    "progress_level": 3,
    "known_gates": "{\"alpha\": [0,0,0]}"
  },
  "extensions": {
    "progress": {
      "level": 3,
      "known_gates": {}
    }
  }
}
```

### 4.2 Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | State format version. Current: `1`. Bumped on breaking changes. |
| `format` | string | Always `"nexus-state"`. For validation. |
| `player` | string | Player name. |
| `origin` | string | Galaxy name the player is leaving. |
| `destination` | string | Galaxy name the player is going to. |
| `timestamp` | int | Unix timestamp of departure. For debugging and TTL. |
| `request_id` | string | UUID for correlating with the state machine. |
| `core` | object | HP, breath, physics override. Built-in handler. |
| `inventory` | object | Full inventory snapshot. Built-in handler. |
| `player_meta` | object | Player metadata key-value pairs. Built-in handler. |
| `extensions` | object | Custom state from registered handlers, keyed by handler name. |

### 4.3 Inventory Serialization Detail

```lua
-- How inventory is captured (built-in handler)
local function capture_inventory(player)
    local inv = player:get_inventory()
    local data = {}
    for listname, _ in pairs(inv:get_lists()) do
        local size = inv:get_size(listname)
        local slots = {}
        for i = 1, size do
            local stack = inv:get_stack(listname, i)
            if not stack:is_empty() then
                local entry = {
                    name = stack:get_name(),
                    count = stack:get_count(),
                    wear = stack:get_wear(),
                }
                -- Capture item metadata if present
                local meta = stack:get_meta():to_table()
                if next(meta.fields) then
                    entry.meta = meta.fields
                end
                slots[tostring(i)] = entry
            end
        end
        data[listname] = { size = size, slots = slots }
    end
    return data
end

-- How inventory is restored (built-in handler)
local function restore_inventory(player, inv_data)
    local inv = player:get_inventory()
    -- Clear existing inventory lists
    for listname, _ in pairs(inv:get_lists()) do
        inv:set_list(listname, {})
    end
    -- Restore each list
    for listname, list_data in pairs(inv_data) do
        -- Ensure the list exists with correct size
        local current_size = inv:get_size(listname)
        if current_size == 0 then
            -- List doesn't exist on this server (mod mismatch)
            -- Skip it — don't create lists that this server doesn't define
            core.log("warning", "[nexus] inventory list '" .. listname ..
                "' not found on this galaxy, skipping")
        else
            -- Resize if origin had a larger list
            if list_data.size > current_size then
                inv:set_size(listname, list_data.size)
            end
            for slot_str, item_data in pairs(list_data.slots) do
                local slot = tonumber(slot_str)
                local stack = ItemStack(item_data)
                if item_data.meta then
                    for key, value in pairs(item_data.meta) do
                        stack:get_meta():set_string(key, value)
                    end
                end
                inv:set_stack(listname, slot, stack)
            end
        end
    end
end
```

**List mismatch handling:** If the destination server doesn't have a list that the origin had (e.g., "armor" list but no armor mod), the list is skipped with a warning. Items in that list are lost. This is documented behavior — both servers must run compatible mods for full state preservation.

---

## 5. HTTP API (Proxy Plugin)

The Go plugin exposes a small REST API. All endpoints accept/return JSON.

### Base URL
`http://<proxy_host>:8080/nexus`

### 5.1 Endpoints

#### `POST /nexus/depart`
Called by the origin server's Lua mod when a player wants to travel.

**Request:**
```json
{
  "player": "alice",
  "destination": "beta",
  "request_id": "a1b2c3d4",
  "state": { /* full state table from §4 */ }
}
```

**Response (200):**
```json
{
  "ok": true,
  "request_id": "a1b2c3d4",
  "message": "Departure initiated"
}
```

**Plugin behavior:**
1. Validate destination exists and is reachable
2. Store state (keyed by player name)
3. Set player's transfer state to `IN_TRANSIT`
4. Call `cc.Hop(destination)` asynchronously
5. Return success

**Error responses:**
| Code | Condition |
|------|-----------|
| 400 | Malformed request, missing fields |
| 404 | Destination galaxy not found |
| 409 | Player already in transit |
| 503 | Destination server unreachable |

#### `GET /nexus/state/:player`
Called by the destination server's Lua mod on player arrival.

**Response (200):**
```json
{
  "ok": true,
  "state": { /* full state table from §4 */ }
}
```

**Response (404):**
```json
{
  "ok": false,
  "error": "NO_STATE",
  "message": "No pending state for player 'alice'"
}
```

**Plugin behavior:**
1. Look up stored state by player name
2. Return state (does NOT delete yet — DELETE is explicit)

#### `DELETE /nexus/state/:player`
Called by the destination server after successful state restoration.

**Response (200):**
```json
{
  "ok": true,
  "message": "State cleared"
}
```

**Plugin behavior:**
1. Delete stored state
2. Set player's transfer state to `IDLE`

#### `GET /nexus/galaxies`
Returns all known galaxies and their availability.

**Response (200):**
```json
{
  "galaxies": [
    { "name": "alpha", "label": "Alpha Sector", "tier": 1, "available": true },
    { "name": "beta", "label": "Beta Sector", "tier": 2, "available": true }
  ],
  "current": "alpha"
}
```

#### `POST /nexus/register`
Called by each galaxy server at startup to register its metadata.

**Request:**
```json
{
  "galaxy": { "name": "alpha", "label": "Alpha Sector", "tier": 1 }
}
```

#### `GET /nexus/health`
Liveness check.

**Response (200):**
```json
{
  "ok": true,
  "version": "1.0",
  "uptime": 3600,
  "players_in_transit": 0
}
```

---

## 6. Transfer State Machine

Each player has a state tracked in the plugin. This ensures correctness and prevents race conditions.

### 6.1 States

```
                    ┌──────┐
                    │ IDLE │ ◄────────────────────────────┐
                    └──┬───┘                               │
                       │ depart request                     │
                       ▼                                    │
                 ┌───────────┐                               │
                 │ DEPARTING │                               │
                 └─────┬─────┘                               │
                       │ Hop() succeeds                      │
                       ▼                                      │
                ┌─────────────┐                               │
          ┌────►│ IN_TRANSIT  │                               │
          │     └──────┬──────┘                               │
          │            │ arrive detected                      │
          │            ▼                                      │
          │     ┌───────────┐                                 │
          │     │ ARRIVING  │                                 │
          │     └─────┬─────┘                                 │
          │           │ restore confirmed                     │
          │           ▼                                        │
          │      ┌──────┐                                      │
          │      │ IDLE │─────────────────────────────────────┘
          │      └──────┘
          │
          │ Any failure:
          │   • Hop() fails
          │   • Timeout (player never arrives)
          │   • Restore fails
          ▼
    ┌──────────┐
    │  FAILED  │ ──► cleanup ──► IDLE
    └──────────┘
```

### 6.2 Transition Table

| From | Event | To | Action |
|------|-------|-----|--------|
| IDLE | `POST /depart` | DEPARTING | Store state, begin hop |
| DEPARTING | `Hop()` succeeds | IN_TRANSIT | Start arrival timeout (30s) |
| DEPARTING | `Hop()` fails | FAILED | Return error, player stays |
| IN_TRANSIT | `GET /state/:player` | ARRIVING | Return stored state |
| IN_TRANSIT | Timeout (30s) | FAILED | Log warning, clean up state |
| ARRIVING | `DELETE /state/:player` | IDLE | Clear state, clear timeout |
| ARRIVING | Timeout (60s) | FAILED | Log warning, keep state for retry |
| FAILED | Cleanup complete | IDLE | Remove from tracking |

### 6.3 Concurrency Model

```go
// Per-player mutex prevents concurrent transfers
type PlayerTransfer struct {
    mu        sync.Mutex
    state     TransferState
    stateData *PlayerState
    timer     *time.Timer
}

// Global registry
var transfers sync.Map // map[string]*PlayerTransfer (keyed by player name)
```

Only one transfer per player at a time. If a second `POST /depart` arrives while a transfer is in progress, it returns `409 Conflict`.

---

## 7. Failure Modes & Recovery

### 7.1 Failure Scenarios

| Scenario | What Happens | Recovery |
|----------|-------------|----------|
| **Destination unreachable** | `Hop()` returns error | Player stays on origin. Lua mod gets error. State never stored. |
| **Player disconnects mid-transfer** | `IN_TRANSIT` times out after 30s | State auto-cleaned. No dupe. |
| **Restore fails on destination** | Lua mod logs error, returns failure | Plugin keeps state for 60s (retry window). Player gets default inventory as fallback. |
| **Proxy restarts** | In-memory state lost | SQLite-backed state survives. On restart, orphaned states are expired by timestamp TTL. |
| **Duplicate depart request** | Second request gets `409` | First transfer proceeds normally. |
| **Player reconnects to origin** | State is still stored but `IN_TRANSIT` | Timeout fires, state cleaned. Player is fresh on origin. |
| **Network partition (server ↔ proxy)** | HTTP request times out | Lua mod retries with backoff. Transfer not initiated. |
| **Item list mismatch** | List doesn't exist on destination | Items in that list are dropped (logged). Other state preserved. |

### 7.2 Timeout Configuration

```go
const (
    ArrivalTimeout   = 30 * time.Second  // Player must arrive on dest within this
    RestoreTimeout   = 60 * time.Second  // Dest must confirm restore within this
    StateTTL         = 5 * time.Minute   // Orphaned state auto-expires
    CleanupInterval  = 60 * time.Second  // Background cleanup sweep
)
```

### 7.3 Player Disconnect During Transfer

The plugin registers `RegisterOnLeave` to detect disconnects:
```go
proxy.RegisterOnLeave(func(cc *proxy.ClientConn) {
    name := cc.Name()
    if pt, ok := transfers.Load(name); ok {
        pt.(*PlayerTransfer).mu.Lock()
        if pt.state == IN_TRANSIT {
            // Player disconnected during transfer — clean up
            pt.state = FAILED
            // Start shorter cleanup timeout
        }
        pt.mu.Unlock()
    }
})
```

---

## 8. Go Plugin Structure

```
nexus_plugin/
├── main.go          ← Plugin entry point: registers hooks, starts HTTP server
├── api.go           ← HTTP handler functions (depart, state, galaxies, etc.)
├── state.go         ← State store: in-memory map + SQLite persistence
├── transfer.go      ← Transfer state machine, per-player mutex, timeouts
├── galaxy.go        ← Galaxy registry, cross-references proxy server config
├── config.go        ← Config parsing (env vars + nexus.conf)
├── serialize.go     ← JSON structs for state format, request/response types
└── go.mod           ← Module definition, imports proxy package
```

### 8.1 Plugin Entry Point (pseudocode)

```go
package main

import (
    "net/http"
    "proxy"
)

func init() {
    proxy.RegisterOnLoad(func() {
        cfg := loadConfig()
        
        // Initialize subsystems
        stateStore = NewStateStore(cfg.Database)
        transferMgr = NewTransferManager(stateStore)
        galaxyReg = NewGalaxyRegistry()
        
        // Register proxy hooks
        proxy.RegisterOnJoin(onClientJoin)
        proxy.RegisterOnLeave(onClientLeave)
        
        // Start HTTP API
        go startHTTPServer(cfg.APIPort)
        
        log.Println("[nexus] plugin loaded, API on :" + cfg.APIPort)
    })
}

func startHTTPServer(port string) {
    mux := http.NewServeMux()
    mux.HandleFunc("/nexus/depart", handleDepart)
    mux.HandleFunc("/nexus/state/", handleState)  // GET and DELETE
    mux.HandleFunc("/nexus/galaxies", handleGalaxies)
    mux.HandleFunc("/nexus/register", handleRegister)
    mux.HandleFunc("/nexus/health", handleHealth)
    
    http.ListenAndServe(":"+port, mux)
}
```

### 8.2 State Store Interface

```go
type StateStore interface {
    // Store player state with a TTL
    Store(player string, state *PlayerState) error
    
    // Retrieve player state (does not delete)
    Retrieve(player string) (*PlayerState, bool)
    
    // Delete player state (after successful restore)
    Delete(player string) error
    
    // Clean up expired states (called periodically)
    CleanupExpired() int
}

// In-memory implementation (prototype)
type MemoryStateStore struct {
    mu    sync.RWMutex
    data  map[string]*storedState
}

// SQLite implementation (production)
type SQLiteStateStore struct {
    db *sql.DB
}
```

### 8.3 The Hop Integration

```go
func handleDepart(w http.ResponseWriter, r *http.Request) {
    var req DepartRequest
    json.NewDecoder(r.Body).Decode(&req)
    
    // 1. Validate
    if !galaxyReg.Exists(req.Destination) {
        writeError(w, 404, "UNKNOWN_GALAXY", "No galaxy named "+req.Destination)
        return
    }
    
    // 2. Get or create player transfer state
    pt := transferMgr.GetOrCreate(req.Player)
    pt.mu.Lock()
    defer pt.mu.Unlock()
    
    if pt.state != IDLE {
        writeError(w, 409, "IN_TRANSIT", "Player already traveling")
        return
    }
    
    // 3. Store state
    stateStore.Store(req.Player, req.State)
    pt.state = DEPARTING
    
    // 4. Get the ClientConn from the proxy
    cc := proxy.GetClientConn(req.Player)
    if cc == nil {
        pt.state = FAILED
        writeError(w, 503, "NOT_CONNECTED", "Player not connected to proxy")
        return
    }
    
    // 5. Hop asynchronously (don't block the HTTP response)
    go func() {
        err := cc.Hop(req.Destination)
        pt.mu.Lock()
        if err != nil {
            pt.state = FAILED
            stateStore.Delete(req.Player)
            log.Printf("[nexus] hop failed for %s: %v", req.Player, err)
        } else {
            pt.state = IN_TRANSIT
            pt.StartArrivalTimeout()
        }
        pt.mu.Unlock()
    }()
    
    // 6. Return success — Lua mod knows departure is initiated
    writeJSON(w, 200, DepartResponse{
        OK: true, RequestID: req.RequestID,
    })
}
```

---

## 9. Configuration

### 9.1 Proxy Plugin Config (`nexus.conf`)

```ini
[nexus]
# HTTP API port (serves backend Luanti servers)
api_port = 8080
api_bind = 127.0.0.1

# State storage backend: "memory" (prototype) or "sqlite" (production)
storage_backend = memory
sqlite_path = ./nexus_state.db

# Timeouts (seconds)
arrival_timeout = 30
restore_timeout = 60
state_ttl = 300
```

### 9.2 Luanti Server Config (`minetest.conf` per galaxy)

```ini
# Allow the nexus mod to make HTTP requests
secure.http_mods = nexus

# This server's galaxy identity
nexus.galaxy_name = alpha
nexus.proxy_url = http://127.0.0.1:8080

# Backend servers allow empty passwords (proxy handles auth)
empty_password = true
disallow_empty_password = false
```

### 9.3 Proxy Server Config (`config.json`)

```json
{
  "Servers": {
    "alpha": { "Addr": "127.0.0.1:30000" },
    "beta":  { "Addr": "127.0.0.1:30001" }
  },
  "Proxy": {
    "Addr": ":40000"
  }
}
```

---

## 10. Optional: Mod Channel Enhancement

Mod channels are NOT required for the core transfer loop. They're available for **real-time cross-server events** that HTTP can't do well (push notifications, galaxy status broadcasts).

### Potential Future Uses

| Use Case | Channel | Direction |
|----------|---------|-----------|
| "Player arriving at your gate" | `nexus:alpha` | Plugin → Alpha Lua |
| Galaxy status broadcast | `nexus:broadcast` | Plugin → All Lua |
| Chat relay across galaxies | `nexus:chat` | Lua ↔ Lua (via plugin) |

These are **out of scope for v1**. The HTTP API is sufficient. Mod channels can be layered on later without changing the Nexus Lua API.

---

## 11. Testing Strategy

### 11.1 Unit Tests (Lua)

```lua
-- Test inventory serialization round-trip
function test_inventory_roundtrip()
    local player = mock_player({main = {"default:stone 99", "default:dirt 64"}})
    local data = nexus.internal.capture_inventory(player)
    local player2 = mock_player({main = {}})
    nexus.internal.restore_inventory(player2, data)
    assert(player2.inv.main[1]:get_name() == "default:stone")
    assert(player2.inv.main[1]:get_count() == 99)
end

-- Test state handler registration and capture order
function test_state_handlers()
    nexus.state.register_handler("a", {capture = fn_a, restore = fn_a_r})
    nexus.state.register_handler("b", {capture = fn_b, restore = fn_b_r})
    local state = nexus.state.capture(mock_player())
    assert(state.extensions.a ~= nil)
    assert(state.extensions.b ~= nil)
end
```

### 11.2 Integration Tests (Go)

```go
func TestFullTransferCycle(t *testing.T) {
    // 1. Start proxy + 2 mock Luanti servers
    // 2. Connect a mock client
    // 3. POST /depart with test state
    // 4. Verify player hopped to server B
    // 5. GET /state/alice — verify state returned
    // 6. DELETE /state/alice — verify cleaned up
    // 7. Verify state machine returned to IDLE
}
```

### 11.3 Chaos Tests

| Test | What It Validates |
|------|-------------------|
| Disconnect during IN_TRANSIT | State cleaned up, no orphan |
| POST depart twice rapidly | Second gets 409 |
| Restart proxy mid-transfer | SQLite state survives, expires by TTL |
| Destination server down | Hop fails, player stays on origin |
| Large inventory (1000 items) | No truncation, no 64KB limit |

---

## 12. Migration Path (When Native transfer_player Lands)

PR #14129 adds `transfer_player()` to Luanti core. When it merges:

**What changes:**
- The Go plugin's `cc.Hop()` call → becomes `server:transfer_player(player, dest_server)`
- State transfer mechanism may change (core might provide native state sync)

**What DOESN'T change:**
- `nexus.travel()` — game code is untouched
- State format (§4) — same structure
- State handlers (§3.2) — same registration API
- Callbacks (§3.3) — same interface

The Nexus Lua API is the abstraction layer. We swap the transport underneath. **This is why the API design matters more than the implementation.**

---

## 13. Development Names Reference

All names are temporary placeholders for development.

| Concept | Dev Name | Will Be Renamed To |
|---------|----------|--------------------|
| Project | `ringworld` | TBD (lore-based) |
| Transfer system | `nexus` | TBD (lore-based) |
| Galaxy Alpha | `alpha` | TBD |
| Galaxy Beta | `beta` | TBD |
| Lua mod | `nexus` | TBD |
| Go plugin | `nexus_plugin` | TBD |
| Gate block | `gate_travel:anchor` | TBD |
| State format | `nexus-state` | TBD |

---

## 14. Build Order (What To Implement First)

| Step | Component | Validates | Est. Effort |
|------|-----------|-----------|-------------|
| **1** | Go plugin: HTTP skeleton + health endpoint | Plugin loads, proxy works | 1 hr |
| **2** | Go plugin: state store (memory) + `/depart` + `/state` | Can store/retrieve JSON | 2 hrs |
| **3** | Go plugin: Hop integration + state machine | Transfer actually happens | 2 hrs |
| **4** | Lua mod: inventory serializer/deserializer | State captures correctly | 2 hrs |
| **5** | Lua mod: `travel()` + `on_arrive()` + HTTP calls | End-to-end transfer works | 2 hrs |
| **6** | Lua mod: state handlers, callbacks, galaxy registration | Full API usable | 2 hrs |
| **7** | Integration: two servers + proxy + test transfer | The proof of concept | 1 hr |
| **8** | Hardening: timeouts, failure paths, edge cases | Robustness | 3 hrs |

**Total: ~15 hours** of focused implementation. Each step is independently testable.

---

## 15. Open Questions (To Resolve Before Building)

1. **Does the proxy expose `GetClientConn(player_name)`?** Need to verify we can look up a player's ClientConn by name from the plugin. If not, we capture it in `RegisterOnJoin` and maintain our own map.

2. **What happens to detached inventories?** The proxy's hop code removes detached inventories on hop. If a player has items in a detached inventory (e.g., creative search, bags), those need separate handling. For v1, document as a known limitation.

3. **Player attributes vs. player meta?** Luanti has both. We serialize `player:get_meta()`. If game code uses `player:set_attribute()` (deprecated in newer versions), that needs a handler too.

4. **Spawn position on arrival?** Where does the player appear on the new galaxy? Options: world spawn, a designated gate position, or a position specified in the travel request. v1: world spawn. v2: gate-to-gate positioning.

5. **Hot-reload of galaxy config?** Can a server admin add a galaxy without restarting the proxy? The proxy supports dynamic servers (`AddServer`). The plugin should expose this, but it's v2.
