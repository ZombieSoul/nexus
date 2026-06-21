#!/bin/bash
cd "$(dirname "$0")/.."
DIR="$(pwd)"
echo "[start_proxy] Launching mt-multiserver-proxy on :40000"

# Load the shared nexus API secret (trusted by all galaxy servers)
SECRET_FILE="$DIR/config/nexus_secret"
if [ ! -f "$SECRET_FILE" ]; then
    echo "[start_proxy] ERROR: $SECRET_FILE not found — refusing to start (auth disabled)"
    exit 1
fi
export NEXUS_API_SECRET="$(cat "$SECRET_FILE")"
export NEXUS_API_PORT=8090

# Use SQLite for state persistence (survives proxy restart)
export NEXUS_STORAGE_BACKEND=sqlite

cd proxy
exec ./mt-multiserver-proxy
