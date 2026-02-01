#!/bin/bash
# SecureGuard VPN - Linux Package Builder
# Builds both Rust daemon and Flutter client, then creates .deb and/or .rpm packages
# Automatically uses Docker when not running on Linux

set -euo pipefail

# Get script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$SCRIPT_DIR/build"
FLUTTER_PROJECT="$PROJECT_ROOT/secureguard_client"

# Version (can be overridden via argument)
VERSION="${1:-1.0.0}"

# Default options
TARGET_ARCH=""
TARGET_FORMAT=""
USE_DOCKER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

print_banner() {
    echo ""
    echo "=============================================================="
    echo "          SecureGuard VPN - Linux Package Builder            "
    echo "                      Version: $VERSION                       "
    echo "=============================================================="
    echo ""
}

print_usage() {
    echo "Usage: $0 [VERSION] [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --arch=ARCH      Target architecture (x86_64, aarch64, or native)"
    echo "  --format=FORMAT  Package format (deb, rpm, or all)"
    echo "  --docker         Force Docker build (auto-detected on non-Linux)"
    echo "  --no-docker      Force native build (fails on non-Linux)"
    echo "  --help           Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 1.0.0                           # Build native arch, both formats"
    echo "  $0 1.0.0 --arch=aarch64            # Build ARM64"
    echo "  $0 1.0.0 --format=deb              # Build .deb only"
    echo "  $0 1.0.0 --docker                  # Force Docker build"
    echo ""
}

# Parse arguments
parse_args() {
    for arg in "$@"; do
        case $arg in
            --arch=*)
                TARGET_ARCH="${arg#*=}"
                ;;
            --format=*)
                TARGET_FORMAT="${arg#*=}"
                ;;
            --docker)
                USE_DOCKER="true"
                ;;
            --no-docker)
                USE_DOCKER="false"
                ;;
            --help)
                print_usage
                exit 0
                ;;
            [0-9]*)
                VERSION="$arg"
                ;;
        esac
    done

    # Auto-detect Docker requirement
    if [ -z "$USE_DOCKER" ]; then
        if [ "$(uname -s)" != "Linux" ]; then
            USE_DOCKER="true"
            log_info "Non-Linux platform detected, using Docker build"
        else
            USE_DOCKER="false"
        fi
    fi

    # Default to native/host architecture
    if [ -z "$TARGET_ARCH" ]; then
        local host_arch
        host_arch=$(uname -m)
        case "$host_arch" in
            x86_64|amd64) TARGET_ARCH="x86_64" ;;
            aarch64|arm64) TARGET_ARCH="aarch64" ;;
            *) TARGET_ARCH="$host_arch" ;;
        esac
    fi

    # Default to all formats
    if [ -z "$TARGET_FORMAT" ]; then
        TARGET_FORMAT="all"
    fi
}

# ============================================================================
# Docker Build Mode
# ============================================================================

