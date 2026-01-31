#!/bin/bash
# SecureGuard VPN - macOS DMG Builder
# Creates a distributable DMG containing the Flutter app and daemon installer

set -euo pipefail

# Get script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_DIR="$SCRIPT_DIR/build"
FLUTTER_PROJECT="$PROJECT_ROOT/secureguard_client"

# Version (can be overridden via argument)
VERSION="${1:-1.0.0}"
DMG_NAME="SecureGuard-$VERSION-macOS"
DMG_VOLUME_NAME="SecureGuard $VERSION"

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
    echo "║       SecureGuard VPN - macOS DMG Installer Builder        ║"
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
    command -v hdiutil &>/dev/null || missing+=("hdiutil")
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

# Create installer PKG
create_installer_pkg() {
    log_step "Creating installer PKG..."

    "$SCRIPT_DIR/create-pkg.sh" "$VERSION"

    log_info "Installer PKG created"
}

# Create DMG
create_dmg() {
    log_step "Creating DMG..."

    local dmg_temp="$BUILD_DIR/dmg-temp"
    local dmg_rw="$BUILD_DIR/temp.dmg"
    local dmg_final="$BUILD_DIR/$DMG_NAME.dmg"

    # Create temp directory
    rm -rf "$dmg_temp"
    mkdir -p "$dmg_temp"

    # Copy Flutter app
    local flutter_app="$FLUTTER_PROJECT/build/macos/Build/Products/Release/secureguard_client.app"
    if [ -d "$flutter_app" ]; then
        cp -R "$flutter_app" "$dmg_temp/SecureGuard.app"
        log_info "Flutter app copied"
    else
        log_error "Flutter app not found at: $flutter_app"
        exit 1
    fi

    # Copy installer PKG
    cp "$BUILD_DIR/Install SecureGuard Service.pkg" "$dmg_temp/"
    log_info "Installer PKG copied"

    # Create Applications symlink
    ln -s /Applications "$dmg_temp/Applications"

    # Copy background if exists
    if [ -d "$SCRIPT_DIR/dmg" ]; then
        mkdir -p "$dmg_temp/.background"
        [ -f "$SCRIPT_DIR/dmg/background.png" ] && \
            cp "$SCRIPT_DIR/dmg/background.png" "$dmg_temp/.background/"
        [ -f "$SCRIPT_DIR/dmg/background@2x.png" ] && \
            cp "$SCRIPT_DIR/dmg/background@2x.png" "$dmg_temp/.background/"
    fi

    # Create read-write DMG
    log_info "Creating temporary DMG..."
    hdiutil create -srcfolder "$dmg_temp" \
        -volname "$DMG_VOLUME_NAME" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" \
        -format UDRW \
        "$dmg_rw"

    # Mount DMG to customize
    log_info "Customizing DMG layout..."
    local device
    device=$(hdiutil attach -readwrite -noverify "$dmg_rw" | awk '/dev\/disk/ {print $1; exit}')
    local mount_point="/Volumes/$DMG_VOLUME_NAME"

    # Wait for mount
    sleep 2

    # Apply icon layout via AppleScript
    osascript << EOF || log_warn "Could not apply icon layout (non-fatal)"
tell application "Finder"
    tell disk "$DMG_VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 100, 1000, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80

        -- Position icons
        set position of item "SecureGuard.app" to {150, 180}
        set position of item "Applications" to {450, 180}
        set position of item "Install SecureGuard Service.pkg" to {300, 340}

        close
        open
        update without registering applications
    end tell
end tell
EOF

    # Sync and unmount
    sync
    sleep 2
    hdiutil detach "$device" || hdiutil detach "$device" -force

    # Convert to compressed read-only DMG
    log_info "Creating final compressed DMG..."
    rm -f "$dmg_final"
    hdiutil convert "$dmg_rw" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$dmg_final"

    # Cleanup
    rm -f "$dmg_rw"
    rm -rf "$dmg_temp"

    log_info "DMG created: $dmg_final"
}

# Print final summary
print_summary() {
    local dmg_file="$BUILD_DIR/$DMG_NAME.dmg"
    local dmg_size
    dmg_size=$(du -h "$dmg_file" | cut -f1)

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    Build Complete!                         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Output:"
    echo "  DMG: $dmg_file"
    echo "  Size: $dmg_size"
    echo ""
    echo "Contents:"
    echo "  - SecureGuard.app (Flutter desktop client)"
    echo "  - Install SecureGuard Service.pkg (Daemon installer)"
    echo "  - Applications symlink"
    echo ""
    echo "To test:"
    echo "  1. Open the DMG: open '$dmg_file'"
    echo "  2. Double-click 'Install SecureGuard Service.pkg'"
    echo "  3. Drag 'SecureGuard.app' to Applications"
    echo "  4. Launch SecureGuard from Applications"
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
    create_dmg
    print_summary
}

main "$@"
