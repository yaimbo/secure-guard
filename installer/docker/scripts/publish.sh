#!/bin/bash
# =============================================================================
# MinnowVPN Docker Images - Build and Publish to Docker Hub
# =============================================================================
#
# Usage:
#   ./publish.sh <version>                    # Build + push all (both arch)
#   ./publish.sh <version> --no-push          # Build only, don't push
#   ./publish.sh <version> --amd64-only       # x86_64 only
#   ./publish.sh <version> --arm64-only       # ARM64 only
#   ./publish.sh <version> --image=api        # Single image only
#
# Prerequisites:
#   - Docker with buildx support
#   - docker login already completed
#
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REGISTRY="${DOCKER_REGISTRY:-minnowvpn}"
IMAGES=(
    "api:Dockerfile.dart-server"
    "console:Dockerfile.flutter-console"
    "vpn:Dockerfile.vpn-daemon"
)
BUILDER_NAME="minnowvpn-builder"

# Show help
show_help() {
    echo "Usage: $0 <version> [options]"
    echo ""
    echo "Build and push MinnowVPN Docker images to Docker Hub."
    echo ""
    echo "Options:"
    echo "  --no-push       Build only, don't push to Docker Hub"
    echo "  --amd64-only    Build for x86_64 only"
    echo "  --arm64-only    Build for ARM64 only"
    echo "  --image=NAME    Build single image (api, console, or vpn)"
    echo "  -y, --yes       Skip confirmation prompts (for CI/CD)"
    echo "  --help, -h      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 1.0.0                      # Build and push all images"
    echo "  $0 1.0.0 --no-push            # Build only"
    echo "  $0 1.0.0 --image=api          # Build and push API image only"
    echo "  $0 1.0.0 -y                   # Skip prompts (CI/CD mode)"
    exit 0
}

# Check for help flag first
for arg in "$@"; do
    case "$arg" in
        --help|-h) show_help ;;
    esac
done

# Parse arguments
VERSION="${1:-}"
PUSH=true
PLATFORMS="linux/amd64,linux/arm64"
FILTER_IMAGE=""
SKIP_CONFIRM=false

for arg in "${@:2}"; do
    case "$arg" in
        --no-push)
            PUSH=false
            ;;
        --amd64-only)
            PLATFORMS="linux/amd64"
            ;;
        --arm64-only)
            PLATFORMS="linux/arm64"
            ;;
        --image=*)
            FILTER_IMAGE="${arg#--image=}"
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate version
if [[ -z "$VERSION" ]]; then
    echo -e "${RED}Error: Version is required${NC}"
    echo "Usage: $0 <version> [options]"
    echo "Use --help for more information"
    exit 1
fi

# Validate version format (semver-ish)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo -e "${YELLOW}Warning: Version '$VERSION' doesn't follow semver format (x.y.z)${NC}"
    if $SKIP_CONFIRM; then
        echo -e "${YELLOW}Continuing anyway (--yes flag set)${NC}"
    else
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# Validate filter image name
if [[ -n "$FILTER_IMAGE" ]]; then
    valid_images=("api" "console" "vpn")
    if [[ ! " ${valid_images[*]} " =~ " ${FILTER_IMAGE} " ]]; then
        echo -e "${RED}Error: Invalid image name '$FILTER_IMAGE'${NC}"
        echo "Valid options: api, console, vpn"
        exit 1
    fi
fi

# Change to repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT"

echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  MinnowVPN Docker Image Publisher${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Version:    ${GREEN}$VERSION${NC}"
echo -e "  Platforms:  ${GREEN}$PLATFORMS${NC}"
echo -e "  Push:       ${GREEN}$PUSH${NC}"
if [[ -n "$FILTER_IMAGE" ]]; then
    echo -e "  Image:      ${GREEN}$FILTER_IMAGE${NC}"
fi
echo ""

# Ensure buildx builder exists
ensure_builder() {
    echo -e "${BLUE}Checking Docker buildx...${NC}"

    if ! docker buildx version &>/dev/null; then
        echo -e "${RED}Error: Docker buildx is not available${NC}"
        echo "Please install Docker Desktop or enable buildx plugin"
        exit 1
    fi

    if ! docker buildx inspect "$BUILDER_NAME" &>/dev/null; then
        echo -e "${YELLOW}Creating buildx builder: $BUILDER_NAME${NC}"
        docker buildx create --name "$BUILDER_NAME" --driver docker-container --use
        docker buildx inspect --bootstrap
    else
        docker buildx use "$BUILDER_NAME"
    fi

    echo -e "${GREEN}Using builder: $BUILDER_NAME${NC}"
    echo ""
}

# Build and optionally push an image
build_image() {
    local name="$1"
    local dockerfile="$2"
    local full_name="$REGISTRY/$name"
    local start_time=$(date +%s)

    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Building: ${GREEN}$full_name:$VERSION${NC}"
    echo -e "${BLUE}Dockerfile: ${NC}installer/docker/$dockerfile"
    echo -e "${BLUE}Platforms: ${NC}$PLATFORMS"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""

    local build_args=(
        "--platform" "$PLATFORMS"
        "--file" "installer/docker/$dockerfile"
        "--tag" "$full_name:$VERSION"
        "--tag" "$full_name:latest"
        "--progress" "plain"
    )

    if $PUSH; then
        build_args+=("--push")
    else
        # --load only works for single platform builds
        if [[ "$PLATFORMS" == *","* ]]; then
            echo -e "${YELLOW}Note: Multi-platform builds require --push to export${NC}"
            echo -e "${YELLOW}      Images will be built but not saved locally${NC}"
            echo ""
        else
            build_args+=("--load")
        fi
    fi

    if ! docker buildx build "${build_args[@]}" .; then
        echo -e "${RED}Failed to build $full_name${NC}"
        return 1
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo ""
    echo -e "${GREEN}Built $full_name:$VERSION in ${duration}s${NC}"
    echo ""
}

# Track overall timing and results
TOTAL_START=$(date +%s)
BUILT_IMAGES=()
FAILED_IMAGES=()

# Main
ensure_builder

for entry in "${IMAGES[@]}"; do
    name="${entry%%:*}"
    dockerfile="${entry#*:}"

    # Skip if filter is set and doesn't match
    if [[ -n "$FILTER_IMAGE" && "$name" != "$FILTER_IMAGE" ]]; then
        continue
    fi

    if build_image "$name" "$dockerfile"; then
        BUILT_IMAGES+=("$name")
    else
        FAILED_IMAGES+=("$name")
    fi
done

# Summary
TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Build Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Total time: ${GREEN}${TOTAL_DURATION}s${NC}"
echo ""

if [[ ${#BUILT_IMAGES[@]} -gt 0 ]]; then
    echo -e "${GREEN}Successfully built:${NC}"
    for img in "${BUILT_IMAGES[@]}"; do
        echo -e "  - $REGISTRY/$img:$VERSION"
        if $PUSH; then
            echo -e "    ${GREEN}Pushed to Docker Hub${NC}"
        fi
    done
    echo ""
fi

if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
    echo -e "${RED}Failed to build:${NC}"
    for img in "${FAILED_IMAGES[@]}"; do
        echo -e "  - $REGISTRY/$img"
    done
    echo ""
    exit 1
fi

if $PUSH && [[ ${#BUILT_IMAGES[@]} -gt 0 ]]; then
    echo -e "${GREEN}Images available on Docker Hub:${NC}"
    for img in "${BUILT_IMAGES[@]}"; do
        echo -e "  docker pull $REGISTRY/$img:$VERSION"
    done
    echo ""
fi

echo -e "${GREEN}Done!${NC}"