docker_build() {
    log_step "Building Linux packages using Docker..."

    # Check Docker is available
    if ! docker info &>/dev/null; then
        log_error "Docker is not running. Please start Docker Desktop."
        exit 1
    fi

    # Determine Docker platform
    local docker_platform="linux/amd64"
    if [ "$TARGET_ARCH" = "aarch64" ]; then
        docker_platform="linux/arm64"
    fi

    log_info "Docker platform: $docker_platform"
    log_info "Target architecture: $TARGET_ARCH"
    log_info "Package format: $TARGET_FORMAT"

    # Build the Docker image with packages
    log_step "Building Docker image (this may take a while on first run)..."

    docker build \
        --platform "$docker_platform" \
        --build-arg VERSION="$VERSION" \
        --build-arg TARGET_FORMAT="$TARGET_FORMAT" \
        -f "$SCRIPT_DIR/Dockerfile.build" \
        -t secureguard-linux-builder:latest \
        "$PROJECT_ROOT"

    # Extract packages from the built image
    log_step "Extracting packages from Docker image..."

    mkdir -p "$BUILD_DIR"

    # Create temporary container and copy build artifacts
    local container_id
    container_id=$(docker create --platform "$docker_platform" secureguard-linux-builder:latest)

    # Copy packages
    docker cp "$container_id:/build/installer/linux/build/." "$BUILD_DIR/" 2>/dev/null || {
        log_warn "No packages found in expected location, checking alternatives..."
        docker cp "$container_id:/packages/." "$BUILD_DIR/" 2>/dev/null || true
    }

    docker rm "$container_id" > /dev/null

    # List what we got
    local found_packages=0
    if ls "$BUILD_DIR"/*.deb 2>/dev/null; then
        found_packages=1
    fi
    if ls "$BUILD_DIR"/*.rpm 2>/dev/null; then
        found_packages=1
    fi

    if [ "$found_packages" -eq 1 ]; then
        log_info "Packages extracted to: $BUILD_DIR/"
    else
        log_error "No packages were created"
        exit 1
    fi
}

# ============================================================================
# Native Build Mode (Linux only)
# ============================================================================

check_prerequisites() {
    log_step "Checking prerequisites..."

    local missing=()

    command -v cargo &>/dev/null || missing+=("cargo (Rust)")
    command -v flutter &>/dev/null || missing+=("flutter")

    # Check format-specific tools
    if [ "$TARGET_FORMAT" = "deb" ] || [ "$TARGET_FORMAT" = "all" ]; then
        command -v dpkg-deb &>/dev/null || missing+=("dpkg-deb (for .deb packages)")
    fi

    if [ "$TARGET_FORMAT" = "rpm" ] || [ "$TARGET_FORMAT" = "all" ]; then
        command -v rpmbuild &>/dev/null || missing+=("rpmbuild (for .rpm packages)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools:"
        for tool in "${missing[@]}"; do
            echo "  - $tool"
        done
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

clean_build() {
    log_step "Cleaning build directory..."

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    log_info "Build directory cleaned"
}

build_rust_binary() {
    log_step "Building Rust daemon for $TARGET_ARCH..."

    cd "$PROJECT_ROOT"

    local rust_target=""
    case "$TARGET_ARCH" in
        x86_64)
            rust_target="x86_64-unknown-linux-gnu"
            ;;
        aarch64)
            rust_target="aarch64-unknown-linux-gnu"
            ;;
    esac

    # Check if we're building for native or cross-compiling
    local native_arch
    native_arch=$(uname -m)
    case "$native_arch" in
        x86_64|amd64) native_arch="x86_64" ;;
        aarch64|arm64) native_arch="aarch64" ;;
    esac

    if [ "$TARGET_ARCH" = "$native_arch" ]; then
        log_info "Building native binary..."
        cargo build --release
        cp "$PROJECT_ROOT/target/release/secureguard-poc" "$BUILD_DIR/secureguard-service"
    else
        log_info "Cross-compiling for $rust_target..."

        if ! rustup target list --installed | grep -q "$rust_target"; then
            log_warn "Target $rust_target not installed. Installing..."
            rustup target add "$rust_target"
        fi

        cargo build --release --target "$rust_target"
        cp "$PROJECT_ROOT/target/$rust_target/release/secureguard-poc" "$BUILD_DIR/secureguard-service"
    fi

    file "$BUILD_DIR/secureguard-service"
    log_info "Rust daemon built successfully"
}

build_flutter_app() {
    log_step "Building Flutter Linux app..."

    cd "$FLUTTER_PROJECT"

    flutter pub get
    flutter build linux --release

    cp -r "$FLUTTER_PROJECT/build/linux/x64/release/bundle" "$BUILD_DIR/flutter-bundle"

    log_info "Flutter app built successfully"
}

create_deb_package() {
    log_step "Creating .deb package..."

    if [ ! -f "$SCRIPT_DIR/deb/build-deb.sh" ]; then
        log_error "deb/build-deb.sh not found"
        exit 1
    fi

    "$SCRIPT_DIR/deb/build-deb.sh" "$VERSION" "$TARGET_ARCH"

    log_info ".deb package created"
}

create_rpm_package() {
    log_step "Creating .rpm package..."

    if [ ! -f "$SCRIPT_DIR/rpm/build-rpm.sh" ]; then
        log_error "rpm/build-rpm.sh not found"
        exit 1
    fi

    "$SCRIPT_DIR/rpm/build-rpm.sh" "$VERSION" "$TARGET_ARCH"

    log_info ".rpm package created"
}

native_build() {
    check_prerequisites
    clean_build
    build_rust_binary
    build_flutter_app

    case "$TARGET_FORMAT" in
        deb)
            create_deb_package
            ;;
        rpm)
            create_rpm_package
            ;;
        all)
            create_deb_package
            create_rpm_package
            ;;
        *)
            log_error "Unknown format: $TARGET_FORMAT"
            exit 1
            ;;
    esac
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    echo ""
    echo "=============================================================="
    echo "                    Build Complete!                           "
    echo "=============================================================="
    echo ""
    echo "Output directory: $BUILD_DIR"
    echo ""
    echo "Packages created:"
    ls -la "$BUILD_DIR"/*.deb "$BUILD_DIR"/*.rpm 2>/dev/null || echo "  (none found)"
    echo ""

    if [ "$TARGET_FORMAT" = "deb" ] || [ "$TARGET_FORMAT" = "all" ]; then
        echo "To install on Debian/Ubuntu:"
        echo "  sudo dpkg -i $BUILD_DIR/secureguard_${VERSION}_*.deb"
        echo ""
    fi

    if [ "$TARGET_FORMAT" = "rpm" ] || [ "$TARGET_FORMAT" = "all" ]; then
        echo "To install on Fedora/RHEL:"
        echo "  sudo rpm -i $BUILD_DIR/secureguard-${VERSION}-1.*.rpm"
        echo ""
    fi

    echo "To test installation in Docker:"
    echo "  $SCRIPT_DIR/docker-test.sh"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    parse_args "$@"
    print_banner

    if [ "$USE_DOCKER" = "true" ]; then
        docker_build
    else
        native_build
    fi

    print_summary
}

main "$@"
