#!/bin/bash
# setup_worlds.sh — Generate world configs from worlds.json
#
# Reads worlds.json and creates:
#   - worlds/<name>/world.mt
#   - worlds/<name>/map_meta.txt
#   - config/<name>.conf (server config)
#   - worldmods symlinks
#   - proxy/config.json (server topology)
#
# Usage: ./scripts/setup_worlds.sh
# Or:    ./scripts/setup_worlds.sh <world_name>  (set up just one world)

set -e
cd "$(dirname "$0")/.."
DIR="$(pwd)"

# Check for jq (JSON parser)
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required. Install with: sudo apt install jq"
    exit 1
fi

WORLD_FILTER="${1:-}"  # optional: only set up one world

echo "=== Nexus World Setup ==="
echo "Reading worlds.json..."
echo

# Read the shared API secret
SECRET_FILE="$DIR/config/nexus_secret"
if [ ! -f "$SECRET_FILE" ]; then
    echo "Generating new API secret..."
    openssl rand -hex 32 > "$SECRET_FILE"
fi
SECRET=$(cat "$SECRET_FILE")

# Collect all worlds for proxy config
PROXY_SERVERS=""

# Process each world
for world_name in $(jq -r '.worlds | keys[]' worlds.json); do
    if [ -n "$WORLD_FILTER" ] && [ "$world_name" != "$WORLD_FILTER" ]; then
        continue
    fi

    echo "--- World: $world_name ---"

    galaxy=$(jq -r ".worlds.\"$world_name\".galaxy" worlds.json)
    galaxy_label=$(jq -r ".worlds.\"$world_name\".galaxy_label" worlds.json)
    tier=$(jq -r ".worlds.\"$world_name\".tier" worlds.json)
    description=$(jq -r ".worlds.\"$world_name\".description" worlds.json)
    port=$(jq -r ".worlds.\"$world_name\".port" worlds.json)
    terrain=$(jq -r ".worlds.\"$world_name\".mapgen.terrain" worlds.json)
    seed=$(jq -r ".worlds.\"$world_name\".mapgen.seed" worlds.json)
    water_level=$(jq -r ".worlds.\"$world_name\".mapgen.water_level" worlds.json)
    time_speed=$(jq -r ".worlds.\"$world_name\".time_speed" worlds.json)
    ores=$(jq -r ".worlds.\"$world_name\".ores | join(\",\")" worlds.json)
    ruin_enabled=$(jq -r ".worlds.\"$world_name\".ruins.enabled" worlds.json)
    ruin_spacing=$(jq -r ".worlds.\"$world_name\".ruins.spacing" worlds.json)
    hazards=$(jq -r ".worlds.\"$world_name\".hazards | join(\",\")" worlds.json)

    # Create world directory
    WORLD_DIR="$DIR/worlds/$world_name"
    mkdir -p "$WORLD_DIR/worldmods"

    # Symlink mods
    ln -sfn "$DIR/mods/nexus" "$WORLD_DIR/worldmods/nexus"
    ln -sfn "$DIR/mods/nexus_power" "$WORLD_DIR/worldmods/nexus_power"
    ln -sfn "$DIR/mods/nexus_worldgen" "$WORLD_DIR/worldmods/nexus_worldgen"
    ln -sfn "$DIR/mods/nexus_worldmanager" "$WORLD_DIR/worldmods/nexus_worldmanager"

    # world.mt
    cat > "$WORLD_DIR/world.mt" << EOF
gameid = mineclonia
backend = sqlite3
player_backend = files
auth_backend = files
EOF

    # map_meta.txt (singlenode for Mineclonia's levelgen)
    cat > "$WORLD_DIR/map_meta.txt" << EOF
mg_name = singlenode
seed = $seed
chunksize = 5
water_level = $water_level
mg_flags = caves, nodungeons, light, nodecorations, biomes, ores
mapgen_limit = 31007
mcl_singlenode_mapgen = true
[end_of_params]
EOF

    # Server config
    CONF_FILE="$DIR/config/${world_name}.conf"
    cat > "$CONF_FILE" << EOF
server_address = 127.0.0.1
port = $port
name = admin
empty_password = true
disallow_empty_password = false

secure.http_mods = nexus

language = en
default_privs = interact, shout, give

