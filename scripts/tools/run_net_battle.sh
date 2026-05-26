#!/bin/bash
# PTCG Deck Agent - Network Battle Server Quick Start
# Usage: ./run_net_battle.sh [--port 9000] [--web-port 8080]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SERVER_PORT=${SERVER_PORT:-9000}
WEB_PORT=${WEB_PORT:-8080}
EXPORT_DIR="$PROJECT_DIR/exports/web"

while [[ $# -gt 0 ]]; do
    case $1 in
        --port) SERVER_PORT="$2"; shift 2 ;;
        --web-port) WEB_PORT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Find Godot binary
GODOT_BIN=$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null || echo "")
if [ -z "$GODOT_BIN" ]; then
    echo "[!] Godot not found. Please install Godot or run deploy_server.sh first."
    exit 1
fi

# Ensure server config exists
if [ ! -f "$PROJECT_DIR/scripts/server/server_config.json" ] && [ -f "$PROJECT_DIR/scripts/server/server_config.example.json" ]; then
    cp "$PROJECT_DIR/scripts/server/server_config.example.json" "$PROJECT_DIR/scripts/server/server_config.json"
    echo "  Created server_config.json from example template"
fi

echo "============================================"
echo "  PTCG Deck Agent - Network Battle Server"
echo "============================================"
echo ""
echo "  Game server:   ws://0.0.0.0:$SERVER_PORT"
echo "  Web client:    http://0.0.0.0:$WEB_PORT"
echo ""
echo "  Press Ctrl+C to stop"
echo "============================================"
echo ""

# Start game server in background
"$GODOT_BIN" --headless --path "$PROJECT_DIR" -s res://scripts/server/ServerMain.gd -- --port=$SERVER_PORT &
SERVER_PID=$!

# Start web server if export exists
if [ -d "$EXPORT_DIR" ] && command -v python3 &>/dev/null; then
    python3 "$PROJECT_DIR/scripts/tools/serve_web_export.py" $WEB_PORT "$EXPORT_DIR" &
    WEB_PID=$!
fi

# Cleanup on exit
cleanup() {
    echo ""
    echo "Stopping servers..."
    kill $SERVER_PID 2>/dev/null
    [ -n "$WEB_PID" ] && kill $WEB_PID 2>/dev/null
    wait
    echo "Done."
}
trap cleanup EXIT INT TERM

wait
