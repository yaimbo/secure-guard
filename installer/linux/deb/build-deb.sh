#!/bin/bash
# SecureGuard VPN - Debian Package Builder
# Creates a .deb package from pre-built binaries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$(dirname "$INSTALLER_DIR")")"
BUILD_DIR="$INSTALLER_DIR/build"

VERSION="${1:-1.0.0}"
ARCH="${2:-x86_64}"

# Map architecture names
case "$ARCH" in
    x86_64|amd64) DEB_ARCH="amd64" ;;
    aarch64|arm64) DEB_ARCH="arm64" ;;
    *) echo "Unknown architecture: $ARCH"; exit 1 ;;
esac

PKG_NAME="secureguard_${VERSION}_${DEB_ARCH}"
PKG_ROOT="$BUILD_DIR/$PKG_NAME"

# Colors
GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[DEB]${NC} $1"; }

log_info "Building .deb package: $PKG_NAME"

# Clean and create package root
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT"

# Create directory structure
mkdir -p "$PKG_ROOT/DEBIAN"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/opt/secureguard"
mkdir -p "$PKG_ROOT/etc/systemd/system"
mkdir -p "$PKG_ROOT/usr/share/applications"
mkdir -p "$PKG_ROOT/usr/share/icons/hicolor/48x48/apps"
mkdir -p "$PKG_ROOT/usr/share/icons/hicolor/128x128/apps"
mkdir -p "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps"

# Copy daemon binary
log_info "Copying daemon binary..."
cp "$BUILD_DIR/secureguard-service" "$PKG_ROOT/usr/local/bin/"
chmod 755 "$PKG_ROOT/usr/local/bin/secureguard-service"

# Copy Flutter client bundle
log_info "Copying Flutter client..."
cp -r "$BUILD_DIR/flutter-bundle"/* "$PKG_ROOT/opt/secureguard/"
chmod 755 "$PKG_ROOT/opt/secureguard/secureguard_client"

# Create symlink for client in PATH
ln -sf /opt/secureguard/secureguard_client "$PKG_ROOT/usr/local/bin/secureguard"

# Copy systemd service file
log_info "Copying systemd service..."
cp "$INSTALLER_DIR/secureguard.service" "$PKG_ROOT/etc/systemd/system/"

# Copy desktop file
log_info "Copying desktop file..."
cp "$INSTALLER_DIR/shared/secureguard.desktop" "$PKG_ROOT/usr/share/applications/"

# Copy app icons from macOS asset catalog (properly sized)
ICON_SOURCE="$PROJECT_ROOT/secureguard_client/macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICON_SOURCE" ]; then
    log_info "Copying app icons..."
    # Use closest available sizes from the asset catalog
    cp "$ICON_SOURCE/app_icon_128.png" "$PKG_ROOT/usr/share/icons/hicolor/48x48/apps/secureguard.png"
    cp "$ICON_SOURCE/app_icon_128.png" "$PKG_ROOT/usr/share/icons/hicolor/128x128/apps/secureguard.png"
    cp "$ICON_SOURCE/app_icon_256.png" "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps/secureguard.png"
else
    echo "ERROR: App icons not found at $ICON_SOURCE"
    echo "Icons are required for desktop integration. Ensure the Flutter client has been built."
    exit 1
fi

# Generate control file
log_info "Generating control file..."
cat > "$PKG_ROOT/DEBIAN/control" << EOF
Package: secureguard
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Depends: libgtk-3-0, libsecret-1-0
Maintainer: SecureGuard Team <support@secureguard.io>
Description: SecureGuard VPN Client
 WireGuard-compatible VPN client with a modern GUI.
 Includes background daemon service and Flutter desktop client.
EOF

# Copy maintainer scripts
log_info "Copying maintainer scripts..."
cp "$SCRIPT_DIR/DEBIAN/preinst" "$PKG_ROOT/DEBIAN/"
cp "$SCRIPT_DIR/DEBIAN/postinst" "$PKG_ROOT/DEBIAN/"
cp "$SCRIPT_DIR/DEBIAN/prerm" "$PKG_ROOT/DEBIAN/"
cp "$SCRIPT_DIR/DEBIAN/postrm" "$PKG_ROOT/DEBIAN/"

chmod 755 "$PKG_ROOT/DEBIAN/preinst"
chmod 755 "$PKG_ROOT/DEBIAN/postinst"
chmod 755 "$PKG_ROOT/DEBIAN/prerm"
chmod 755 "$PKG_ROOT/DEBIAN/postrm"

# Build the package
log_info "Building package..."
dpkg-deb --build "$PKG_ROOT"

# Note: dpkg-deb creates the .deb in the same directory as PKG_ROOT,
# which is already BUILD_DIR, so no move needed

log_info "Package created: $BUILD_DIR/$PKG_NAME.deb"
