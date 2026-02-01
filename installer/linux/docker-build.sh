#!/bin/bash
# SecureGuard Linux Package Builder using Docker
# Builds .deb and .rpm packages for ARM64 (and optionally x86_64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

VERSION="${1:-1.0.0}"
PLATFORM="${2:-linux/arm64}"  # Default to ARM64 for Apple Silicon

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo ""
echo "=============================================================="
echo "     SecureGuard Linux Package Builder (Docker)              "
echo "=============================================================="
echo ""
echo "Version: $VERSION"
echo "Platform: $PLATFORM"
echo ""

# Check Docker
if ! docker info &>/dev/null; then
    echo "Error: Docker is not running"
    exit 1
fi

log_step "Building Linux packages in Docker container..."

# Build using Docker
docker build \
    --platform "$PLATFORM" \
    --build-arg VERSION="$VERSION" \
    -f "$SCRIPT_DIR/Dockerfile.build" \
    -t secureguard-linux-builder \
    "$PROJECT_ROOT"

# Extract packages from the image
log_step "Extracting packages..."

mkdir -p "$SCRIPT_DIR/build"

# Create a temporary container and copy files out
CONTAINER_ID=$(docker create --platform "$PLATFORM" secureguard-linux-builder)
docker cp "$CONTAINER_ID:/build/installer/linux/build/." "$SCRIPT_DIR/build/" 2>/dev/null || true
docker rm "$CONTAINER_ID"

log_info "Packages available in: $SCRIPT_DIR/build/"
ls -la "$SCRIPT_DIR/build/"

echo ""
echo "=============================================================="
echo "                    Build Complete!                           "
echo "=============================================================="
echo ""
echo "To test installation in a Docker container:"
echo "  ./docker-test.sh"
echo ""
