#!/bin/bash
cd "$(dirname "$0")/.."
echo "[start_beta] Launching Proxima galaxy server on :30001"
exec engine/bin/luantiserver \
    --config config/beta.conf \
    --world worlds/proxima \
    --gameid mineclonia
