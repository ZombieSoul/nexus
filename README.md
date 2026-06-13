# Ringworld — Multi-Galaxy Progression Game

A Stargate-themed progression game built on Luanti (formerly Minetest) with
cross-server zone travel. Players discover, repair, and program gates to
explore tiered dimensions across multiple galaxies.

## Architecture

The game runs as multiple Luanti server processes behind mt-multiserver-proxy.
Each galaxy is a separate server. Travel between galaxies happens via:
- **Gate travel** — instant, gate-to-gate wormhole transfer
- **Space travel** — spacecraft through orbit and hyperspace zones

The `nexus` system handles player state synchronization across servers.

## Documentation

All design docs are in [`documentation/`](documentation/):
- [`nexus-api-spec.md`](documentation/nexus-api-spec.md) — Core transfer system API
- [`nexus-gate-protocol.md`](documentation/nexus-gate-protocol.md) — Gate-to-gate travel protocol
- [`nexus-space-protocol.md`](documentation/nexus-space-protocol.md) — Spacecraft and zone travel
- [`dimension-architecture-multiserver.md`](documentation/dimension-architecture-multiserver.md) — Architecture overview
- [`license-analysis.md`](documentation/license-analysis.md) — Component license analysis
- [`prototype-plan.md`](documentation/prototype-plan.md) — Original prototype plan

## Project Structure

```
luanti/
├── engine/           — Luanti 5.16.1 server (built from source)
├── proxy/            — mt-multiserver-proxy + nexus Go plugin
├── mods/
│   └── nexus/        — Cross-server travel mod (Lua)
├── nexus_plugin/     — Proxy plugin (Go): HTTP API + state sync
├── worlds/
│   ├── alpha/        — Test world: Alpha Sector
│   └── beta/         — Test world: Beta Sector
├── config/           — Server and proxy configs
└── scripts/          — Launch scripts
```

## Quick Start

```bash
# Build Luanti server (first time only)
cd luanti/engine && cmake . -DRUN_IN_PLACE=TRUE -DBUILD_SERVER=TRUE -DBUILD_CLIENT=FALSE && make -j$(nproc)

# Build proxy (first time only)
cd luanti/proxy && go build -o mt-multiserver-proxy ./cmd/mt-multiserver-proxy

# Build nexus plugin (after changes)
cd luanti/nexus_plugin && go build -buildmode=plugin -o nexus.so . && cp nexus.so ../proxy/plugins/

# Start everything
luanti/scripts/start_all.sh

# Connect a Luanti client to: 127.0.0.1:40000
```

## Status

Foundation built and boot-tested. The proxy loads the nexus plugin, both
galaxy servers register, and the HTTP API is live. End-to-end transfer
testing requires a connected Luanti client.
