#!/bin/bash

#=============================================================#
#  StreamerHelper Docker Images Build & Push Script           #
#  Usage: ./build-and-push.sh [version] [options]             #
#                                                             #
#  Examples:                                                  #
#    ./build-and-push.sh v0.0.2                               #
#    ./build-and-push.sh v0.0.2 --no-cache                    #
#    ./build-and-push.sh latest                               #
#=============================================================#

set -e

# Configuration
VERSION=${1:-latest}
REGISTRY=${DOCKER_REGISTRY:-docker.io}
ORG=${DOCKER_ORG:-umuoy1}
IMAGE_PREFIX=${IMAGE_PREFIX:-streamerhelper}
NO_CACHE=""

# Script directory (for relative paths)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Parse options
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --skip-push)
            SKIP_PUSH=1
            shift
            ;;
        -h|--help)
            echo "Usage: ./build-and-push.sh [version] [options]"
            echo ""
            echo "Arguments:"
            echo "  version    Image tag (default: latest)"
            echo ""
            echo "Options:"
            echo "  --no-cache      Build without cache"
            echo "  --skip-push     Build only, skip pushing to registry"
            echo "  -h, --help      Show this help"
            echo ""
            echo "Environment variables:"
            echo "  DOCKER_REGISTRY   Docker registry (default: docker.io)"
            echo "  DOCKER_ORG        Docker org/username (default: streamerhelper)"
            echo "  IMAGE_PREFIX      Image name prefix (default: streamerhelper)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_build() { echo -e "${BLUE}[BUILD]${NC} $1"; }

# Check directories - use actual project structure
BACKEND_DIR="$ROOT_DIR/web-server"
FRONTEND_DIR="$ROOT_DIR/web"

if [ ! -d "$BACKEND_DIR" ]; then
    log_error "Backend directory not found: $BACKEND_DIR"
    log_error "Expected structure: infra/ (this script), web-server/ (backend), web/ (frontend)"
    exit 1
fi

if [ ! -d "$FRONTEND_DIR" ]; then
    log_error "Frontend directory not found: $FRONTEND_DIR"
    log_error "Expected structure: infra/ (this script), web-server/ (backend), web/ (frontend)"
    exit 1
fi

# Verify required files exist
if [ ! -f "$BACKEND_DIR/docker-entrypoint.sh" ]; then
    log_error "Missing: $BACKEND_DIR/docker-entrypoint.sh"
    exit 1
fi

if [ ! -f "$BACKEND_DIR/bootstrap.js" ]; then
    log_error "Missing: $BACKEND_DIR/bootstrap.js"
    exit 1
fi

if [ ! -f "$FRONTEND_DIR/package.json" ]; then
    log_error "Missing: $FRONTEND_DIR/package.json"
    exit 1
fi

# Check docker login (skip if --skip-push)
if [ -z "${SKIP_PUSH:-}" ]; then
    log_info "Checking Docker login status..."
    if ! docker pull busybox:latest >/dev/null 2>&1; then
        log_warn "Not logged in to Docker registry"
        log_info "Running docker login..."
        docker login $REGISTRY
    fi
fi

# Banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         StreamerHelper Build & Push                       ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Version:  $VERSION"
echo "║  Registry: $REGISTRY/$ORG"
echo "║  No Cache: ${NO_CACHE:-false}"
echo "║  Skip Push: ${SKIP_PUSH:-false}"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Build and push function
build_and_push() {
    local name=$1
    local dockerfile=$2
    local context=$3
    local image_name="$IMAGE_PREFIX-$name"

    log_build "Building $image_name..."
    docker build $NO_CACHE -f "$dockerfile" -t "$REGISTRY/$ORG/$image_name:$VERSION" "$context"
    docker tag "$REGISTRY/$ORG/$image_name:$VERSION" "$REGISTRY/$ORG/$image_name:latest"

    if [ -z "${SKIP_PUSH:-}" ]; then
        log_info "Pushing $image_name:$VERSION..."
        docker push "$REGISTRY/$ORG/$image_name:$VERSION"
        docker push "$REGISTRY/$ORG/$image_name:latest"
    else
        log_info "Skipping push (--skip-push)"
    fi

    echo ""
}

# Build all images
# Note: Dockerfiles are in infra/, but build context is the respective app directory
build_and_push "backend" "$SCRIPT_DIR/Dockerfile.backend" "$BACKEND_DIR"
build_and_push "frontend" "$SCRIPT_DIR/Dockerfile.frontend" "$FRONTEND_DIR"
build_and_push "nginx" "$SCRIPT_DIR/Dockerfile.nginx" "$SCRIPT_DIR"

# Done
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Build Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Images built:                                            ║"
echo "║    - $REGISTRY/$ORG/$IMAGE_PREFIX-backend:$VERSION         "
echo "║    - $REGISTRY/$ORG/$IMAGE_PREFIX-frontend:$VERSION        "
echo "║    - $REGISTRY/$ORG/$IMAGE_PREFIX-nginx:$VERSION           "
if [ -z "${SKIP_PUSH:-}" ]; then
echo "║                                                           ║"
echo "║  Images pushed to registry                                ║"
fi
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
