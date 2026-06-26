#!/bin/bash
cd "$(dirname "$0")/.."
DIR="$(pwd)"

echo "=== Starting Nexus World Network ==="

# Start proxy FIRST
echo "[1/5] Starting Proxy (:40000)..."
"$DIR/scripts/start_proxy.sh" > /tmp/nexus-proxy.log 2>&1 &
PROXY_PID=$!
echo "  PID: $PROXY_PID"
sleep 3

# Start void lobby SECOND (it's the default world — players land here)
echo "[2/5] Starting Void lobby (:30010)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/void.conf" --world "$DIR/worlds/void" --gameid nexus_lobby > /tmp/nexus-void.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "[3/5] Starting abydos (:30002)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/abydos.conf" --world "$DIR/worlds/abydos" --gameid mineclonia > /tmp/nexus-abydos.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "[4/5] Starting earth (:30000)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/earth.conf" --world "$DIR/worlds/earth" --gameid mineclonia > /tmp/nexus-earth.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "[5/5] Starting proxima (:30001)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/proxima.conf" --world "$DIR/worlds/proxima" --gameid mineclonia > /tmp/nexus-proxima.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "Waiting for servers..."
sleep 5

echo ""
echo "=== All services running ==="
echo "Void lobby:    (log: /tmp/nexus-void.log)"
echo "abydos server:  (log: /tmp/nexus-abydos.log)"
echo "earth server:   (log: /tmp/nexus-earth.log)"
echo "proxima server: (log: /tmp/nexus-proxima.log)"
echo "Proxy:         (log: /tmp/nexus-proxy.log)"
echo ""
echo "Connect to: 127.0.0.1:40000"
echo "Proxy HTTP API: http://127.0.0.1:8090/nexus/health"
echo ""
echo "Stop all: kill $PROXY_PID $(pgrep -f luantiserver | tr '\n' ' ')"
