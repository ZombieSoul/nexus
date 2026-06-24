#!/bin/bash
cd "$(dirname "$0")/.."
DIR="$(pwd)"

echo "=== Starting Nexus World Network ==="

# Start proxy FIRST
echo "[1/N] Starting Proxy (:40000)..."
"$DIR/scripts/start_proxy.sh" > /tmp/nexus-proxy.log 2>&1 &
PROXY_PID=$!
echo "  PID: $PROXY_PID"
sleep 3

echo "[2/4] Starting abydos (:30002)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/abydos.conf" --world "$DIR/worlds/abydos" --gameid mineclonia > /tmp/nexus-abydos.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "[3/4] Starting earth (:30000)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/earth.conf" --world "$DIR/worlds/earth" --gameid mineclonia > /tmp/nexus-earth.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "[4/4] Starting proxima (:30001)..."
cd "$DIR/engine"
nohup ./bin/luantiserver --config "$DIR/config/proxima.conf" --world "$DIR/worlds/proxima" --gameid mineclonia > /tmp/nexus-proxima.log 2>&1 &
echo "  PID: $!"
cd "$DIR"

echo "Waiting for servers..."
sleep 5

echo ""
echo "=== All services running ==="
echo "abydos server:  (log: /tmp/nexus-abydos.log)"
echo "earth server:  (log: /tmp/nexus-earth.log)"
echo "proxima server:  (log: /tmp/nexus-proxima.log)"
echo "Proxy:         (log: /tmp/nexus-proxy.log)"
echo ""
echo "Connect to: 127.0.0.1:40000"
echo "$PROXY_PID" > /tmp/nexus-pids.txt

