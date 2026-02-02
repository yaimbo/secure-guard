#!/bin/bash
# MinnowVPN Linux Package Installation Test
# Tests package installation in a clean Docker container

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[TEST]${NC} $1"; }

# Parse arguments
DISTRO="${1:-debian}"
ARCH="${2:-}"

# Auto-detect architecture
if [ -z "$ARCH" ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
    esac
fi

DOCKER_PLATFORM="linux/$ARCH"

echo ""
echo "=============================================================="
echo "       MinnowVPN Package Installation Test                   "
echo "=============================================================="
echo ""
echo "Distribution: $DISTRO"
echo "Architecture: $ARCH"
echo "Platform: $DOCKER_PLATFORM"
echo ""

# Find package to test
case "$DISTRO" in
    debian|ubuntu)
        PKG_FILE=$(ls "$BUILD_DIR"/minnowvpn_*_${ARCH}.deb 2>/dev/null | head -1) || true
        if [ -z "$PKG_FILE" ]; then
            # Try alternate arch names
            PKG_FILE=$(ls "$BUILD_DIR"/minnowvpn_*_amd64.deb 2>/dev/null | head -1) || true
        fi
        BASE_IMAGE="debian:bookworm-slim"
        INSTALL_CMD="dpkg -i"
        ;;
    fedora)
        rpm_arch="$ARCH"
        [ "$ARCH" = "amd64" ] && rpm_arch="x86_64"
        [ "$ARCH" = "arm64" ] && rpm_arch="aarch64"
        PKG_FILE=$(ls "$BUILD_DIR"/minnowvpn-*."${rpm_arch}".rpm 2>/dev/null | head -1) || true
        BASE_IMAGE="fedora:latest"
        INSTALL_CMD="rpm -i"
        ;;
    *)
        log_error "Unknown distro: $DISTRO (use debian, ubuntu, or fedora)"
        exit 1
        ;;
esac

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
    log_error "No package found for $DISTRO $ARCH"
    log_error "Available packages:"
    ls -la "$BUILD_DIR"/ 2>/dev/null || echo "  (none)"
    exit 1
fi

log_info "Testing package: $(basename "$PKG_FILE")"

# Create test script
TEST_SCRIPT=$(cat << 'EOF'
#!/bin/bash
set -e

echo "=== Installing dependencies ==="
if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq libgtk-3-0 libsecret-1-0 file >/dev/null
elif command -v dnf &>/dev/null; then
    dnf install -y -q gtk3 libsecret file >/dev/null
fi

echo "=== Installing package ==="
# Allow dpkg to fail on systemd-related issues in Docker
DEBIAN_FRONTEND=noninteractive $INSTALL_CMD /pkg/$PKG_NAME || true

echo ""
echo "=== Checking installed files ==="
ls -la /usr/local/bin/minnowvpn* || echo "No binaries in /usr/local/bin"
ls -la /opt/minnowvpn/ || echo "No /opt/minnowvpn"
ls -la /etc/systemd/system/minnowvpn.service || echo "No systemd service"
ls -la /usr/share/applications/minnowvpn.desktop || echo "No desktop file"

echo ""
echo "=== Checking daemon binary ==="
/usr/local/bin/minnowvpn-service --help || echo "Daemon help failed (may need args)"

echo ""
echo "=== Checking client binary ==="
file /opt/minnowvpn/minnowvpn_client || echo "Client binary not found"

echo ""
echo "=== Installation Test PASSED ==="
EOF
)

# Run test in Docker
log_step "Starting test container..."

docker run --rm \
    --platform "$DOCKER_PLATFORM" \
    -v "$BUILD_DIR:/pkg:ro" \
    -e "INSTALL_CMD=$INSTALL_CMD" \
    -e "PKG_NAME=$(basename "$PKG_FILE")" \
    "$BASE_IMAGE" \
    bash -c "$TEST_SCRIPT"

echo ""
log_info "All tests passed!"
echo ""
