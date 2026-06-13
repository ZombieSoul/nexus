#!/bin/bash
if [ -f /tmp/nexus-pids.txt ]; then
    read -ra PIDS < /tmp/nexus-pids.txt
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping PID $pid..."
            kill "$pid"
        fi
    done
    rm /tmp/nexus-pids.txt
    echo "All services stopped."
else
    echo "No PID file found. Services may not be running."
fi
