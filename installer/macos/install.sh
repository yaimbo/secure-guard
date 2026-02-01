#!/bin/bash
# SecureGuard VPN Service Installer for macOS
# This script installs the daemon service with proper permissions and security

set -euo pipefail

# Configuration
SERVICE_NAME="com.secureguard.vpn-service"
HELPER_TOOLS_DIR="/Library/PrivilegedHelperTools"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
APPLICATION_SUPPORT_DIR="/Library/Application Support/SecureGuard"
LOG_DIR="/var/log"
DATA_DIR="/var/lib/secureguard"
TOKEN_DIR="/var/run/secureguard"
TOKEN_FILE="$TOKEN_DIR/auth-token"
HTTP_PORT=51820
MIN_MACOS_VERSION="10.15"
SECUREGUARD_GROUP="secureguard"
SECUREGUARD_GID=1100

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Print banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║          MinnowVPN Service Installer for macOS            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    echo "Usage: sudo $0"
    exit 1
fi

# Check macOS version
check_macos_version() {
    local current_version
    current_version=$(sw_vers -productVersion)
    log_info "Detected macOS version: $current_version"

    # Compare versions (basic comparison)
    if [[ "$(printf '%s\n' "$MIN_MACOS_VERSION" "$current_version" | sort -V | head -n1)" != "$MIN_MACOS_VERSION" ]]; then
        log_error "macOS $MIN_MACOS_VERSION or higher is required (found $current_version)"
        exit 1
    fi
}

# Find the binary
find_binary() {
    local binary_path=""

    # Check various locations
    if [ -f "$SCRIPT_DIR/../../target/release/secureguard-poc" ]; then
        binary_path="$SCRIPT_DIR/../../target/release/secureguard-poc"
    elif [ -f "$SCRIPT_DIR/secureguard-service" ]; then
        binary_path="$SCRIPT_DIR/secureguard-service"
    elif [ -f "/tmp/secureguard-service" ]; then
        binary_path="/tmp/secureguard-service"
    fi

    if [ -z "$binary_path" ]; then
        log_error "Could not find secureguard binary"
        echo ""
        echo "Please either:"
        echo "  1. Build with: cargo build --release"
        echo "  2. Place binary at: $SCRIPT_DIR/secureguard-service"
        exit 1
    fi

    echo "$binary_path"
}

# Verify binary architecture
verify_binary() {
    local binary_path="$1"
    local arch
    arch=$(file "$binary_path")

    log_info "Binary: $binary_path"

    # Check if it's a valid executable
    if ! file "$binary_path" | grep -q "Mach-O"; then
        log_error "Binary is not a valid macOS executable"
        exit 1
    fi

    # Get current architecture
    local current_arch
    current_arch=$(uname -m)

    if [[ "$current_arch" == "arm64" ]] && ! echo "$arch" | grep -q "arm64"; then
        log_warn "Binary may not be optimized for Apple Silicon"
    fi

    log_info "Binary architecture verified"
}

# Calculate SHA256 hash
calculate_hash() {
    local file_path="$1"
    shasum -a 256 "$file_path" | awk '{print $1}'
}

# Backup existing installation
backup_existing() {
    local backup_dir="/tmp/secureguard-backup-$(date +%Y%m%d-%H%M%S)"

    if [ -f "$HELPER_TOOLS_DIR/secureguard-service" ] || [ -f "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" ]; then
        log_info "Backing up existing installation to $backup_dir"
        mkdir -p "$backup_dir"

        [ -f "$HELPER_TOOLS_DIR/secureguard-service" ] && \
            cp "$HELPER_TOOLS_DIR/secureguard-service" "$backup_dir/" 2>/dev/null || true
        [ -f "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" ] && \
            cp "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" "$backup_dir/" 2>/dev/null || true

        log_info "Backup saved to: $backup_dir"
    fi
}

# Stop existing service
stop_existing_service() {
    if launchctl list 2>/dev/null | grep -q "$SERVICE_NAME"; then
        log_info "Stopping existing service..."
        launchctl bootout system/"$SERVICE_NAME" 2>/dev/null || \
        launchctl unload "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" 2>/dev/null || true
        sleep 2
    fi
}

# Create secureguard group for token access
create_secureguard_group() {
    log_info "Setting up secureguard group..."

    # Check if group exists
    if ! dscl . -read /Groups/$SECUREGUARD_GROUP &>/dev/null; then
        log_info "Creating group: $SECUREGUARD_GROUP"
        dscl . -create /Groups/$SECUREGUARD_GROUP
        dscl . -create /Groups/$SECUREGUARD_GROUP PrimaryGroupID $SECUREGUARD_GID
        dscl . -create /Groups/$SECUREGUARD_GROUP RealName "MinnowVPN Users"
    else
        log_info "Group $SECUREGUARD_GROUP already exists"
    fi

    # Add the invoking user to the group (if SUDO_USER is set)
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        if ! dscl . -read /Groups/$SECUREGUARD_GROUP GroupMembership 2>/dev/null | grep -q "$SUDO_USER"; then
            log_info "Adding user $SUDO_USER to $SECUREGUARD_GROUP group"
            dscl . -append /Groups/$SECUREGUARD_GROUP GroupMembership "$SUDO_USER"
        else
            log_info "User $SUDO_USER already in $SECUREGUARD_GROUP group"
        fi
    fi
}

