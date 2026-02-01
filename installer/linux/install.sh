#!/bin/bash
# SecureGuard VPN Service Installer for Linux
# This script installs the daemon service with proper permissions and security

set -euo pipefail

# Configuration
SERVICE_NAME="secureguard"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
DATA_DIR="/var/lib/secureguard"
RUN_DIR="/var/run/secureguard"
LOG_DIR="/var/log/secureguard"
TOKEN_FILE="$RUN_DIR/auth-token"
HTTP_PORT=51820
SECUREGUARD_GROUP="secureguard"

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
echo "║        SecureGuard VPN Service Installer for Linux        ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    echo "Usage: sudo $0"
    exit 1
fi

# Detect init system
detect_init_system() {
    if [ -d /run/systemd/system ]; then
        echo "systemd"
    elif [ -f /etc/init.d/cron ] && [ ! -d /run/systemd/system ]; then
        echo "sysvinit"
    else
        echo "unknown"
    fi
}

# Check system requirements
check_requirements() {
    local init_system
    init_system=$(detect_init_system)
    log_info "Detected init system: $init_system"

    if [ "$init_system" != "systemd" ]; then
        log_error "This installer requires systemd"
        echo "For other init systems, please install manually."
        exit 1
    fi

    # Check kernel version for required features
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1-2)
    log_info "Kernel version: $(uname -r)"

    # Check for TUN device support
    if [ ! -e /dev/net/tun ]; then
        log_warn "/dev/net/tun not found - attempting to create..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 666 /dev/net/tun 2>/dev/null || true
    fi

    if [ ! -c /dev/net/tun ]; then
        log_error "TUN device not available. Please enable CONFIG_TUN in kernel."
        exit 1
    fi
    log_info "TUN device available"
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

# Verify binary
verify_binary() {
    local binary_path="$1"
    local arch

    log_info "Binary: $binary_path"

    # Check if it's executable
    if ! file "$binary_path" | grep -q "ELF"; then
        log_error "Binary is not a valid Linux executable"
        exit 1
    fi

    # Check architecture matches
    local binary_arch
    local system_arch
    binary_arch=$(file "$binary_path" | grep -oP '(x86-64|aarch64|ARM)')
    system_arch=$(uname -m)

    if [[ "$system_arch" == "x86_64" ]] && [[ "$binary_arch" != "x86-64" ]]; then
        log_warn "Binary architecture may not match system ($binary_arch vs $system_arch)"
    elif [[ "$system_arch" == "aarch64" ]] && [[ "$binary_arch" != "aarch64" ]]; then
        log_warn "Binary architecture may not match system ($binary_arch vs $system_arch)"
    fi

    log_info "Binary architecture verified"
}

# Calculate SHA256 hash
calculate_hash() {
    local file_path="$1"
    sha256sum "$file_path" | awk '{print $1}'
}

# Backup existing installation
backup_existing() {
    local backup_dir="/tmp/secureguard-backup-$(date +%Y%m%d-%H%M%S)"

    if [ -f "$INSTALL_DIR/secureguard-service" ] || [ -f "$SYSTEMD_DIR/secureguard.service" ]; then
        log_info "Backing up existing installation to $backup_dir"
        mkdir -p "$backup_dir"

        [ -f "$INSTALL_DIR/secureguard-service" ] && \
            cp "$INSTALL_DIR/secureguard-service" "$backup_dir/" 2>/dev/null || true
        [ -f "$SYSTEMD_DIR/secureguard.service" ] && \
            cp "$SYSTEMD_DIR/secureguard.service" "$backup_dir/" 2>/dev/null || true

        log_info "Backup saved to: $backup_dir"
    fi
}

# Stop existing service
stop_existing_service() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping existing service..."
        systemctl stop "$SERVICE_NAME" || true
        sleep 2
    fi
}

# Create secureguard group for token access
create_secureguard_group() {
    log_info "Setting up secureguard group..."

    # Create group if it doesn't exist
    if ! getent group "$SECUREGUARD_GROUP" > /dev/null 2>&1; then
        log_info "Creating group: $SECUREGUARD_GROUP"
        groupadd -f "$SECUREGUARD_GROUP"
    else
        log_info "Group $SECUREGUARD_GROUP already exists"
    fi

    # Add the invoking user to the group (if SUDO_USER is set)
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        if ! id -nG "$SUDO_USER" | grep -qw "$SECUREGUARD_GROUP"; then
            log_info "Adding user $SUDO_USER to $SECUREGUARD_GROUP group"
            usermod -aG "$SECUREGUARD_GROUP" "$SUDO_USER"
        else
            log_info "User $SUDO_USER already in $SECUREGUARD_GROUP group"
        fi
    fi
}

