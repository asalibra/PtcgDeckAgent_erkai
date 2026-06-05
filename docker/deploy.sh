#!/bin/bash
# PTCG Deck Agent - Docker One-Click Deploy
# Usage: curl -sSL https://raw.githubusercontent.com/.../deploy.sh | bash

set -e

REPO_URL="https://github.com/asalibra/PtcgDeckAgent_erkai.git"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/ptcg-server}"
DOMAIN="${DOMAIN:-localhost}"
PORT="${PORT:-1234}"

echo "============================================"
echo "  PTCG Deck Agent - Docker Deploy"
echo "============================================"
echo "  Deploy dir: $DEPLOY_DIR"
echo "  Domain:     $DOMAIN"
echo "  Port:       $PORT"
echo "============================================"

# 1. Install Docker if missing
if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    echo "Installing docker-compose..."
    apt-get update && apt-get install -y docker-compose-plugin 2>/dev/null || \
    pip3 install docker-compose 2>/dev/null || \
    echo "Warning: docker-compose not found, using 'docker compose'"
fi

# 2. Clone or update repo
if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "Updating existing repo..."
    cd "$DEPLOY_DIR" && git pull
else
    echo "Cloning repo..."
    git clone "$REPO_URL" "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
fi

# 3. Build and start
echo "Building Docker image..."
cd "$DEPLOY_DIR/docker"

# Use docker compose (v2) or docker-compose (v1)
if docker compose version &>/dev/null; then
    COMPOSE="docker compose"
else
    COMPOSE="docker-compose"
fi

$COMPOSE build --no-cache

echo "Starting services..."
$COMPOSE up -d

# 4. Show status
echo ""
echo "============================================"
echo "  Deploy complete!"
echo ""
echo "  Web client:   http://$DOMAIN:$PORT"
echo "  WebSocket:    ws://$DOMAIN:$PORT/ws"
echo ""
echo "  Check status: $COMPOSE ps"
echo "  View logs:    $COMPOSE logs -f"
echo "  Stop:         $COMPOSE down"
echo "============================================"
