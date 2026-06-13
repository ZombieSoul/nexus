#!/bin/bash
cd "$(dirname "$0")/.."
echo "[start_alpha] Launching Alpha galaxy server on :30000"
exec engine/bin/luantiserver \
    --config config/alpha.conf \
    --world worlds/alpha \
    --gameid devtest
