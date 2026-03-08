#!/bin/bash

# StreamerHelper Quick Deploy Script
# Usage: curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash

set -e

COMPOSE_URL="https://raw.githubusercontent.com/StreamerHelper/infra/main/docker-compose.prod.yml"
COMPOSE_FILE="docker-compose.streamer.yml"

echo "=== StreamerHelper Quick Deploy ==="
echo ""

# Download compose file
echo ">>> Downloading docker-compose file..."
curl -fsSL $COMPOSE_URL -o $COMPOSE_FILE

# Check if .env exists, create from template if not
if [ ! -f ".env.streamer" ]; then
    echo ">>> Creating .env.streamer file..."
    cat > .env.streamer << EOF
# Required: Change this to a secure random string
APP_KEYS=change-me-to-secure-random-string

# Database (optional, defaults provided)
TYPEORM_USERNAME=postgres
TYPEORM_PASSWORD=postgres
TYPEORM_DATABASE=livestream

# Redis (optional)
REDIS_PASSWORD=

# MinIO / S3 (optional, defaults provided)
S3_ACCESS_KEY=minioadmin
S3_SECRET_KEY=minioadmin
S3_BUCKET=livestream-archive

# Ports (optional)
HTTP_PORT=80
HTTPS_PORT=443
EOF
    echo ""
    echo "!!! Please edit .env.streamer and set APP_KEYS to a secure value !!!"
    echo ""
    read -p "Press Enter after you've configured .env.streamer..."
fi

# Start services
echo ">>> Starting services..."
docker compose -f $COMPOSE_FILE --env-file .env.streamer up -d

echo ""
echo "=== Deploy Complete ==="
echo ""
echo "Services:"
echo "  - Frontend:    http://localhost"
echo "  - Backend API: http://localhost:7001 (via nginx)"
echo "  - MinIO:       http://localhost:9001"
echo ""
echo "Logs: docker compose -f $COMPOSE_FILE logs -f"
echo "Stop: docker compose -f $COMPOSE_FILE down"