# Create required directories
create_directories() {
    log_info "Creating directories..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$RUN_DIR"
    mkdir -p "$LOG_DIR"

    # Data directory: root:secureguard, 750
    # Stores persistent connection state for auto-reconnect on boot
    chown root:$SECUREGUARD_GROUP "$DATA_DIR"
    chmod 750 "$DATA_DIR"

    # Log directory
    chmod 750 "$LOG_DIR"

    # Token directory: root:secureguard, 750
    chown root:$SECUREGUARD_GROUP "$RUN_DIR"
    chmod 750 "$RUN_DIR"
}

# Install binary
install_binary() {
    local binary_path="$1"
    local dest="$INSTALL_DIR/secureguard-service"

    log_info "Installing binary..."

    # Copy binary
    cp "$binary_path" "$dest"

    # Set ownership and permissions
    chown root:root "$dest"
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

# Install uninstall script (for in-app uninstall feature)
install_uninstall_script() {
    local script_source="$SCRIPT_DIR/uninstall.sh"
    local app_dir="/opt/secureguard"
    local script_dest="$app_dir/uninstall.sh"

    if [ -f "$script_source" ]; then
        log_info "Installing uninstall script..."

        # Create app directory if it doesn't exist
        mkdir -p "$app_dir"

        # Copy and set permissions
        cp "$script_source" "$script_dest"
        chown root:root "$script_dest"
        chmod 755 "$script_dest"

        log_info "Uninstall script installed to $script_dest"
    else
        log_warn "Uninstall script not found at $script_source"
    fi
}

# Set capabilities
set_capabilities() {
    log_info "Setting capabilities..."

    if setcap cap_net_admin,cap_net_raw,cap_net_bind_service=eip "$INSTALL_DIR/secureguard-service" 2>/dev/null; then
        log_info "Capabilities set successfully"
    else
        log_warn "Could not set capabilities. Service will run with systemd capabilities."
    fi
}

# Install systemd service
install_service() {
    log_info "Installing systemd service..."

    # Copy service file
    cp "$SCRIPT_DIR/secureguard.service" "$SYSTEMD_DIR/"
    chmod 644 "$SYSTEMD_DIR/secureguard.service"

    # Reload systemd
    log_info "Reloading systemd..."
    systemctl daemon-reload
}

# Enable and start service
start_service() {
    log_info "Enabling and starting service..."

    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # Wait for service to start
    sleep 2
}

# Verify service is running
verify_service() {
    log_info "Verifying service..."

    # Check if service is active
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "Service is not running"
        echo ""
        echo "Check status with: sudo systemctl status secureguard"
        echo "Check logs with:   sudo journalctl -u secureguard -n 50"
        return 1
    fi

    log_info "Service is running"

    # Check if HTTP port is listening
    local retries=5
    while [ $retries -gt 0 ]; do
        if ss -tlnp | grep -q ":$HTTP_PORT "; then
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
    echo "  Binary:  $INSTALL_DIR/secureguard-service"
    echo "  API:     http://127.0.0.1:$HTTP_PORT/api/v1"
    echo "  Token:   $TOKEN_FILE"
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
    echo "  Status:  sudo systemctl status secureguard"
    echo "  Stop:    sudo systemctl stop secureguard"
    echo "  Start:   sudo systemctl start secureguard"
    echo "  Restart: sudo systemctl restart secureguard"
    echo "  Logs:    sudo journalctl -u secureguard -f"
    echo ""
    echo "Security Hardening Applied:"
    echo "  - Syscall filtering (seccomp)"
    echo "  - Capability restrictions"
    echo "  - Filesystem isolation"
    echo "  - Memory execution protection"
    echo ""
}

# Print failure message
print_failure() {
    echo ""
    log_error "Installation may have encountered issues."
    echo ""
    echo "Troubleshooting:"
    echo "  Check service: sudo systemctl status secureguard"
    echo "  Check logs:    sudo journalctl -u secureguard -n 50"
    echo "  Verify binary: $INSTALL_DIR/secureguard-service --version"
    echo ""
}

# Main installation flow
main() {
    check_requirements

    local binary_path
    binary_path=$(find_binary)
    verify_binary "$binary_path"

    backup_existing
    stop_existing_service
    create_secureguard_group
    create_directories
    install_binary "$binary_path"
    install_uninstall_script
    set_capabilities
    install_service
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
