#!/bin/bash

#=============================================================#
#  StreamerHelper Production Deploy Script                    #
#                                                             #
#  Usage:                                                     #
#    curl -fsSL https://raw.githubusercontent.com/             #
#         StreamerHelper/infra/main/deploy.sh | bash          #
#=============================================================#

set -e

COMPOSE_URL="https://raw.githubusercontent.com/StreamerHelper/infra/main/docker-compose.prod.yml"
CONFIG_DIR="$HOME/.streamer-helper"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
DATA_DIR="$CONFIG_DIR"

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

# Create config directory
log_step "Creating directory: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# Generate config if not exists
if [ ! -f "$CONFIG_FILE" ]; then
    log_step "Generating configuration..."

    # Prompt for secrets or generate
    if [ -z "$APP_KEYS" ]; then
        APP_KEYS=$(generate_secret)
        log_warn "APP_KEYS generated. Save this for future use: $APP_KEYS"
    fi

    DB_PASSWORD="${TYPEORM_PASSWORD:-$(generate_secret | head -c 16)}"
    MINIO_PASSWORD="${S3_SECRET_KEY:-$(generate_secret | head -c 16)}"

    cat > "$CONFIG_FILE" << EOF
# StreamerHelper Configuration
# Generated at $(date -Iseconds)

app:
  port: 7001
  keys: "${APP_KEYS}"
  nodeEnv: production

database:
  host: postgres
  port: 5432
  username: postgres
  password: "${DB_PASSWORD}"
  database: streamerhelper
  ssl: false

redis:
  host: redis
  port: 6379
  password: ""
  db: 0

s3:
  endpoint: http://minio:9000
  region: us-east-1
  accessKey: minioadmin
  secretKey: "${MINIO_PASSWORD}"
  bucket: streamerhelper-archive

recorder:
  segmentDuration: 10
  cacheMaxSegments: 3
  heartbeatInterval: 5
  heartbeatTimeout: 10
  maxRecordingTime: 86400

poller:
  checkInterval: 60
  totalInstances: 1
  concurrency: 5

upload:
  defaultTid: 171
  defaultTitleTemplate: "{streamerName}的直播录像 {date}"
EOF

    chmod 600 "$CONFIG_FILE"
    log_info "Configuration saved to $CONFIG_FILE"
else
    log_info "Using existing configuration: $CONFIG_FILE"
fi

# Create docker-compose env file (used by docker-compose.yml)
DOCKER_ENV="$CONFIG_DIR/.docker-env"

# 从配置文件中提取需要的值，保持 docker-compose 与 config.yaml 一致
APP_KEYS_VALUE=$(grep -o 'keys: *\"[^\"]*\"' "$CONFIG_FILE" | head -1 | cut -d'\"' -f2)
DB_PASSWORD_VALUE=$(grep -o 'password: *\"[^\"]*\"' "$CONFIG_FILE" | head -1 | cut -d'\"' -f2)
MINIO_PASSWORD_VALUE=$(grep -o 'secretKey: *\"[^\"]*\"' "$CONFIG_FILE" | head -1 | cut -d'\"' -f2)

cat > "$DOCKER_ENV" << EOF
APP_KEYS=$APP_KEYS_VALUE
TYPEORM_PASSWORD=$DB_PASSWORD_VALUE
S3_SECRET_KEY=$MINIO_PASSWORD_VALUE
CONFIG_DIR=$DATA_DIR
HTTP_PORT=${HTTP_PORT:-80}
HTTPS_PORT=${HTTPS_PORT:-443}
EOF

# Download compose file
log_step "Downloading docker-compose file..."
curl -fsSL "$COMPOSE_URL" -o "$DATA_DIR/docker-compose.yml"

# Stop existing services
if docker ps --format '{{.Names}}' | grep -q "^streamer-"; then
    log_step "Stopping existing services..."
    docker compose -f "$DATA_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null || true
fi

# Pull images
log_step "Pulling images..."
docker compose -f "$DATA_DIR/docker-compose.yml" --env-file "$DOCKER_ENV" pull

# Start services
log_step "Starting services..."
docker compose -f "$DATA_DIR/docker-compose.yml" --env-file "$DOCKER_ENV" up -d

# Wait for backend healthy
log_step "Waiting for backend to be ready..."
MAX_WAIT=180
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(docker inspect streamer-backend --format '{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
    if [ "$STATUS" = "healthy" ]; then
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    echo "  Waiting... (${WAITED}s/${MAX_WAIT}s)"
done

if [ $WAITED -ge $MAX_WAIT ]; then
    log_error "Backend failed to start"
    docker logs streamer-backend --tail 50
    exit 1
fi

log_info "Backend is healthy!"

# Done
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                   Deploy Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  🌐 Application:   http://localhost:${HTTP_PORT:-80}                    "
echo "║  📦 MinIO Console: http://localhost:9001                  ║"
echo "║  📁 Config:        $CONFIG_DIR       "
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Commands:                                                ║"
echo "║  • View logs:   docker compose -f $DATA_DIR/docker-compose.yml logs -f"
echo "║  • Stop:        docker compose -f $DATA_DIR/docker-compose.yml down"
echo "║  • Edit config: vim $CONFIG_FILE && docker compose restart backend"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
