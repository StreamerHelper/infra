#!/bin/bash

# StreamerHelper Docker Images Build & Push Script
# Usage: ./build-and-push.sh [version]

set -e

VERSION=${1:-latest}
REGISTRY=${DOCKER_REGISTRY:-docker.io}
ORG=umuoy1

echo "=== Building and pushing images with tag: $VERSION ==="
echo "Registry: $REGISTRY/$ORG"
echo ""

# Backend
echo ">>> Building backend..."
docker build -f Dockerfile.backend -t $REGISTRY/$ORG/backend:$VERSION ../StreamerHelper
docker tag $REGISTRY/$ORG/backend:$VERSION $REGISTRY/$ORG/backend:latest
echo ">>> Pushing backend..."
docker push $REGISTRY/$ORG/backend:$VERSION
docker push $REGISTRY/$ORG/backend:latest

# Frontend
echo ">>> Building frontend..."
docker build -f Dockerfile.frontend -t $REGISTRY/$ORG/frontend:$VERSION ../StreamerHelper-FE
docker tag $REGISTRY/$ORG/frontend:$VERSION $REGISTRY/$ORG/frontend:latest
echo ">>> Pushing frontend..."
docker push $REGISTRY/$ORG/frontend:$VERSION
docker push $REGISTRY/$ORG/frontend:latest

# Nginx
echo ">>> Building nginx..."
docker build -f Dockerfile.nginx -t $REGISTRY/$ORG/nginx:$VERSION .
docker tag $REGISTRY/$ORG/nginx:$VERSION $REGISTRY/$ORG/nginx:latest
echo ">>> Pushing nginx..."
docker push $REGISTRY/$ORG/nginx:$VERSION
docker push $REGISTRY/$ORG/nginx:latest

echo ""
echo "=== Done! ==="
echo "Images pushed:"
echo "  - $REGISTRY/$ORG/backend:$VERSION"
echo "  - $REGISTRY/$ORG/frontend:$VERSION"
echo "  - $REGISTRY/$ORG/nginx:$VERSION"
