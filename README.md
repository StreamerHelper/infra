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
- At least 4GB RAM available for containers

## Quick Start (One-Line Deploy)

**Deploy with default configuration:**

```bash
curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash
```

**Deploy with custom configuration:**

```bash
# Set environment variables before running
export APP_KEYS=your-secret-key-here
export HTTP_PORT=8080
export TYPEORM_PASSWORD=your-db-password

curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash
```

**All configurable environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_KEYS` | `streamer-helper-default-...` | Session secret key |
| `HTTP_PORT` | `80` | HTTP port |
| `HTTPS_PORT` | `443` | HTTPS port |
| `TYPEORM_USERNAME` | `postgres` | Database username |
| `TYPEORM_PASSWORD` | `postgres` | Database password |
| `TYPEORM_DATABASE` | `livestream` | Database name |
| `REDIS_PASSWORD` | *(empty)* | Redis password |
| `S3_ACCESS_KEY` | `minioadmin` | MinIO access key |
| `S3_SECRET_KEY` | `minioadmin` | MinIO secret key |
| `S3_BUCKET` | `livestream-archive` | Storage bucket name |
| `BACKEND_VERSION` | `latest` | Docker image version |

---

## Developer Guide

### Build & Push Images

```bash
# Build and push all images to Docker Hub
./build-and-push.sh v1.0.0

# Or just push latest
./build-and-push.sh
```

Images will be pushed to:
- `docker.io/streamerhelper/streamerhelper-backend:latest`
- `docker.io/streamerhelper/streamerhelper-frontend:latest`
- `docker.io/streamerhelper/streamerhelper-nginx:latest`

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

Run database migrations after first deployment:

```bash
docker compose exec backend sh -c "pnpm migration:run"
```

## MinIO Setup

After starting services, create the required bucket:

1. Open MinIO Console: http://localhost:9001
2. Login with `S3_ACCESS_KEY` and `S3_SECRET_KEY`
3. Create a bucket named `livestream-archive`
4. Set bucket policy to public read (if needed)

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_KEYS` | - | Application secret key |
| `TYPEORM_USERNAME` | postgres | Database username |
| `TYPEORM_PASSWORD` | postgres | Database password |
| `TYPEORM_DATABASE` | livestream | Database name |
| `REDIS_PASSWORD` | - | Redis password (optional) |
| `S3_ACCESS_KEY` | minioadmin | MinIO access key |
| `S3_SECRET_KEY` | minioadmin | MinIO secret key |
| `S3_BUCKET` | livestream-archive | Storage bucket name |

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
