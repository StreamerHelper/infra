# Streamer Helper Docker Deployment

This directory contains Docker configuration files for deploying the Streamer Helper application.

## Architecture

```
                    ┌─────────────┐
                    │   Nginx     │ :80/:443
                    │ (Reverse    │
                    │   Proxy)    │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │  Frontend   │ │   Backend   │ │  Bull Board │
    │  (Next.js)  │ │  (MidwayJS) │ │    /ui/     │
    │   :3000     │ │    :7001    │ │             │
    └─────────────┘ └──────┬──────┘ └─────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
  │  PostgreSQL │   │    Redis    │   │    MinIO    │
  │   :5432     │   │   :6379     │   │ :9000/:9001 │
  └─────────────┘   └─────────────┘   └─────────────┘
```

## Prerequisites

- Docker 20.10+
- Docker Compose 2.0+
- **jq**（一键部署脚本用于读写 `settings.json`）：`apt install jq` / `brew install jq`
- At least 4GB RAM available for containers

## Quick Start (One-Line Deploy)

**快速一键部署（推荐）：**

```bash
curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash
```

执行后会自动完成：

- 在 `~/.streamer-helper/settings.json` 生成标准 JSON 配置（不存在时）；
- 用 **jq** 从 `settings.json` 读取并生成 `~/.streamer-helper/.docker-env` 供 compose 使用；
- 下载并启动 `docker-compose.prod.yml` 中的服务；
- 后端容器挂载 `settings.json`，启动时自动执行数据库迁移再启动应用。

**重要**：数据库密码仅在 Postgres 首次初始化时生效（写入数据卷）。之后重启或再次部署时**不要**在脚本里对服务做 `down`，以免用新 env 重建容器导致与卷内密码不一致。启动/重启请始终使用：`docker compose -f ~/.streamer-helper/docker-compose.yml --env-file ~/.streamer-helper/.docker-env up -d`。若曾误操作导致密码认证失败，可执行一次 `docker compose -f ... down -v` 后重新运行本脚本（会清空数据库）。

**使用自定义配置：**

```bash
# 在运行前设置（可选）
export APP_KEYS=your-secret-key-here       # 覆盖默认生成的 app.keys
export HTTP_PORT=8080                      # Nginx 对外暴露的 HTTP 端口
export HTTPS_PORT=8443                     # Nginx 对外暴露的 HTTPS 端口
export TYPEORM_PASSWORD=your-db-password   # 数据库密码（会写入 settings.json）
export S3_SECRET_KEY=your-minio-password   # MinIO 密码（会写入 settings.json）

curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash
```

**deploy.sh 会使用的环境变量：**

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_KEYS` | *(随机生成)* | 应用签名密钥，会写入 `settings.json` |
| `HTTP_PORT` | `80` | Nginx 对外 HTTP 端口 |
| `HTTPS_PORT` | `443` | Nginx 对外 HTTPS 端口 |
| `TYPEORM_PASSWORD` | *(随机生成)* | PostgreSQL 密码，会写入 `settings.json` |
| `S3_SECRET_KEY` | *(随机生成)* | MinIO 密码，会写入 `settings.json` |
| `STREAMER_HELPER_CONFIG_DIR` | `$HOME/.streamer-helper` | 配置目录路径 |

---

## Developer Guide

### Build & Push Images

```bash
# Build and push all images to Docker Hub
./build-and-push.sh v1.0.0

# Build without pushing (for testing)
./build-and-push.sh v1.0.0 --skip-push

