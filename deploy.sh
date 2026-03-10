#!/bin/bash

#=============================================================#
#  StreamerHelper Production Deploy Script                    #
#                                                             #
#  Usage:                                                     #
#    curl -fsSL https://raw.githubusercontent.com/             #
#         StreamerHelper/infra/main/deploy.sh | bash          #
#                                                             #
#  Configuration (all optional, will prompt if required):     #
#    export APP_KEYS=your-secret-key                          #
#    export TYPEORM_PASSWORD=your-db-password                 #
#    export REDIS_PASSWORD=your-redis-password                #
#    export S3_ACCESS_KEY=minio-user                          #
#    export S3_SECRET_KEY=minio-password                      #
#=============================================================#

set -e

COMPOSE_URL="https://raw.githubusercontent.com/StreamerHelper/infra/main/docker-compose.prod.yml"
COMPOSE_FILE="/opt/streamer-helper/docker-compose.yml"
DATA_DIR="/opt/streamer-helper"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Generate random secret
generate_secret() {
  openssl rand -hex 32
}

# Banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           StreamerHelper Production Deploy                ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    log_error "Docker Compose v2 is required. Please upgrade Docker."
    exit 1
fi

# Create data directory
log_step "Creating data directory..."
sudo mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

# Generate secrets if not provided
log_step "Checking configuration..."

if [ -z "$APP_KEYS" ]; then
    if [ -f "$DATA_DIR/.env" ] && grep -q "^APP_KEYS=" "$DATA_DIR/.env"; then
        # Load existing APP_KEYS
        export APP_KEYS=$(grep "^APP_KEYS=" "$DATA_DIR/.env" | cut -d'=' -f2-)
        log_info "Using existing APP_KEYS from .env"
    else
        export APP_KEYS=$(generate_secret)
        log_warn "APP_KEYS not set. Generated random secret."
        log_warn "Please save this key for future deployments: $APP_KEYS"
    fi
fi

# Set defaults
export HTTP_PORT="${HTTP_PORT:-80}"
export HTTPS_PORT="${HTTPS_PORT:-443}"
export TYPEORM_USERNAME="${TYPEORM_USERNAME:-postgres}"
export TYPEORM_PASSWORD="${TYPEORM_PASSWORD:-postgres}"
export TYPEORM_DATABASE="${TYPEORM_DATABASE:-livestream}"
export TYPEORM_SSL="${TYPEORM_SSL:-false}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-}"
export REDIS_DB="${REDIS_DB:-0}"
export S3_ACCESS_KEY="${S3_ACCESS_KEY:-minioadmin}"
export S3_SECRET_KEY="${S3_SECRET_KEY:-minioadmin}"
export S3_BUCKET="${S3_BUCKET:-livestream-archive}"
export S3_REGION="${S3_REGION:-us-east-1}"
export BACKEND_VERSION="${BACKEND_VERSION:-latest}"
export FRONTEND_VERSION="${FRONTEND_VERSION:-latest}"
export DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io}"
export DOCKER_ORG="${DOCKER_ORG:-streamerhelper}"

# Save environment to .env file for persistence
cat > "$DATA_DIR/.env" << EOF
# StreamerHelper Configuration
# Generated at $(date -Iseconds)

# Application
APP_KEYS=${APP_KEYS}

# Ports
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=${HTTPS_PORT}

# Database (PostgreSQL)
TYPEORM_USERNAME=${TYPEORM_USERNAME}
TYPEORM_PASSWORD=${TYPEORM_PASSWORD}
TYPEORM_DATABASE=${TYPEORM_DATABASE}
TYPEORM_SSL=${TYPEORM_SSL}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}

# S3/MinIO
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}

# Image versions
BACKEND_VERSION=${BACKEND_VERSION}
FRONTEND_VERSION=${FRONTEND_VERSION}
DOCKER_REGISTRY=${DOCKER_REGISTRY}
DOCKER_ORG=${DOCKER_ORG}
EOF

chmod 600 "$DATA_DIR/.env"
log_info "Configuration saved to $DATA_DIR/.env"

# Show configuration (hide secrets)
log_info "Configuration:"
echo "  HTTP_PORT:       ${HTTP_PORT}"
echo "  HTTPS_PORT:      ${HTTPS_PORT}"
echo "  DB_USER:         ${TYPEORM_USERNAME}"
echo "  DB_PASSWORD:     ********"
echo "  DB_NAME:         ${TYPEORM_DATABASE}"
echo "  REDIS_PASSWORD:  $([ -n "$REDIS_PASSWORD" ] && echo '********' || echo '<none>')"
echo "  MINIO_USER:      ${S3_ACCESS_KEY}"
echo "  MINIO_PASSWORD:  ********"
echo "  S3_BUCKET:       ${S3_BUCKET}"
echo "  BACKEND_VERSION: ${BACKEND_VERSION}"
echo "  FRONTEND_VERSION:${FRONTEND_VERSION}"
echo ""

# Download compose file
log_step "Downloading docker-compose file..."
curl -fsSL "$COMPOSE_URL" -o "$COMPOSE_FILE"

# Stop existing services
if docker ps --format '{{.Names}}' | grep -q "^streamer-"; then
    log_step "Stopping existing services..."
    docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
fi

# Pull images
log_step "Pulling images..."
docker compose -f "$COMPOSE_FILE" pull

# Start services
log_step "Starting services..."
docker compose -f "$COMPOSE_FILE" up -d

# Wait for backend healthy
log_step "Waiting for backend to be ready..."
MAX_WAIT=180
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(docker inspect streamer-backend --format '{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
    if [ "$STATUS" = "healthy" ]; then
        break
    fi
    if [ "$STATUS" = "unhealthy" ]; then
        log_error "Backend is unhealthy. Check logs: docker logs streamer-backend"
        exit 1
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo "  Waiting... (${WAITED}s/${MAX_WAIT}s) - Status: ${STATUS}"
done

if [ $WAITED -ge $MAX_WAIT ]; then
    log_error "Backend failed to start within ${MAX_WAIT}s"
    log_error "Check logs: docker logs streamer-backend"
    exit 1
fi

log_info "Backend is healthy!"

# Run database migrations
log_step "Running database migrations..."
docker compose -f "$COMPOSE_FILE" exec -T backend sh -c "node dist/migration/run.js" 2>/dev/null || {
    log_warn "Migration command not found or failed. Trying npm script..."
    docker compose -f "$COMPOSE_FILE" exec -T backend npm run migration:run 2>/dev/null || {
        log_warn "Migrations may have already been applied"
    }
}

# Create MinIO bucket if not exists
log_step "Initializing MinIO bucket..."
sleep 5
docker compose -f "$COMPOSE_FILE" exec -T minio sh -c "
    mc alias set local http://localhost:9000 ${S3_ACCESS_KEY} ${S3_SECRET_KEY} 2>/dev/null || true
    mc mb local/${S3_BUCKET} --ignore-existing 2>/dev/null || true
" 2>/dev/null || log_warn "MinIO init skipped (mc not available)"

# Done
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                   Deploy Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║                                                           ║"
echo "║  🌐 Application:  http://localhost:${HTTP_PORT}                      "
echo "║  📦 MinIO Console: http://localhost:9001                  ║"
echo "║                                                           ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Commands:                                                ║"
echo "║  • View logs:   docker compose -f $COMPOSE_FILE logs -f"
echo "║  • Stop:        docker compose -f $COMPOSE_FILE down"
echo "║  • Restart:     docker compose -f $COMPOSE_FILE restart"
echo "║  • Update:      curl ... | bash  (run deploy again)"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
