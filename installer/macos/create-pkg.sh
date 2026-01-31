#!/bin/bash
# SecureGuard VPN - PKG Creation Script
# Creates a unified installer package for both the app and daemon service

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$SCRIPT_DIR/build"
PKG_ROOT="$BUILD_DIR/pkg-root"
FLUTTER_PROJECT="$PROJECT_ROOT/secureguard_client"

# Version (can be overridden)
VERSION="${1:-1.0.0}"

# Configuration
IDENTIFIER="com.secureguard.installer"
SERVICE_NAME="com.secureguard.vpn-service"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "========================================="
echo "  SecureGuard VPN Installer Builder"
echo "  Version: $VERSION"
echo "========================================="
echo ""

# Check for required daemon binary
check_daemon_binary() {
    local binary_path=""

    # Check build output locations
    if [ -f "$BUILD_DIR/secureguard-service" ]; then
        binary_path="$BUILD_DIR/secureguard-service"
    elif [ -f "$PROJECT_ROOT/target/release/secureguard-poc" ]; then
        binary_path="$PROJECT_ROOT/target/release/secureguard-poc"
    fi

    if [ -z "$binary_path" ]; then
        log_error "Daemon binary not found. Please either:"
        echo "  1. Run build-dmg.sh first (builds universal binary)"
        echo "  2. Run 'cargo build --release' manually"
        exit 1
    fi

    echo "$binary_path"
}

# Check for Flutter app
check_flutter_app() {
    local app_path="$FLUTTER_PROJECT/build/macos/Build/Products/Release/secureguard_client.app"

    if [ ! -d "$app_path" ]; then
        log_error "Flutter app not found at: $app_path"
        echo "  Please run: cd secureguard_client && flutter build macos --release"
        exit 1
    fi

    echo "$app_path"
}

# Clean and prepare build directory
prepare_build_dir() {
    log_info "Preparing build directory..."

    rm -rf "$PKG_ROOT"
    mkdir -p "$PKG_ROOT/Applications"
    mkdir -p "$PKG_ROOT/Library/PrivilegedHelperTools"
    mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
    mkdir -p "$BUILD_DIR"
}

# Copy files to package root
copy_files() {
    local daemon_binary="$1"
    local flutter_app="$2"

    log_info "Copying files to package root..."

    # Copy Flutter app to /Applications
    cp -R "$flutter_app" "$PKG_ROOT/Applications/SecureGuard.app"
    log_info "Flutter app copied to /Applications"

    # Copy daemon binary
    cp "$daemon_binary" "$PKG_ROOT/Library/PrivilegedHelperTools/secureguard-service"
    log_info "Daemon binary copied"

    # Copy LaunchDaemon plist
    cp "$SCRIPT_DIR/com.secureguard.vpn-service.plist" \
       "$PKG_ROOT/Library/LaunchDaemons/$SERVICE_NAME.plist"
    log_info "LaunchDaemon plist copied"
}

# Update Distribution.xml with version
prepare_distribution() {
    log_info "Preparing Distribution.xml..."

    # Create a versioned copy of Distribution.xml
    sed "s/VERSION/$VERSION/g" "$SCRIPT_DIR/pkg/Distribution.xml" > "$BUILD_DIR/Distribution.xml"
}

# Build component package
build_component_pkg() {
    log_info "Building component package..."

    pkgbuild \
        --root "$PKG_ROOT" \
        --scripts "$SCRIPT_DIR/pkg/scripts" \
        --identifier "$IDENTIFIER" \
        --version "$VERSION" \
        --ownership recommended \
        "$BUILD_DIR/secureguard-component.pkg"

    log_info "Component package created"
}

# Build final distribution package
build_distribution_pkg() {
    log_info "Building distribution package..."

    productbuild \
        --distribution "$BUILD_DIR/Distribution.xml" \
        --resources "$SCRIPT_DIR/pkg/Resources" \
        --package-path "$BUILD_DIR" \
        "$BUILD_DIR/SecureGuard-$VERSION.pkg"

    log_info "Distribution package created"
}

# Clean up intermediate files
cleanup() {
    log_info "Cleaning up intermediate files..."

    rm -rf "$PKG_ROOT"
    rm -f "$BUILD_DIR/secureguard-component.pkg"
    rm -f "$BUILD_DIR/Distribution.xml"
}

# Main
main() {
    local daemon_binary flutter_app

    daemon_binary=$(check_daemon_binary)
    flutter_app=$(check_flutter_app)

    log_info "Using daemon binary: $daemon_binary"
    log_info "Using Flutter app: $flutter_app"

    prepare_build_dir
    copy_files "$daemon_binary" "$flutter_app"
    prepare_distribution
    build_component_pkg
    build_distribution_pkg
    cleanup

    echo ""
    echo "========================================="
    echo "  Installer created successfully!"
    echo "  Output: $BUILD_DIR/SecureGuard-$VERSION.pkg"
    echo "========================================="
    echo ""
    echo "The installer includes:"
    echo "  - SecureGuard.app (installed to /Applications)"
    echo "  - VPN daemon service (runs in background)"
    echo ""
}

main "$@"