# Or just push latest
./build-and-push.sh
```

Images will be pushed to:
- `docker.io/streamerhelper/backend:latest`
- `docker.io/streamerhelper/frontend:latest`
- `docker.io/streamerhelper/nginx:latest`

### CI/CD

This repository uses GitHub Actions to automatically build and push Docker images:

- **Trigger**: Push a tag starting with `v` (e.g., `v1.0.0`)
- **Manual**: Use the "workflow_dispatch" event in GitHub Actions UI

Required GitHub Secrets:
- `DOCKERHUB_USERNAME` - Docker Hub username
- `DOCKERHUB_TOKEN` - Docker Hub access token
- `GH_PAT` (optional) - GitHub Personal Access Token for private repos

### Local Development

1. **Copy environment file**
   ```bash
   cp .env.example .env
   ```

2. **Edit environment variables**
   ```bash
   vim .env
   ```
   Update passwords and secrets for production use.

3. **Start all services (with local build)**
   ```bash
   docker compose up -d --build
   ```

4. **Check service status**
   ```bash
   docker compose ps
   ```

5. **View logs**
   ```bash
   # All services
   docker compose logs -f

   # Specific service
   docker compose logs -f backend
   ```

## Service Endpoints

| Service | URL | Description |
|---------|-----|-------------|
| Frontend | http://localhost | Web UI |
| API | http://localhost/api | Backend API |
| Bull Board | http://localhost/ui | Queue monitoring |
| MinIO Console | http://localhost:9001 | Object storage management |

## Database Migration

数据库迁移会在 **后端容器启动时自动执行**：

- backend 镜像的入口脚本会在启动应用前运行 `node dist/scripts/run-migrations.js`；
- 当数据库没有新的迁移时，该脚本会直接退出并启动应用；
- 部署脚本 `deploy.sh` 会等待 backend 健康检查通过后再提示部署完成。

只有在调试或手动迁移时，你才需要进入容器执行：

```bash
docker compose -f ~/.streamer-helper/docker-compose.yml exec backend sh
node dist/scripts/run-migrations.js
```

## MinIO Setup

After starting services, create the required bucket:

1. Open MinIO Console: http://localhost:9001
2. Login with `S3_ACCESS_KEY` and `S3_SECRET_KEY`
3. Create a bucket named `streamerhelper-archive`
4. Set bucket policy to public read (if needed)

## Configuration

### Config file (settings.json)

- **路径**：`~/.streamer-helper/settings.json`（可通过环境变量 `STREAMER_HELPER_CONFIG_DIR` 或 deploy 生成的 `CONFIG_DIR` 覆盖）
- **格式**：标准 JSON，便于编辑器与脚本（如 jq）解析。
- **示例**：[settings.example.json](./settings.example.json)
- **Schema**：[settings.schema.json](./settings.schema.json) 可供 IDE 校验与补全。
- **注意**：`database.password` 仅在首次创建 Postgres 数据卷时生效；之后修改该字段不会改变已存在数据库的密码，需先 `down -v` 再重新部署（会清空数据）或自行在库内修改 postgres 用户密码。

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_KEYS` | - | Application secret key |
| `TYPEORM_USERNAME` | postgres | Database username |
| `TYPEORM_PASSWORD` | postgres | Database password |
| `TYPEORM_DATABASE` | streamerhelper | Database name |
| `REDIS_PASSWORD` | - | Redis password (optional) |
| `S3_ACCESS_KEY` | minioadmin | MinIO access key |
| `S3_SECRET_KEY` | minioadmin | MinIO secret key |
| `S3_BUCKET` | streamerhelper-archive | Storage bucket name |

### Ports

| Service | Internal | External (default) |
|---------|----------|-------------------|
| Nginx | 80/443 | 80/443 |
| PostgreSQL | 5432 | 5432 |
| Redis | 6379 | 6379 |
| MinIO API | 9000 | 9000 |
| MinIO Console | 9001 | 9001 |

## Production Checklist

- [ ] Change all default passwords in `.env`
- [ ] Configure SSL/TLS certificates for Nginx
- [ ] Set up regular database backups
- [ ] Configure log rotation
- [ ] Set up monitoring and alerting
- [ ] Review and adjust resource limits

## Troubleshooting

### Backend won't start

1. Check database connection:
   ```bash
   docker compose exec postgres pg_isready
   ```

2. Check Redis connection:
   ```bash
   docker compose exec redis redis-cli ping
   ```

3. View backend logs:
   ```bash
   docker compose logs backend
   ```

### Frontend build fails

1. Check Node.js version compatibility
2. Ensure all dependencies are installed
3. Check build logs:
   ```bash
   docker compose logs frontend
   ```

### MinIO connection issues

1. Verify MinIO is running:
   ```bash
   docker compose ps minio
   ```

2. Check MinIO health:
   ```bash
   curl http://localhost:9000/minio/health/live
   ```

## Useful Commands

```bash
# Stop all services
docker compose down

# Stop and remove volumes
docker compose down -v

# Rebuild images
docker compose build --no-cache

# View resource usage
docker compose top

# Execute command in container
docker compose exec backend sh
```
