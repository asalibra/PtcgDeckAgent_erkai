# Docker 部署指南

## 架构

```
客户端 (浏览器/桌面)
    ↓ ws://your-domain.com:1234/ws
Docker 容器
    ├── nginx (端口 8080→外部 1234)
    │   ├── 静态文件: Web 客户端 (exports/web/)
    │   └── WebSocket 代理: /ws → 127.0.0.1:9000
    └── Godot headless (端口 9000)
        └── 对战服务器 (ServerMain.gd)
```

## 一键部署

```bash
# 在服务器上执行
curl -sSL https://raw.githubusercontent.com/asalibra/PtcgDeckAgent_erkai/main/docker/deploy.sh | bash
```

或手动部署：

```bash
# 1. 克隆仓库
git clone https://github.com/asalibra/PtcgDeckAgent_erkai.git
cd PtcgDeckAgent_erkai/docker

# 2. 构建镜像
docker compose build

# 3. 启动服务
docker compose up -d

# 4. 查看日志
docker compose logs -f
```

## 访问地址

| 服务 | 地址 |
|------|------|
| Web 客户端 | http://your-domain.com:1234 |
| WebSocket | ws://your-domain.com:1234/ws |

## 常用命令

```bash
# 查看状态
docker compose ps

# 查看日志
docker compose logs -f

# 重启
docker compose restart

# 停止
docker compose down

# 更新代码后重新部署
git pull && docker compose up -d --build
```

## 配置修改

### 修改端口

编辑 `docker-compose.yml`：
```yaml
ports:
  - "1234:8080"   # 改为需要的外部端口
```

### 修改域名

客户端连接时输入：`ws://your-domain.com:1234/ws`

### TLS/HTTPS

如需 HTTPS，需要：
1. 配置 SSL 证书
2. 修改 nginx.conf 添加 SSL 配置
3. 客户端使用 `wss://` 连接

## 故障排查

```bash
# 检查容器是否运行
docker compose ps

# 查看实时日志
docker compose logs -f

# 进入容器调试
docker exec -it ptcg-server bash

# 测试 WebSocket 连接
curl -v -H "Upgrade: websocket" -H "Connection: Upgrade" http://localhost:1234/ws
```
