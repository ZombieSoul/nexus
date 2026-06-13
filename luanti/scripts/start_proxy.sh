#!/bin/bash
cd "$(dirname "$0")/.."
echo "[start_proxy] Launching mt-multiserver-proxy on :40000"
cd proxy
exec ./mt-multiserver-proxy
