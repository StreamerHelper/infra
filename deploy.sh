#!/bin/bash

# StreamerHelper Quick Deploy Script
# Usage: curl -fsSL https://raw.githubusercontent.com/StreamerHelper/infra/main/deploy.sh | bash

set -e

COMPOSE_URL="https://raw.githubusercontent.com/StreamerHelper/infra/main/docker-compose.prod.yml"
COMPOSE_FILE="docker-compose.streamer.yml"
ENV_FILE=".env.streamer"

echo "=== StreamerHelper Quick Deploy ==="
echo ""

# Download compose file
echo ">>> Downloading docker-compose file..."
curl -fsSL $COMPOSE_URL -o $COMPOSE_FILE

# Create env file if not exists
if [ ! -f "$ENV_FILE" ]; then
    echo ""
    echo ">>> Configuration"
    echo ""

    # Prompt for APP_KEYS
    echo "Enter APP_KEYS (a secret string for session encryption)."
    echo "Press Enter to use default (not recommended for production):"
    read -p "APP_KEYS: " APP_KEYS_INPUT

    # Use default if empty
    if [ -z "$APP_KEYS_INPUT" ]; then
        APP_KEYS_INPUT="streamer-helper-default-secret-key-please-change-in-production"
        echo "Using default APP_KEYS"
    fi

    echo ""
    echo ">>> Creating environment file..."
    cat > $ENV_FILE << EOF
# Generated at $(date)
APP_KEYS=$APP_KEYS_INPUT

# Ports
HTTP_PORT=80
HTTPS_PORT=443
EOF
fi

# Start services
echo ">>> Starting services..."
docker compose -f $COMPOSE_FILE --env-file $ENV_FILE up -d

echo ""
echo "=== Deploy Complete ==="
echo ""
echo "Services:"
echo "  - Frontend:    http://localhost"
echo "  - MinIO:       http://localhost:9001"
echo ""
echo "Commands:"
echo "  Logs:  docker compose -f $COMPOSE_FILE logs -f"
echo "  Stop:  docker compose -f $COMPOSE_FILE down"
