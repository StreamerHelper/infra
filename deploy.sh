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
CONFIG_DIR="${STREAMER_HELPER_CONFIG_DIR:-$HOME/.streamer-helper}"
CONFIG_FILE="$CONFIG_DIR/settings.json"
OLD_CONFIG_FILE="$CONFIG_DIR/config.json"  # Legacy config file name
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

if ! command -v jq &> /dev/null; then
    log_error "jq is required to read/write settings.json. Install it: apt install jq / brew install jq"
    exit 1
fi

# Create config directory
log_step "Creating directory: $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"

# Migrate old config file if exists
if [ -f "$OLD_CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
    log_step "Migrating old config.json to settings.json..."
    mv "$OLD_CONFIG_FILE" "$CONFIG_FILE"
    log_info "Migration complete. Your settings are now in $CONFIG_FILE"
fi

# Generate config if not exists (standard JSON, editable and tool-friendly)
if [ ! -f "$CONFIG_FILE" ]; then
    log_step "Generating configuration..."

    if [ -z "${APP_KEYS:-}" ]; then
        APP_KEYS=$(generate_secret)
        log_warn "APP_KEYS generated. Save this for future use: $APP_KEYS"
    fi
    DB_PASSWORD="${TYPEORM_PASSWORD:-$(generate_secret | head -c 16)}"
    MINIO_PASSWORD="${S3_SECRET_KEY:-$(generate_secret | head -c 16)}"

    jq -n \
        --arg app_keys "$APP_KEYS" \
        --arg db_password "$DB_PASSWORD" \
        --arg s3_secret "$MINIO_PASSWORD" \
        '{
          app: { port: 7001, keys: $app_keys, nodeEnv: "production" },
          database: { host: "postgres", port: 5432, username: "postgres", password: $db_password, database: "streamerhelper", ssl: false },
          redis: { host: "redis", port: 6379, password: "", db: 0 },
          s3: { endpoint: "http://minio:9000", region: "us-east-1", accessKey: "minioadmin", secretKey: $s3_secret, bucket: "streamerhelper-archive" },
          recorder: { segmentDuration: 10, cacheMaxSegments: 3, heartbeatInterval: 5, heartbeatTimeout: 10, maxRecordingTime: 86400 },
          poller: { checkInterval: 60, totalInstances: 1, concurrency: 5 },
          upload: { defaultTid: 171, defaultTitleTemplate: "{streamerName}的直播录像 {date}" }
        }' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log_info "Configuration saved to $CONFIG_FILE"
else
    log_info "Using existing configuration: $CONFIG_FILE"
fi

# Create docker-compose env file (values from settings.json via jq)
DOCKER_ENV="$CONFIG_DIR/.docker-env"

APP_KEYS_VALUE=$(jq -r '.app.keys // empty' "$CONFIG_FILE")
TYPEORM_PASSWORD_VALUE=$(jq -r '.database.password // empty' "$CONFIG_FILE")
S3_SECRET_KEY_VALUE=$(jq -r '.s3.secretKey // empty' "$CONFIG_FILE")
S3_ACCESS_KEY_VALUE=$(jq -r '.s3.accessKey // empty' "$CONFIG_FILE")
S3_BUCKET_VALUE=$(jq -r '.s3.bucket // empty' "$CONFIG_FILE")
S3_REGION_VALUE=$(jq -r '.s3.region // empty' "$CONFIG_FILE")

if [ -z "$APP_KEYS_VALUE" ] || [ -z "$TYPEORM_PASSWORD_VALUE" ] || [ -z "$S3_SECRET_KEY_VALUE" ]; then
    log_error "Invalid or incomplete $CONFIG_FILE (missing app.keys, database.password, or s3.secretKey)"
    exit 1
fi

# Escape single quotes for use in KEY='value' env file
shell_quote() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# Check if postgres data volume exists with old password
POSTgres_volume="streamer-postgres"
if docker volume inspect "$postgres_volume" --format '{{.Mountpoint}}' 2>/dev/null | grep -q "exists"; then
    # Get current password from postgres container env
    current_env=$(docker exec "$postgres_volume" env 2>/dev/null | grep -i "POSTGRES_PASSWORD" || true)
    if [ -n "$current_env" ]; then
        # Check if password matches
        if ! echo "$current_env" | grep -q "$TYPEORM_PASSWORD_VALUE" > /dev/null; then
            log_error "Password mismatch detected!"
            log_error "Postgres was initialized with a different password than in $CONFIG_FILE"
            log_error ""
            log_error "To fix this issue, you have two options:"
            log_error "  1. Update $CONFIG_FILE with the original password, OR"
            log_error "  2. Reset everything: docker compose -f $DATA_DIR/docker-compose.yml down -v && rm -rf $DATA_DIR"
            log_error "     Then run this deploy script again"
            log_error ""
            log_error "WARNING: Option 2 will DELETE ALL DATA"
            exit 1
    fi
fi

{
  printf "APP_KEYS='%s'\n" "$(shell_quote "$APP_KEYS_VALUE")"
  printf "TYPEORM_PASSWORD='%s'\n" "$(shell_quote "$TYPEORM_PASSWORD_VALUE")"
  printf "S3_SECRET_KEY='%s'\n" "$(shell_quote "$S3_SECRET_KEY_VALUE")"
  printf "S3_ACCESS_KEY='%s'\n" "${S3_ACCESS_KEY_VALUE:-minioadmin}"
  printf "S3_BUCKET='%s'\n" "${S3_BUCKET_VALUE:-streamerhelper-archive}"
  printf "S3_REGION='%s'\n" "${S3_REGION_VALUE:-us-east-1}"
  printf "CONFIG_DIR=%s\n" "$(shell_quote "$DATA_DIR")"
  printf "HTTP_PORT=%s\n" "${HTTP_PORT:-80}"
  printf "HTTPS_PORT=%s\n" "${HTTPS_PORT:-443}"
} > "$DOCKER_ENV"

# Download compose file
log_step "Downloading docker-compose file..."
curl -fsSL "$COMPOSE_URL" -o "$DATA_DIR/docker-compose.yml"

# 不使用 down，避免重建 Postgres 容器导致「卷内密码」与「.docker-env 密码」不一致
# 启动/重启请始终带 --env-file，保证与 settings.json 一致
log_step "Pulling images..."
docker compose -f "$DATA_DIR/docker-compose.yml" --env-file "$DOCKER_ENV" pull

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
echo "║  Application:   http://localhost:${HTTP_PORT:-80}"
echo "║  MinIO Console: http://localhost:9001"
echo "║  Config:        $CONFIG_FILE"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Commands:"
echo "║  • Start:   docker compose -f $DATA_DIR/docker-compose.yml --env-file $DOCKER_ENV up -d"
echo "║  • Logs:    docker compose -f $DATA_DIR/docker-compose.yml logs -f"
echo "║  • Stop:    docker compose -f $DATA_DIR/docker-compose.yml down"
echo "║  • Restart: docker compose -f $DATA_DIR/docker-compose.yml --env-file $DOCKER_ENV restart"
echo "║"
echo "║  Note: Do not change database.password after first run"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
