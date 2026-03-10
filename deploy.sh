#!/bin/bash

#=============================================================#
#  StreamerHelper One-Line Deploy Script                      #
#  Usage: curl -fsSL https://raw.githubusercontent.com/        #
#         StreamerHelper/infra/main/deploy.sh | bash          #
#                                                             #
#  Configuration via environment variables:                   #
#    export APP_KEYS=your-secret-key                          #
#    export HTTP_PORT=8080                                    #
#    curl ... | bash                                          #
#=============================================================#

set -e

COMPOSE_URL="https://raw.githubusercontent.com/StreamerHelper/infra/main/docker-compose.prod.yml"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           StreamerHelper Quick Deploy                     ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Show current configuration
log_info "Configuration:"
echo "  APP_KEYS:        ${APP_KEYS:-<default>}"
echo "  HTTP_PORT:       ${HTTP_PORT:-80}"
echo "  HTTPS_PORT:      ${HTTPS_PORT:-443}"
echo "  DB_PASSWORD:     ${TYPEORM_PASSWORD:-postgres}"
echo "  REDIS_PASSWORD:  ${REDIS_PASSWORD:-<none>}"
echo "  MINIO_USER:      ${S3_ACCESS_KEY:-minioadmin}"
echo "  MINIO_PASSWORD:  ${S3_SECRET_KEY:-minioadmin}"
echo "  IMAGE_VERSION:   ${BACKEND_VERSION:-latest}"
echo ""

# Download compose file
log_info "Downloading docker-compose file..."
curl -fsSL "$COMPOSE_URL" -o /tmp/streamer-compose.yml

# Stop existing services if running
if docker ps --format '{{.Names}}' | grep -q "^streamer-"; then
    log_info "Stopping existing services..."
    docker compose -f /tmp/streamer-compose.yml down --remove-orphans 2>/dev/null || true
fi

# Start services
log_info "Starting services..."
docker compose -f /tmp/streamer-compose.yml up -d

# Wait for backend healthy
log_info "Waiting for backend to be ready..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if docker inspect streamer-backend --format '{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo "  Waiting... (${WAITED}s/${MAX_WAIT}s)"
done

if [ $WAITED -ge $MAX_WAIT ]; then
    log_error "Backend failed to start. Check logs: docker logs streamer-backend"
    exit 1
fi

# Run database migrations
log_info "Running database migrations..."
docker compose -f /tmp/streamer-compose.yml exec -T backend sh -c "pnpm run migration:run" 2>/dev/null || {
    log_warn "Migration may have already been applied"
}

# Done
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                   Deploy Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Frontend:    http://localhost:${HTTP_PORT:-80}                        "
echo "║  MinIO:       http://localhost:9001                        "
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Logs:   docker compose -f /tmp/streamer-compose.yml logs -f"
echo "║  Stop:   docker compose -f /tmp/streamer-compose.yml down "
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
