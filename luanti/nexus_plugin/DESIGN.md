# Server Lifecycle Manager — Design Document

## Overview

The proxy plugin manages world server lifecycles: spawning, monitoring,
and shutting down Luanti server processes on demand. This enables
dialing gates on offline worlds — the proxy boots the destination
world's server, waits for it to come online, then completes the transfer.

## Architecture

```
PROXY (always running)
  │
  ├── SQLite: world_registry.db
  │   ├── worlds table — all known worlds, their state, params
  │   └── gates table — all registered gates (persists across restarts)
  │
  ├── ServerManager (Go)
  │   ├── Process pool — spawn/monitor/kill Luanti processes
  │   ├── Port pool — assign/reclaim ports (30010-30050 for dynamic)
  │   ├── Idle detector — shut down servers with 0 players after timeout
  │   ├── Eviction — when at capacity, shut down oldest idle dynamic world
  │   └── Boot timeout — kill servers that don't register within 30s
  │
  ├── HTTP API
  │   ├── POST /nexus/link         — existing, now handles offline worlds
  │   ├── GET  /nexus/link/status  — poll for link/dial completion
  │   ├── GET  /nexus/world/:name  — world info + state
  │   ├── POST /nexus/world/start  — admin: start a world manually
  │   ├── POST /nexus/world/stop   — admin: stop a world manually
  │   └── GET  /nexus/worlds       — list all worlds with states
  │
  └── Universe Config (worlds.json)
      ├── Galaxy definitions (tier, max random worlds, params)
      ├── Static worlds (always known, priority for resources)
      └── Random world templates (ores, hazards, ruin density per tier)

## State Machine

```
                    ┌─────────┐
          ┌────────►│ OFFLINE │◄────────┐
          │         └────┬────┘         │
          │              │ start()      │ shutdown complete
          │              ▼              │
          │         ┌─────────┐         │
          │         │STARTING │         │
          │         └────┬────┘         │
          │              │ registered   │
          │              ▼              │
   timeout│         ┌─────────┐         │
   or     │         │ ONLINE  │─────────┘
   error  │         └────┬────┘ stop()
          │              │
          │              ▼
          │         ┌─────────┐
          └─────────│ STOPPING│
                    └─────────┘
```

Valid transitions:
  OFFLINE → STARTING (start request)
  STARTING → ONLINE (server registered with proxy)
  STARTING → OFFLINE (boot timeout or process died)
  ONLINE → STOPPING (stop request or idle timeout)
  STOPPING → OFFLINE (process exited)

Invalid transitions are logged and rejected.

## Crash Recovery

On proxy restart:
  1. All worlds in SQLite have their state set to "offline"
     (processes died with the proxy)
  2. Gate registry is intact (SQLite persisted)
  3. Static worlds are started by the startup script
  4. Dynamic worlds start on-demand when dialed
  5. World data on disk is intact

## Concurrency Model

  - ServerManager uses a RWMutex for the process map
  - SQLite uses WAL mode for concurrent reads
  - Each managed server has its own context with cancel
  - Process monitoring runs in a per-server goroutine

## Robustness Principles

  1. SQLite is the source of truth, not memory
  2. All state transitions are logged
  3. Boot timeout kills zombie processes
  4. Graceful shutdown warns players 60s before
  5. Idempotent: starting an already-starting server is a no-op
  6. Gate data never deleted by proxy shutdown (persists in SQLite)
