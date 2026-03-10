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
NO_CACHE=""

# Parse options
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        -h|--help)
            echo "Usage: ./build-and-push.sh [version] [options]"
            echo ""
            echo "Arguments:"
            echo "  version    Image tag (default: latest)"
            echo ""
            echo "Options:"
            echo "  --no-cache    Build without cache"
            echo "  -h, --help    Show this help"
            echo ""
            echo "Environment variables:"
            echo "  DOCKER_REGISTRY   Docker registry (default: docker.io)"
            echo "  DOCKER_ORG        Docker org/username (default: umuoy1)"
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

# Check directories
BACKEND_DIR="../StreamerHelper"
FRONTEND_DIR="../StreamerHelper-FE"

if [ ! -d "$BACKEND_DIR" ]; then
    log_error "Backend directory not found: $BACKEND_DIR"
    exit 1
fi

if [ ! -d "$FRONTEND_DIR" ]; then
    log_error "Frontend directory not found: $FRONTEND_DIR"
    exit 1
fi

# Check docker login
log_info "Checking Docker login status..."
if ! docker pull busybox:latest >/dev/null 2>&1; then
    log_warn "Not logged in to Docker registry"
    log_info "Running docker login..."
    docker login $REGISTRY
fi

# Banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         StreamerHelper Build & Push                       ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Version:  $VERSION"
echo "║  Registry: $REGISTRY/$ORG"
echo "║  No Cache: ${NO_CACHE:-false}"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Build and push function
build_and_push() {
    local name=$1
    local dockerfile=$2
    local context=$3

    log_build "Building $name..."
    docker build $NO_CACHE -f "$dockerfile" -t "$REGISTRY/$ORG/$name:$VERSION" "$context"
    docker tag "$REGISTRY/$ORG/$name:$VERSION" "$REGISTRY/$ORG/$name:latest"

    log_info "Pushing $name:$VERSION..."
    docker push "$REGISTRY/$ORG/$name:$VERSION"
    docker push "$REGISTRY/$ORG/$name:latest"

    echo ""
}

# Build all images
build_and_push "backend" "Dockerfile.backend" "$BACKEND_DIR"
build_and_push "frontend" "Dockerfile.frontend" "$FRONTEND_DIR"
build_and_push "nginx" "Dockerfile.nginx" "."

# Done
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Build Complete!                        ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Images pushed:                                           ║"
echo "║    - $REGISTRY/$ORG/backend:$VERSION                       "
echo "║    - $REGISTRY/$ORG/frontend:$VERSION                      "
echo "║    - $REGISTRY/$ORG/nginx:$VERSION                         "
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
