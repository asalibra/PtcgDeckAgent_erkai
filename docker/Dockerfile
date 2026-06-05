FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    unzip \
    ca-certificates \
    python3 \
    python3-pip \
    nginx \
    && rm -rf /var/lib/apt/lists/*

# Install Godot
ARG GODOT_VERSION=4.6.2
RUN wget -q --show-progress -O /tmp/godot.zip \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && unzip -q -o /tmp/godot.zip -d /tmp \
    && mv /tmp/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm -rf /tmp/godot.zip

# Copy project files
WORKDIR /app
COPY . /app/

# Export web client
RUN mkdir -p /app/exports/web \
    && godot --headless --path /app --export-release "Web" /app/exports/web/index.html || true

# Copy nginx config
COPY docker/nginx.conf /etc/nginx/sites-available/default

# Copy entrypoint
COPY docker/entrypoint.sh /app/docker/entrypoint.sh
RUN chmod +x /app/docker/entrypoint.sh

# Expose ports
# 9000 = WebSocket game server
# 8080 = Web client (nginx)
EXPOSE 9000 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -f http://localhost:8080/ || exit 1

ENTRYPOINT ["/app/docker/entrypoint.sh"]
