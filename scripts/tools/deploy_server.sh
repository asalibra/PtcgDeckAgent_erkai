#!/bin/bash
# PTCG Deck Agent - Cloud Server One-Click Deploy
# Usage: curl -sSL <raw-url> | bash -s -- [--port 9000] [--web-port 8080]
# Or: ./deploy_server.sh [--port 9000] [--web-port 8080]

set -e

SERVER_PORT=${SERVER_PORT:-9000}
WEB_PORT=${WEB_PORT:-8080}
GODOT_VERSION="4.6.2"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/ptcg-server}"
PROJECT_REPO=""  # Set if using git clone

while [[ $# -gt 0 ]]; do
    case $1 in
        --port) SERVER_PORT="$2"; shift 2 ;;
        --web-port) WEB_PORT="$2"; shift 2 ;;
        --deploy-dir) DEPLOY_DIR="$2"; shift 2 ;;
        --repo) PROJECT_REPO="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "============================================"
echo "  PTCG Deck Agent - Cloud Server Deploy"
echo "============================================"
echo ""
echo "  Deploy dir:    $DEPLOY_DIR"
echo "  Server port:   $SERVER_PORT"
echo "  Web port:      $WEB_PORT"
echo ""

# ---------- 1. Install dependencies ----------
echo "[1/5] Checking dependencies..."

install_godot() {
    echo "  Downloading Godot ${GODOT_VERSION} for Linux..."
    local url="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
    local tmp_dir=$(mktemp -d)
    wget -q --show-progress -O "$tmp_dir/godot.zip" "$url"
    unzip -q -o "$tmp_dir/godot.zip" -d "$tmp_dir"
    chmod +x "$tmp_dir"/Godot_v${GODOT_VERSION}-stable_linux.x86_64
    sudo mv "$tmp_dir"/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot
    rm -rf "$tmp_dir"
    echo "  Godot installed to /usr/local/bin/godot"
}

if ! command -v godot &>/dev/null && ! command -v godot4 &>/dev/null; then
    echo "  Godot not found, installing..."
    install_godot
fi
GODOT_BIN=$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null)
echo "  Godot: $GODOT_BIN"

if ! command -v python3 &>/dev/null; then
    echo "  Installing Python3..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq python3
    elif command -v yum &>/dev/null; then
        sudo yum install -y python3
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm python
    else
        echo "[!] Cannot install Python3 automatically"
        exit 1
    fi
fi
echo "  Python3: $(python3 --version)"

# ---------- 2. Get project files ----------
echo ""
echo "[2/5] Setting up project files..."

mkdir -p "$DEPLOY_DIR"

if [ -n "$PROJECT_REPO" ]; then
    if [ -d "$DEPLOY_DIR/.git" ]; then
        echo "  Updating existing repo..."
        cd "$DEPLOY_DIR" && git pull
    else
        echo "  Cloning $PROJECT_REPO..."
        git clone "$PROJECT_REPO" "$DEPLOY_DIR"
    fi
elif [ -f "$DEPLOY_DIR/project.godot" ]; then
    echo "  Using existing project at $DEPLOY_DIR"
else
    echo "[!] No project files found at $DEPLOY_DIR"
    echo "    Use --repo <git-url> to clone, or copy project files to $DEPLOY_DIR"
    exit 1
fi

cd "$DEPLOY_DIR"

# ---------- 3. Export web client ----------
echo ""
echo "[3/5] Exporting web client..."

EXPORT_DIR="$DEPLOY_DIR/exports/web"
mkdir -p "$EXPORT_DIR"

# Check if export preset exists
if [ ! -f "export_presets.cfg" ]; then
    echo "[!] No export_presets.cfg found, skipping export"
    echo "    Please export manually or copy web export files to $EXPORT_DIR"
