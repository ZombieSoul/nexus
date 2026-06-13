#!/bin/bash
cd "$(dirname "$0")/.."
DIR="$(pwd)"

echo "=== Starting Nexus test environment ==="

# Start proxy FIRST (it's the broker — servers register with it)
echo "[1/3] Starting Proxy (:40000)..."
"$DIR/scripts/start_proxy.sh" > /tmp/nexus-proxy.log 2>&1 &
PROXY_PID=$!
echo "  PID: $PROXY_PID"

# Wait for proxy to be ready
echo "  Waiting for proxy to initialize..."
sleep 3

# Start alpha server
echo "[2/3] Starting Alpha galaxy (:30000)..."
"$DIR/scripts/start_alpha.sh" > /tmp/nexus-alpha.log 2>&1 &
ALPHA_PID=$!
echo "  PID: $ALPHA_PID"

# Start beta server
echo "[3/3] Starting Beta galaxy (:30001)..."
"$DIR/scripts/start_beta.sh" > /tmp/nexus-beta.log 2>&1 &
BETA_PID=$!
echo "  PID: $BETA_PID"

# Wait for servers to initialize
echo "  Waiting for servers to initialize..."
sleep 4

echo ""
echo "=== All services running ==="
echo "Alpha server:  PID $ALPHA_PID (log: /tmp/nexus-alpha.log)"
echo "Beta server:   PID $BETA_PID (log: /tmp/nexus-beta.log)"
echo "Proxy:         PID $PROXY_PID (log: /tmp/nexus-proxy.log)"
echo ""
echo "Connect to: 127.0.0.1:40000"
echo "Proxy HTTP API: http://127.0.0.1:8080/nexus/health"
echo ""
echo "Stop all: kill $PROXY_PID $ALPHA_PID $BETA_PID"
echo ""

# Save PIDs for stop script
echo "$PROXY_PID $ALPHA_PID $BETA_PID" > /tmp/nexus-pids.txt
