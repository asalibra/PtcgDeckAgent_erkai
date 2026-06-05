#!/bin/bash
set -e

SERVER_PORT=${SERVER_PORT:-9000}
WEB_PORT=${WEB_PORT:-8080}

echo "============================================"
echo "  PTCG Deck Agent - Docker Server"
echo "============================================"
echo "  WebSocket: port $SERVER_PORT"
echo "  Web:       port $WEB_PORT"
echo "============================================"

# Create server config from template if missing
if [ ! -f /app/scripts/server/server_config.json ] && [ -f /app/scripts/server/server_config.example.json ]; then
    cp /app/scripts/server/server_config.example.json /app/scripts/server/server_config.json
    echo "Created server_config.json from template"
fi

# Start game server in background
echo "Starting game server on port $SERVER_PORT..."
godot --headless --path /app -s res://scripts/server/ServerMain.gd -- --port=$SERVER_PORT &
SERVER_PID=$!

# Wait for server to be ready
sleep 2

# Start nginx
echo "Starting nginx on port $WEB_PORT..."
nginx -g 'daemon off;' &
NGINX_PID=$!

# Cleanup on exit
cleanup() {
    echo "Shutting down..."
    kill $SERVER_PID 2>/dev/null
    kill $NGINX_PID 2>/dev/null
    wait
    echo "Done."
}
trap cleanup EXIT INT TERM

echo "All services started."
wait
