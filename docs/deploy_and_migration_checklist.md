# PTCG Deck Agent 部署与迁移 Checklist

## 1. 服务器依赖
- Ubuntu 20.04+/Debian/CentOS
- Python 3.8+
- Godot 4.6.x (自动安装)
- Nginx 1.18+
- systemd
- certbot (如需 HTTPS)

## 2. 目录结构
- `/root/ptcg-server` — 项目主目录（git clone）
- `/root/ptcg-server/exports/web` — Godot 导出产物（deploy_server.sh 自动生成）
- `/var/www/ptcgdeckagent` — Nginx 静态资源目录（实际公网服务目录）

## 3. Nginx 配置模板
```
server {
    listen 80;
    listen [::]:80;
    server_name ptcg4npg.us.cc www.ptcg4npg.us.cc;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://ptcg4npg.us.cc$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ptcg4npg.us.cc www.ptcg4npg.us.cc;
    root /var/www/ptcgdeckagent;
    index index.html;
    ssl_certificate /etc/letsencrypt/live/ptcg4npg.us.cc/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ptcg4npg.us.cc/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/javascript application/javascript application/json application/wasm application/octet-stream image/svg+xml;
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Embedder-Policy "require-corp" always;
    location = /index.html {
        default_type text/html;
        expires -1;
        try_files $uri =404;
    }
    location ~* \.wasm$ {
        default_type application/wasm;
        expires 7d;
        try_files $uri =404;
    }
    location ~* \.(pck|js|png|jpg|jpeg|gif|webp|ico|worklet\.js)$ {
        expires 7d;
        try_files $uri =404;
    }
    location /ws {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
    }
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

## 4. systemd 服务模板
- `/etc/systemd/system/ptcg-server.service` — Godot 后端
- `/etc/systemd/system/ptcg-web.service` — 8080 端口静态 HTTP（可选）

## 5. 自动部署与同步
- `deploy_server.sh` 只会导出到 `/root/ptcg-server/exports/web`，**不会自动同步到 `/var/www/ptcgdeckagent`**。
- 需要加一步：
  ```bash
  rsync -av --delete /root/ptcg-server/exports/web/ /var/www/ptcgdeckagent/
  ```
- 建议把这步写进部署脚本或 CI/CD。

## 6. Cloudflare 自动 purge
- `deploy_server.sh` 已支持自动调用 `purge_cloudflare_cache.py`，需设置：
  - `CLOUDFLARE_ZONE_ID`
  - `CLOUDFLARE_API_TOKEN`
  - `CLOUDFLARE_BASE_URL`（如 https://ptcg4npg.us.cc）
- 推荐用环境变量或 `.env` 文件，不要把 token 写进仓库。

## 7. 迁移服务器 Checklist
- 备份 `/root/ptcg-server`（含 git、导出产物、配置）
- 备份 `/var/www/ptcgdeckagent`（如有本地上传文件/图片）
- 备份 `/etc/nginx/sites-available/ptcgdeckagent` 和相关证书
- 备份 `/etc/systemd/system/ptcg-server.service`、`ptcg-web.service`
- 迁移 Cloudflare DNS 解析
- 重新部署并同步静态资源
- 检查 systemd 服务和 Nginx reload
- 验证 Cloudflare purge 是否生效

---
如需自定义端口、域名、证书路径，请同步修改 Nginx 配置和 systemd 服务。