# Create required directories
create_directories() {
    log_info "Creating directories..."

    mkdir -p "$HELPER_TOOLS_DIR"
    mkdir -p "$APPLICATION_SUPPORT_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$TOKEN_DIR"

    # Set permissions on data directory
    chmod 700 "$DATA_DIR"

    # Set permissions on token directory (root:secureguard, 750)
    chown root:$SECUREGUARD_GROUP "$TOKEN_DIR"
    chmod 750 "$TOKEN_DIR"
}

# Install binary
install_binary() {
    local binary_path="$1"
    local dest="$HELPER_TOOLS_DIR/secureguard-service"

    log_info "Installing binary..."

    # Copy binary
    cp "$binary_path" "$dest"

    # Set ownership and permissions
    chown root:wheel "$dest"
    chmod 755 "$dest"

    # Verify installation
    local src_hash dest_hash
    src_hash=$(calculate_hash "$binary_path")
    dest_hash=$(calculate_hash "$dest")

    if [ "$src_hash" != "$dest_hash" ]; then
        log_error "Binary verification failed! Installation may be corrupted."
        exit 1
    fi

    log_info "Binary installed and verified (SHA256: ${dest_hash:0:16}...)"
}

# Install plist and sandbox profile
install_configs() {
    log_info "Installing LaunchDaemon configuration..."

    # Install plist
    cp "$SCRIPT_DIR/com.secureguard.vpn-service.plist" "$LAUNCH_DAEMONS_DIR/"
    chown root:wheel "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
    chmod 644 "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"

    # Install sandbox profile (if exists)
    if [ -f "$SCRIPT_DIR/com.secureguard.vpn-service.sb" ]; then
        log_info "Installing sandbox profile..."
        cp "$SCRIPT_DIR/com.secureguard.vpn-service.sb" "$APPLICATION_SUPPORT_DIR/"
        chown root:wheel "$APPLICATION_SUPPORT_DIR/com.secureguard.vpn-service.sb"
        chmod 644 "$APPLICATION_SUPPORT_DIR/com.secureguard.vpn-service.sb"
    fi
}

# Set up logging
setup_logging() {
    log_info "Setting up logging..."

    touch "$LOG_DIR/secureguard.log"
    touch "$LOG_DIR/secureguard.error.log"

    # Secure log permissions
    chmod 640 "$LOG_DIR/secureguard.log" "$LOG_DIR/secureguard.error.log"
    chown root:wheel "$LOG_DIR/secureguard.log" "$LOG_DIR/secureguard.error.log"
}

# Start the service
start_service() {
    log_info "Starting service..."

    # Use bootstrap for modern macOS
    if launchctl bootstrap system "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" 2>/dev/null; then
        log_info "Service bootstrapped successfully"
    else
        # Fallback to legacy load
        launchctl load "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
    fi

    # Wait for service to start
    sleep 2
}

# Verify service is running
verify_service() {
    log_info "Verifying service..."

    # Check if service is registered
    if ! launchctl list 2>/dev/null | grep -q "$SERVICE_NAME"; then
        log_error "Service not found in launchctl list"
        return 1
    fi

    # Check if HTTP port is listening
    local retries=5
    while [ $retries -gt 0 ]; do
        if lsof -i :$HTTP_PORT -sTCP:LISTEN &>/dev/null; then
            log_info "HTTP server listening on port $HTTP_PORT"
            return 0
        fi
        sleep 1
        ((retries--))
    done

    # Check if token file was created
    if [ -f "$TOKEN_FILE" ]; then
        log_info "Auth token file created"
    fi

    log_warn "HTTP server not responding yet, but service may still be starting"
    return 0
}

# Print success message
print_success() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║            Installation Complete Successfully!            ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Service Details:"
    echo "  Binary:  $HELPER_TOOLS_DIR/secureguard-service"
    echo "  API:     http://127.0.0.1:$HTTP_PORT/api/v1"
    echo "  Token:   $TOKEN_FILE"
    echo "  Logs:    $LOG_DIR/secureguard.log"
    echo "  Data:    $DATA_DIR"
    echo ""
    echo "Authentication:"
    echo "  Users in the '$SECUREGUARD_GROUP' group can access the daemon API."
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "  User '$SUDO_USER' has been added to this group."
        echo "  NOTE: You may need to log out and back in for group changes to take effect."
    fi
    echo ""
    echo "Management Commands:"
    echo "  Status:  sudo launchctl list | grep secureguard"
    echo "  Stop:    sudo launchctl bootout system/$SERVICE_NAME"
    echo "  Start:   sudo launchctl bootstrap system $LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
    echo "  Logs:    tail -f $LOG_DIR/secureguard.log"
    echo ""
}

# Print failure message
print_failure() {
    echo ""
    log_error "Installation may have encountered issues."
    echo ""
    echo "Troubleshooting:"
    echo "  Check logs:  tail $LOG_DIR/secureguard.error.log"
    echo "  Check service: sudo launchctl list | grep secureguard"
    echo "  Verify binary: $HELPER_TOOLS_DIR/secureguard-service --version"
    echo ""
}

# Main installation flow
main() {
    check_macos_version

    local binary_path
    binary_path=$(find_binary)
    verify_binary "$binary_path"

    backup_existing
    stop_existing_service
    create_secureguard_group
    create_directories
    install_binary "$binary_path"
    install_configs
    setup_logging
    start_service

    if verify_service; then
        print_success
    else
        print_failure
        exit 1
    fi
}

# Run main
main "$@"