# Nexus identity
nexus.proxy_url = http://127.0.0.1:8090
nexus.world_name = $world_name
nexus.galaxy_name = $galaxy
nexus.galaxy_label = $galaxy_label
nexus.galaxy_tier = $tier
nexus.world_description = $description
nexus.api_secret = $SECRET
nexus.require_power = true

# Power system
nexus_power.ores = $ores

# Worldgen
nexus_worldgen.ruin_spacing = $ruin_spacing

# World manager
nexus_worldmanager.time_speed = $time_speed
nexus_worldmanager.hazards = $hazards
EOF

    # Add to proxy server list
    if [ -n "$PROXY_SERVERS" ]; then
        PROXY_SERVERS="${PROXY_SERVERS},"
    fi
    PROXY_SERVERS="${PROXY_SERVERS}\"$world_name\": { \"Addr\": \"127.0.0.1:$port\", \"MediaPool\": \"mineclonia\" }"

    echo "  Galaxy: $galaxy_label (tier $tier)"
    echo "  Port: $port"
    echo "  Ores: $ores"
    echo "  Hazards: $hazards"
    echo "  Terrain: $terrain (seed $seed)"
    echo

done

# Generate proxy config.json
echo "--- Proxy config ---"
DEFAULT_WORLD=$(jq -r '.worlds | keys[0]' worlds.json)
cat > "$DIR/proxy/config.json" << EOF
{
    "DefaultSrv": "$DEFAULT_WORLD",
    "BindAddr": ":40000",
    "Groups": {
        "default": ["cmd_*"]
    },
    "Servers": {
        $PROXY_SERVERS
    }
}
EOF
echo "  Default world: $DEFAULT_WORLD"
echo "  Servers: $(jq -r '.worlds | keys | join(", ")' worlds.json)"
echo

# Generate start_all.sh
echo "--- Start script ---"
{
    echo '#!/bin/bash'
    echo 'cd "$(dirname "$0")/.."'
    echo 'DIR="$(pwd)"'
    echo ''
    echo 'echo "=== Starting Nexus World Network ==="'
    echo ''
    echo '# Start proxy FIRST'
    echo 'echo "[1/N] Starting Proxy (:40000)..."'
    echo '"$DIR/scripts/start_proxy.sh" > /tmp/nexus-proxy.log 2>&1 &'
    echo 'PROXY_PID=$!'
    echo 'echo "  PID: $PROXY_PID"'
    echo 'sleep 3'

    WORLD_COUNT=$(jq '.worlds | length' worlds.json)
    IDX=1
    for world_name in $(jq -r '.worlds | keys[]' worlds.json); do
        port=$(jq -r ".worlds.\"$world_name\".port" worlds.json)
        galaxy_label=$(jq -r ".worlds.\"$world_name\".galaxy_label" worlds.json)
        IDX=$((IDX + 1))
        echo ''
        echo "echo \"[$IDX/$((WORLD_COUNT + 1))] Starting $world_name (:$port)...\""
        echo "cd \"\$DIR/engine\""
        echo "nohup ./bin/luantiserver --config \"\$DIR/config/${world_name}.conf\" --world \"\$DIR/worlds/${world_name}\" --gameid mineclonia > /tmp/nexus-${world_name}.log 2>&1 &"
        echo "echo \"  PID: \$!\""
        echo "cd \"\$DIR\""
    done

    echo ''
    echo 'echo "Waiting for servers..."'
    echo 'sleep 5'
    echo ''
    echo 'echo ""'
    echo 'echo "=== All services running ==="'
    for world_name in $(jq -r '.worlds | keys[]' worlds.json); do
        port=$(jq -r ".worlds.\"$world_name\".port" worlds.json)
        echo "echo \"$world_name server:  (log: /tmp/nexus-${world_name}.log)\""
    done
    echo 'echo "Proxy:         (log: /tmp/nexus-proxy.log)"'
    echo 'echo ""'
    echo 'echo "Connect to: 127.0.0.1:40000"'

    # Save PIDs
    echo 'echo "$PROXY_PID" > /tmp/nexus-pids.txt'

    echo ''
} > "$DIR/scripts/start_all.sh"
chmod +x "$DIR/scripts/start_all.sh"

echo "  Generated start_all.sh with $WORLD_COUNT world(s)"
echo
echo "=== Setup complete ==="
echo "Run ./scripts/start_all.sh to start the network"
