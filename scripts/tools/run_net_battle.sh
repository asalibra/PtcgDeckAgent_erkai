#!/bin/bash
# PTCG Deck Agent - Network Battle Launcher
# Usage: ./run_net_battle.sh [--server-port 9000] [--web-port 8080] [--godot-path /path/to/godot]

SERVER_PORT=9000
WEB_PORT=8080
GODOT_PATH=""
EXPORT_DIR=""
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --server-port) SERVER_PORT="$2"; shift 2 ;;
        --web-port) WEB_PORT="$2"; shift 2 ;;
        --godot-path) GODOT_PATH="$2"; shift 2 ;;
        --export-dir) EXPORT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$EXPORT_DIR" ]; then
    EXPORT_DIR="$PROJECT_ROOT/exports/web"
fi

# Find Godot
if [ -z "$GODOT_PATH" ]; then
    GODOT_PATH=$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null || echo "")
fi
if [ -z "$GODOT_PATH" ]; then
    echo "[!] Godot not found. Please install and add to PATH, or use --godot-path"
    exit 1
fi

echo "============================================"
echo "  PTCG Deck Agent - Network Battle Launcher"
echo "============================================"
echo ""
echo "  Project dir:     $PROJECT_ROOT"
echo "  WebSocket port:  $SERVER_PORT"
echo "  Web HTTP port:   $WEB_PORT"
echo "  Web export dir:  $EXPORT_DIR"
echo "  Godot path:      $GODOT_PATH"
echo ""

# Check web export
if [ ! -f "$EXPORT_DIR/index.html" ]; then
    HTML_FILE=$(find "$EXPORT_DIR" -name "*.html" -print -quit 2>/dev/null)
    if [ -n "$HTML_FILE" ]; then
        cp "$HTML_FILE" "$EXPORT_DIR/index.html"
        echo "  Auto-created index.html from $(basename "$HTML_FILE")"
    else
        echo "[!] No HTML files in $EXPORT_DIR"
        echo "    Export Web version from Godot editor first"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    fi
fi

cleanup() {
    echo ""
    echo "Stopping services..."
    [ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null && echo "  Server stopped"
    [ -n "$WEB_PID" ] && kill $WEB_PID 2>/dev/null && echo "  Web service stopped"
    echo "Done"
}
trap cleanup EXIT

echo "[1/2] Starting game server (port $SERVER_PORT)..."
"$GODOT_PATH" --headless --path "$PROJECT_ROOT" -s res://scripts/server/ServerMain.gd -- --port=$SERVER_PORT &
SERVER_PID=$!
sleep 2

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "[!] Server failed to start"
    exit 1
fi

echo "[2/2] Starting web hosting service (port $WEB_PORT)..."
python3 "$PROJECT_ROOT/scripts/tools/serve_web_export.py" $WEB_PORT "$EXPORT_DIR" &
WEB_PID=$!
sleep 1

echo ""
echo "============================================"
echo "  All services started!"
echo ""
echo "  Open browser:  http://localhost:$WEB_PORT"
echo "  Server addr:   ws://localhost:$SERVER_PORT"
echo ""
echo "  Press Ctrl+C to stop"
echo "============================================"
echo ""

wait
