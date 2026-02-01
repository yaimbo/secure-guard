#!/bin/bash
# SecureGuard VPN - RPM Package Builder
# Creates an .rpm package from pre-built binaries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$(dirname "$INSTALLER_DIR")")"
BUILD_DIR="$INSTALLER_DIR/build"

VERSION="${1:-1.0.0}"
ARCH="${2:-x86_64}"

# Map architecture names for RPM
case "$ARCH" in
    x86_64|amd64) RPM_ARCH="x86_64" ;;
    aarch64|arm64) RPM_ARCH="aarch64" ;;
    *) echo "Unknown architecture: $ARCH"; exit 1 ;;
esac

# Colors
GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[RPM]${NC} $1"; }

log_info "Building .rpm package: secureguard-$VERSION-1.$RPM_ARCH"

# Set up rpmbuild directory structure
RPMBUILD_DIR="$BUILD_DIR/rpmbuild"
rm -rf "$RPMBUILD_DIR"
mkdir -p "$RPMBUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

# Create tarball of source files
log_info "Creating source tarball..."
SOURCE_DIR="$RPMBUILD_DIR/SOURCES/secureguard-$VERSION"
mkdir -p "$SOURCE_DIR"

# Copy daemon binary
cp "$BUILD_DIR/secureguard-service" "$SOURCE_DIR/"

# Copy Flutter client bundle
cp -r "$BUILD_DIR/flutter-bundle" "$SOURCE_DIR/"

# Copy service file
cp "$INSTALLER_DIR/secureguard.service" "$SOURCE_DIR/"

# Copy desktop file
cp "$INSTALLER_DIR/shared/secureguard.desktop" "$SOURCE_DIR/"

# Copy app icons from macOS asset catalog (properly sized)
ICON_SOURCE="$PROJECT_ROOT/secureguard_client/macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICON_SOURCE" ]; then
    mkdir -p "$SOURCE_DIR/icons"
    cp "$ICON_SOURCE/app_icon_128.png" "$SOURCE_DIR/icons/secureguard-48.png"
    cp "$ICON_SOURCE/app_icon_128.png" "$SOURCE_DIR/icons/secureguard-128.png"
    cp "$ICON_SOURCE/app_icon_256.png" "$SOURCE_DIR/icons/secureguard-256.png"
else
    echo "ERROR: App icons not found at $ICON_SOURCE"
    echo "Icons are required for desktop integration. Ensure the Flutter client has been built."
    exit 1
fi

# Create tarball
cd "$RPMBUILD_DIR/SOURCES"
tar czf "secureguard-$VERSION.tar.gz" "secureguard-$VERSION"
rm -rf "secureguard-$VERSION"

# Copy spec file and substitute version
log_info "Preparing spec file..."
sed "s/%{VERSION}/$VERSION/g" "$SCRIPT_DIR/secureguard.spec" > "$RPMBUILD_DIR/SPECS/secureguard.spec"

# Build the RPM
log_info "Building RPM..."
rpmbuild --define "_topdir $RPMBUILD_DIR" \
         --define "version $VERSION" \
         --target "$RPM_ARCH" \
         -bb "$RPMBUILD_DIR/SPECS/secureguard.spec"

# Move RPM to build directory
mv "$RPMBUILD_DIR/RPMS/$RPM_ARCH"/*.rpm "$BUILD_DIR/"

log_info "Package created: $BUILD_DIR/secureguard-$VERSION-1.$RPM_ARCH.rpm"
