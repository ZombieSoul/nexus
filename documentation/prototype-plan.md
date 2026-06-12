# Prototype Plan: Cross-Server Gate Transfer

## Goal

**Prove the riskiest piece first:** A player clicks a block on Server A, arrives on Server B with inventory intact. If this works, everything else is content.

---

## How The Transfer Actually Works (Verified)

The `mt-multiserver-proxy` sits between client and backend servers:

```
Luanti Client ──→ PROXY (:40000) ──→ GalaxyA server (:30000)
                                    ──→ GalaxyB server (:30001)
```

### The transfer mechanism
The proxy intercepts chat commands prefixed with `>` (configurable). The built-in `>server <name>` command calls `clt.Hop("ServerName")` internally, which transparently redirects the client to a different backend server. **The player doesn't reconnect — they just appear on the new server.**

Key detail from the proxy docs: **backend servers must allow empty passwords** (the proxy handles authentication centrally).

### The state-sync problem
The proxy transfers the *connection*, not the *character*. Each backend server has its own player database. So when you hop to GalaxyB, you arrive as a fresh player — your inventory doesn't come with you.

**Solution:** A sidecar HTTP service that stores player state during transfer.

---

## Architecture

```
Player right-clicks Gate Block (Lua mod, on GalaxyA)
    │
    ▼
1. Lua mod serializes player state (inventory, health, meta)
    │
    ▼
2. Lua mod POSTs state to Transfer API (HTTP)               ─┐
    │                                                        │
    ▼                                                        ▀
3. Transfer API stores state, calls proxy Hop("GalaxyB")    
    │                                                        ┌── Transfer API (Go)
    ▼                                                        │   - stores player state
4. Player arrives on GalaxyB (seamless, no reconnect)        │   - triggers clt.Hop()
    │                                                        │   - serves state on GET
    ▼                                                        ─┘
5. GalaxyB's Lua mod on_joinplayer → GET state from Transfer API
    │
    ▼
6. Restore inventory, health, meta → player is whole again
```

---

## Components To Build

### 1. Two Luanti Server Worlds
- `world_alpha/` — Galaxy Alpha (home), port 30000
- `world_beta/` — Galaxy Beta (destination), port 30001
- Both running VoxeLibre or minetest_game as base
- Both with `empty_password = true` and `disallow_empty_password = false`

### 2. Proxy (off-the-shelf)
- `mt-multiserver-proxy` binary, built from source (Go)
- Config `config.json` with two backend servers
- Port 40000 (client-facing)

### 3. Transfer API (tiny Go plugin OR standalone service)
**Decision needed:** Go plugin that runs inside the proxy process, or standalone HTTP sidecar?

| | Go Plugin (in proxy) | Standalone Sidecar (Python/Go) |
|---|---|---|
| Can call `clt.Hop()` directly | ✅ Yes | ❌ No (needs proxy API) |
| Can run HTTP server | ✅ (in goroutine) | ✅ Native |
| Simpler to build | ⚠️ Need Go + proxy API | ✅ Any language |
| State storage | In-memory or SQLite | SQLite/file |

**Recommendation:** Start with a **standalone sidecar** (simplest to build/debug), trigger transfers via chat command. Upgrade to Go plugin if the chat-command trigger is too clunky.

Sidecar responsibilities:
```
POST /transfer          → store {player, inventory, health, meta, destination}
GET  /state/<player>    → return stored state, then delete it
GET  /health            → liveness check
```

### 4. Gate Mod (Lua — our code)
This is the actual game mod. Files:

```
mods/gate_travel/
├── mod.conf
├── init.lua           ← block registration, click handler, state sync
├── serialize.lua      ← inventory/health serialization helpers
└── textures/
    └── gate_stone.png ← placeholder texture
```

**What init.lua does:**

```lua
-- Register the gate block
minetest.register_node("gate_travel:anchor", {
    description = "Travel Anchor",
    tiles = {"gate_stone.png"},
    groups = {cracky = 3},
    on_rightclick = function(pos, node, player, itemstack, pointed_thing)
        -- Show a formspec asking which galaxy to travel to
        local pname = player:get_player_name()
        local form = "size[6,3]" ..
            "label[1,0.5;Travel to which server?]" ..
            "button[1,1;4,1;beta;Galaxy Beta]" ..
            "button_exit[1,2;4,1;cancel;Cancel]"
        minetest.show_formspec(pname, "gate_travel:choose", form)
    end,
})

-- Handle formspec response
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "gate_travel:choose" then return end
    if fields.beta then
        gate_travel.transfer_player(player, "beta")
    end
end)

-- The transfer sequence
function gate_travel.transfer_player(player, destination)
    local pname = player:get_player_name()
    
    -- 1. Serialize state
    local state = gate_travel.serialize_player(player)
    
    -- 2. POST to sidecar (async HTTP)
    gate_travel.http.fetch({
        url = "http://127.0.0.1:8080/transfer",
        method = "POST",
        data = minetest.write_json({
            player = pname,
            destination = destination,
            state = state,
        }),
    }, function(result)
        -- 3. Tell player to send the proxy chat command
        -- (The actual hop is triggered by the chat command)
        minetest.chat_send_player(pname, "Initiating transfer to " .. destination .. "...")
        -- Server sends the chat command on behalf of player
        -- The proxy intercepts ">server beta" and hops
        -- (mechanism TBD — see "The Trigger Problem" below)
    end)
end

-- On arriving at a new server, restore state
minetest.register_on_joinplayer(function(player)
    local pname = player:get_player_name()
    gate_travel.http.fetch({
        url = "http://127.0.0.1:8080/state/" .. pname,
        method = "GET",
    }, function(result)
        if result.code == 200 then
            local data = minetest.parse_json(result.data)
            gate_travel.restore_player(player, data.state)
            minetest.chat_send_player(pname, "Welcome to this galaxy. Your items have been restored.")
        end
    end)
end)
```

