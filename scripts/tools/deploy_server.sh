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
EXPORT_LOG=""
WEB_EXPORT_NAME="index.html"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_BASE_URL="${CLOUDFLARE_BASE_URL:-}"

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
if [ -n "$CLOUDFLARE_BASE_URL" ]; then
    echo "  Purge target:  $CLOUDFLARE_BASE_URL"
fi
echo ""

# ---------- 1. Install dependencies ----------
echo "[1/5] Checking dependencies..."

install_package_if_missing() {
    local command_name="$1"
    local package_name="$2"

    if command -v "$command_name" &>/dev/null; then
        return
    fi

    echo "  Installing missing dependency: $package_name"
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "$package_name"
    elif command -v yum &>/dev/null; then
        sudo yum install -y "$package_name"
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm "$package_name"
    else
        echo "[!] Cannot install required package automatically: $package_name"
        exit 1
    fi
}

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

godot_templates_installed() {
    local base_dir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
    local candidates=(
        "$base_dir/${GODOT_VERSION}.stable"
        "$base_dir/${GODOT_VERSION}.stable.official"
    )

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ] && find "$candidate" -maxdepth 1 -type f | grep -q .; then
            return 0
        fi
    done

    return 1
}

install_godot_export_templates() {
    echo "  Installing Godot export templates ${GODOT_VERSION}..."
    local url="${GODOT_TEMPLATES_URL:-https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local archive_path="$tmp_dir/export_templates.tpz"
    local extract_dir="$tmp_dir/extracted"
    local base_dir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
    local candidates=(
        "$base_dir/${GODOT_VERSION}.stable"
        "$base_dir/${GODOT_VERSION}.stable.official"
    )

    wget -q --show-progress -O "$archive_path" "$url"
    mkdir -p "$extract_dir"
    unzip -q -o "$archive_path" -d "$extract_dir"

    if [ ! -d "$extract_dir/templates" ]; then
        echo "[!] Export templates archive missing templates/ directory"
        rm -rf "$tmp_dir"
        exit 1
    fi

    mkdir -p "$base_dir"
    for candidate in "${candidates[@]}"; do
        mkdir -p "$candidate"
        cp -f "$extract_dir/templates/"* "$candidate/"
    done

    rm -rf "$tmp_dir"
    echo "  Export templates installed under $base_dir"
}

install_package_if_missing wget wget
install_package_if_missing unzip unzip

if ! command -v godot &>/dev/null && ! command -v godot4 &>/dev/null; then
    echo "  Godot not found, installing..."
    install_godot
fi
GODOT_BIN=$(command -v godot 2>/dev/null || command -v godot4 2>/dev/null)
echo "  Godot: $GODOT_BIN"

if ! godot_templates_installed; then
    install_godot_export_templates
else
    echo "  Export templates: already installed"
fi

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

# Setup server config from template if not exists
if [ ! -f "$DEPLOY_DIR/scripts/server/server_config.json" ] && [ -f "$DEPLOY_DIR/scripts/server/server_config.example.json" ]; then
    cp "$DEPLOY_DIR/scripts/server/server_config.example.json" "$DEPLOY_DIR/scripts/server/server_config.json"
    echo "  Created server_config.json from example template"
fi

# ---------- 3. Export web client ----------
echo ""
echo "[3/5] Exporting web client..."

EXPORT_DIR="$DEPLOY_DIR/exports/web"
EXPORT_LOG="$DEPLOY_DIR/export_web.log"
WEB_EXPORT_PATH="$EXPORT_DIR/$WEB_EXPORT_NAME"
INDEX_EXPORT_PATH="$EXPORT_DIR/index.html"
mkdir -p "$EXPORT_DIR"

# Check if export preset exists
if [ ! -f "export_presets.cfg" ]; then
    echo "[!] No export_presets.cfg found, skipping export"
    echo "    Please export manually or copy web export files to $EXPORT_DIR"