else
    # Export using Godot CLI
    $GODOT_BIN --headless --path "$DEPLOY_DIR" --export-release "Web" "$EXPORT_DIR/index.html" 2>&1 | tail -5
    if [ $? -ne 0 ]; then
        echo "[!] Export failed, trying debug export..."
        $GODOT_BIN --headless --path "$DEPLOY_DIR" --export-debug "Web" "$EXPORT_DIR/index.html" 2>&1 | tail -5
    fi
fi

# Ensure index.html exists
if [ ! -f "$EXPORT_DIR/index.html" ]; then
    HTML_FILE=$(find "$EXPORT_DIR" -name "*.html" -print -quit 2>/dev/null)
    if [ -n "$HTML_FILE" ]; then
        cp "$HTML_FILE" "$EXPORT_DIR/index.html"
        echo "  Created index.html from $(basename "$HTML_FILE")"
    else
        echo "[!] No HTML files found in $EXPORT_DIR"
        echo "    Web clients will not be available"
    fi
fi
echo "  Web export: $EXPORT_DIR"

# ---------- 4. Create systemd service (optional) ----------
echo ""
echo "[4/5] Setting up service..."

SERVICE_FILE="/etc/systemd/system/ptcg-server.service"
CREATE_SERVICE=""

if [ -t 0 ]; then
    read -p "  Create systemd service for auto-start? (y/N) " -n 1 -r CREATE_SERVICE
    echo
fi

if [[ "$CREATE_SERVICE" =~ ^[Yy]$ ]]; then
    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=PTCG Deck Agent Network Battle Server
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$DEPLOY_DIR
ExecStart=$GODOT_BIN --headless --path $DEPLOY_DIR -s res://scripts/server/ServerMain.gd -- --port=$SERVER_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Web service
    sudo tee "/etc/systemd/system/ptcg-web.service" > /dev/null <<EOF
[Unit]
Description=PTCG Deck Agent Web Server
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$DEPLOY_DIR
ExecStart=$(command -v python3) $DEPLOY_DIR/scripts/tools/serve_web_export.py $WEB_PORT $EXPORT_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable ptcg-server ptcg-web
    echo "  Services created. Use 'sudo systemctl start ptcg-server ptcg-web' to start"
else
    echo "  Skipped. Use run_net_battle.sh to start manually"
fi

# ---------- 5. Start services ----------
echo ""
echo "[5/5] Starting services..."

if [[ "$CREATE_SERVICE" =~ ^[Yy]$ ]]; then
    sudo systemctl start ptcg-server ptcg-web
    echo "  Services started via systemd"
    echo "  Check status: systemctl status ptcg-server ptcg-web"
else
    # Start directly in background
    nohup $GODOT_BIN --headless --path "$DEPLOY_DIR" -s res://scripts/server/ServerMain.gd -- --port=$SERVER_PORT > "$DEPLOY_DIR/server.log" 2>&1 &
    echo $! > "$DEPLOY_DIR/server.pid"

    nohup python3 "$DEPLOY_DIR/scripts/tools/serve_web_export.py" $WEB_PORT "$EXPORT_DIR" > "$DEPLOY_DIR/web.log" 2>&1 &
    echo $! > "$DEPLOY_DIR/web.pid"

    echo "  Server PID: $(cat $DEPLOY_DIR/server.pid)"
    echo "  Web PID:    $(cat $DEPLOY_DIR/web.pid)"
    echo ""
    echo "  Logs: $DEPLOY_DIR/server.log, $DEPLOY_DIR/web.log"
    echo "  Stop: kill \$(cat $DEPLOY_DIR/server.pid) \$(cat $DEPLOY_DIR/web.pid)"
fi

echo ""
echo "============================================"
echo "  Deploy complete!"
echo ""
echo "  Game server:   ws://$(hostname -I | awk '{print $1}'):$SERVER_PORT"
echo "  Web client:    http://$(hostname -I | awk '{print $1}'):$WEB_PORT"
echo ""
echo "  Config file:   $DEPLOY_DIR/scripts/server/server_config.json"
echo "  (create this file to override default ports)"
echo "============================================"