---

## ⚠️ The Trigger Problem (Needs Solving)

The proxy only responds to chat commands **from the client** (prefixed with `>`). A server-side Lua mod cannot directly make a client send `>server beta`.

### Options (ranked by simplicity for prototype)

**Option A: Instruction prompt (simplest, MVP)**
The gate block shows: "Type `>server beta` to travel." The player types it. Works immediately, ugly UX, fine for proving the concept.

**Option B: Go plugin with HTTP trigger (cleanest)**
Write a proxy plugin that:
1. Runs an HTTP server in a goroutine
2. Exposes `POST /hop?player=X&server=Y` → calls `clt.Hop("Y")`
3. The Lua mod calls this endpoint after serializing state

This is the production solution. The Lua mod → HTTP → Go plugin → `clt.Hop()` chain.

**Option C: Client-side mod (CSM)**
A client mod that auto-sends the chat command when triggered. Adds client-side dependency. More complex.

**Recommendation:** Start with **Option A** (prove the concept in 1 hour), then move to **Option B** for the real implementation.

---

## Development Names (Safe Placeholders)

Using neutral names during development. Will rename when we have story/lore.

| Concept | Dev Name | Notes |
|---------|----------|-------|
| The mod | `gate_travel` | Descriptive, not thematic |
| The block | `gate_travel:anchor` | "Travel Anchor" — generic |
| Server A | `alpha` | First galaxy |
| Server B | `beta` | Second galaxy |
| The proxy | `broker` | Neutral networking term |
| State sidecar | `transfer_api` | Descriptive |
| Project codename | `ringworld` | Not Stargate-related, easy to grep for |

---

## Prototype Steps (In Order)

### Phase 1: Bare Transfer (no inventory) — 1-2 hours
**Goal:** Prove the proxy works and players can hop between servers.

1. Install Luanti (5.16)
2. Create two worlds (alpha, beta) with VoxeLibre or devtest
3. Install Go, build mt-multiserver-proxy
4. Configure proxy with two backends
5. Connect client to proxy (:40000)
6. Type `>server beta` → verify you hop to the other world
7. Type `>server alpha` → verify you hop back

**Success criteria:** Player can move between two servers via chat command. No disconnect.

### Phase 2: Gate Block + State Sync — 2-4 hours
**Goal:** Click a block, arrive on other server with your stuff.

1. Write the `gate_travel` Lua mod (block, formspec, serializer)
2. Write the transfer_api sidecar (Python Flask, ~50 lines)
3. Install mod on both servers
4. Configure `secure.http_mods = gate_travel` in both servers' minetest.conf
5. Pick up some items on alpha → click gate → arrive on beta → verify items restored

**Success criteria:** Inventory survives cross-server transfer via block click.

### Phase 3: Polish the Trigger — 1-2 hours
**Goal:** Seamless transfer without typing chat commands.

1. Write the Go proxy plugin (HTTP endpoint → `clt.Hop()`)
2. Update Lua mod to call the plugin endpoint instead of chat command prompt
3. End-to-end test: click block → instant transfer with inventory

**Success criteria:** One click, seamless transfer, inventory intact. The core loop works.

---

## What This Proves

If Phase 3 works, we've proven:
- ✅ Multi-server architecture is viable on Luanti TODAY
- ✅ Player state can sync across servers
- ✅ The gate block UX is clean
- ✅ The "loading screen = wormhole travel" concept works (hop latency)
- ✅ We can build the full game on this foundation

**What it doesn't prove yet:** Performance with many players, edge cases (combat logging, dupe glitches), lazy galaxy loading. Those come later.

---

## File Structure (What We'll Create)

```
ringworld/                          ← project root
├── documentation/                  ← existing docs
│   ├── dimension-architecture-multiserver.md
│   ├── license-analysis.md
│   └── prototype-plan.md           ← this file
├── mods/
│   └── gate_travel/                ← our Lua mod
│       ├── mod.conf
│       ├── init.lua
│       ├── serialize.lua
│       └── textures/
├── transfer_api/                   ← state sync sidecar
│   ├── server.py                   ← Flask app (~50 lines)
│   └── requirements.txt
├── proxy_plugin/                   ← Go plugin (Phase 3)
│   └── hop.go                      ← HTTP → clt.Hop()
├── worlds/
│   ├── alpha/                      ← Galaxy Alpha world
│   └── beta/                       ← Galaxy Beta world
├── config/
│   ├── proxy_config.json           ← proxy backend config
│   ├── alpha.conf                  ← Luanti config for alpha
│   └── beta.conf                   ← Luanti config for beta
└── scripts/
    ├── start_proxy.sh              ← launch proxy
    ├── start_alpha.sh              ← launch alpha server
    ├── start_beta.sh               ← launch beta server
    └── start_all.sh                ← launch everything for local testing
```
