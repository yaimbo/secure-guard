#!/bin/bash
# SecureGuard VPN - macOS Installer Builder
# Builds both Rust daemon and Flutter app, then creates a unified PKG installer

set -euo pipefail

# Get script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$SCRIPT_DIR/build"
FLUTTER_PROJECT="$PROJECT_ROOT/secureguard_client"

# Version (can be overridden via argument)
VERSION="${1:-1.0.0}"

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
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            MinnowVPN - macOS Installer Builder             ║"
    echo "║                      Version: $VERSION                         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check for required tools
    local missing=()

    command -v cargo &>/dev/null || missing+=("cargo (Rust)")
    command -v flutter &>/dev/null || missing+=("flutter")
    command -v pkgbuild &>/dev/null || missing+=("pkgbuild (Xcode CLI tools)")
    command -v productbuild &>/dev/null || missing+=("productbuild (Xcode CLI tools)")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools:"
        for tool in "${missing[@]}"; do
            echo "  - $tool"
        done
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

# Clean build directory
clean_build() {
    log_step "Cleaning build directory..."

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    log_info "Build directory cleaned"
}

# Build universal Rust binary
build_rust_binary() {
    log_step "Building Rust daemon (universal binary)..."

    cd "$PROJECT_ROOT"

    # Check if we can build for both architectures
    local can_build_x86=false
    local can_build_arm=false

    if rustup target list --installed | grep -q "x86_64-apple-darwin"; then
        can_build_x86=true
    fi

    if rustup target list --installed | grep -q "aarch64-apple-darwin"; then
        can_build_arm=true
    fi

    # Current architecture
    local current_arch
    current_arch=$(uname -m)

    if $can_build_x86 && $can_build_arm; then
        log_info "Building universal binary (x86_64 + arm64)..."

        cargo build --release --target x86_64-apple-darwin
        cargo build --release --target aarch64-apple-darwin

        # Create universal binary with lipo
        lipo -create \
            "$PROJECT_ROOT/target/x86_64-apple-darwin/release/secureguard-poc" \
            "$PROJECT_ROOT/target/aarch64-apple-darwin/release/secureguard-poc" \
            -output "$BUILD_DIR/secureguard-service"

        log_info "Universal binary created"
    else
        log_warn "Cannot build universal binary. Building for current architecture only ($current_arch)..."
        log_warn "To build universal binary, install targets with:"
        echo "  rustup target add x86_64-apple-darwin aarch64-apple-darwin"

        cargo build --release
        cp "$PROJECT_ROOT/target/release/secureguard-poc" "$BUILD_DIR/secureguard-service"

        log_info "Native binary created"
    fi

    # Verify binary
    file "$BUILD_DIR/secureguard-service"
}

# Build Flutter macOS app
build_flutter_app() {
    log_step "Building Flutter macOS app..."

    cd "$FLUTTER_PROJECT"

    # Get dependencies
    flutter pub get

    # Build release app
    flutter build macos --release

    log_info "Flutter app built successfully"
}

# Create unified installer PKG
create_installer_pkg() {
    log_step "Creating unified installer PKG..."

    "$SCRIPT_DIR/create-pkg.sh" "$VERSION"

    log_info "Installer PKG created"
}

# Print final summary
print_summary() {
    local pkg_file="$BUILD_DIR/MinnowVPN-$VERSION.pkg"
    local pkg_size
    pkg_size=$(du -h "$pkg_file" | cut -f1)

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    Build Complete!                         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Output:"
    echo "  Installer: $pkg_file"
    echo "  Size: $pkg_size"
    echo ""
    echo "The installer includes:"
    echo "  - MinnowVPN.app (installed to /Applications)"
    echo "  - VPN daemon service (runs in background)"
    echo ""
    echo "To install:"
    echo "  Double-click the PKG file, or run:"
    echo "  sudo installer -pkg '$pkg_file' -target /"
    echo ""
}

# Main
main() {
    print_banner
    check_prerequisites
    clean_build
    build_rust_binary
    build_flutter_app
    create_installer_pkg
    print_summary
}

main "$@"