else
    # Export using Godot CLI
    if ! "$GODOT_BIN" --headless --path "$DEPLOY_DIR" --export-release "Web" "$WEB_EXPORT_PATH" > "$EXPORT_LOG" 2>&1; then
        echo "[!] Export failed, trying debug export..."
        if ! "$GODOT_BIN" --headless --path "$DEPLOY_DIR" --export-debug "Web" "$WEB_EXPORT_PATH" >> "$EXPORT_LOG" 2>&1; then
            echo "[!] Web export failed. Last lines:"
            tail -20 "$EXPORT_LOG"
        fi
    fi
fi

# Ensure a discoverable HTML entry exists
if [ ! -f "$WEB_EXPORT_PATH" ] && [ -f "$INDEX_EXPORT_PATH" ]; then
    cp "$INDEX_EXPORT_PATH" "$WEB_EXPORT_PATH"
    echo "  Created $WEB_EXPORT_NAME from index.html"
fi

if [ ! -f "$INDEX_EXPORT_PATH" ] && [ -f "$WEB_EXPORT_PATH" ]; then
    cp "$WEB_EXPORT_PATH" "$INDEX_EXPORT_PATH"
    echo "  Created index.html from $WEB_EXPORT_NAME"
fi

if [ ! -f "$INDEX_EXPORT_PATH" ] && [ ! -f "$WEB_EXPORT_PATH" ]; then
    HTML_FILE=$(find "$EXPORT_DIR" -name "*.html" -print -quit 2>/dev/null)
    if [ -n "$HTML_FILE" ]; then
        cp "$HTML_FILE" "$INDEX_EXPORT_PATH"
        cp "$HTML_FILE" "$WEB_EXPORT_PATH"
        echo "  Created index.html and $WEB_EXPORT_NAME from $(basename "$HTML_FILE")"
    else
        echo "[!] No HTML files found in $EXPORT_DIR"
        if [ -f "$EXPORT_LOG" ]; then
            echo "  Export log (last 20 lines):"
            tail -20 "$EXPORT_LOG"
        fi
        echo "    Aborting deploy because web export is missing"
        exit 1
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
echo "[5/6] Starting services..."

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


# ---------- 6. Sync to Nginx public directory ----------
echo ""
echo "[6/6] Syncing web export to Nginx public directory..."
NGINX_WEB_ROOT="/var/www/ptcgdeckagent"
if [ -d "$NGINX_WEB_ROOT" ]; then
    echo "  Syncing $EXPORT_DIR/ -> $NGINX_WEB_ROOT ..."
    sudo rsync -av --delete "$EXPORT_DIR/" "$NGINX_WEB_ROOT/"
    echo "  Nginx public directory updated."
else
    echo "  [!] Nginx web root $NGINX_WEB_ROOT does not exist. Skipping sync."
    echo "      If this is a new server, create it with: sudo mkdir -p $NGINX_WEB_ROOT && sudo chown $(whoami) $NGINX_WEB_ROOT"
fi

# ---------- 7. Purge Cloudflare cache (optional) ----------
echo ""
echo "[7/7] Purging Cloudflare cache..."

if [ -n "$CLOUDFLARE_ZONE_ID" ] && [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_BASE_URL" ]; then
    PURGE_ARGS=(
        --zone-id "$CLOUDFLARE_ZONE_ID"
        --api-token "$CLOUDFLARE_API_TOKEN"
        --base-url "$CLOUDFLARE_BASE_URL"
        --export-dir "$EXPORT_DIR"
    )

    if [ -n "${CLOUDFLARE_PURGE_EVERYTHING:-}" ]; then
        PURGE_ARGS+=(--purge-everything)
    fi

    if python3 "$DEPLOY_DIR/scripts/tools/purge_cloudflare_cache.py" "${PURGE_ARGS[@]}"; then
        echo "  Cloudflare purge requested successfully"
    else
        echo "[!] Cloudflare purge failed; deployment completed but CDN may still serve stale files"
    fi
else
    echo "  Skipped. Set CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN, and CLOUDFLARE_BASE_URL to enable auto purge"
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
