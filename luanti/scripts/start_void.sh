#!/bin/bash
cd "$(dirname "$0")/.."
echo "[start_void] Launching Void lobby on :30010"
exec engine/bin/luantiserver \
    --config config/void.conf \
    --world worlds/void \
    --gameid nexus_lobby
