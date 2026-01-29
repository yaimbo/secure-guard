#!/bin/bash
# SecureGuard VPN Service Installer for Linux
# This script installs the daemon service with proper permissions

set -e

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="secureguard"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
DATA_DIR="/var/lib/secureguard"
RUN_DIR="/var/run/secureguard"

echo "=== SecureGuard VPN Service Installer ==="
echo ""

# Find the binary
BINARY_PATH=""
if [ -f "$SCRIPT_DIR/../../target/release/secureguard-poc" ]; then
    BINARY_PATH="$SCRIPT_DIR/../../target/release/secureguard-poc"
elif [ -f "$SCRIPT_DIR/secureguard-service" ]; then
    BINARY_PATH="$SCRIPT_DIR/secureguard-service"
else
    echo "Error: Could not find secureguard binary"
    echo "Please build with: cargo build --release"
    exit 1
fi

echo "Using binary: $BINARY_PATH"

# Stop existing service if running
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Stopping existing service..."
    systemctl stop "$SERVICE_NAME"
fi

# Create directories
echo "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "$RUN_DIR"
chmod 755 "$RUN_DIR"

# Copy binary
echo "Installing binary..."
cp "$BINARY_PATH" "$INSTALL_DIR/secureguard-service"
chmod 755 "$INSTALL_DIR/secureguard-service"

# Set capabilities (alternative to running as root)
echo "Setting capabilities..."
setcap cap_net_admin,cap_net_raw,cap_net_bind_service=eip "$INSTALL_DIR/secureguard-service" || {
    echo "Warning: Could not set capabilities. Service may need to run as root."
}

# Copy systemd service file
echo "Installing systemd service..."
cp "$SCRIPT_DIR/secureguard.service" "$SYSTEMD_DIR/"
chmod 644 "$SYSTEMD_DIR/secureguard.service"

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable and start the service
echo "Enabling and starting service..."
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Verify service is running
sleep 1
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "Service installed and running."
    echo "Socket: /var/run/secureguard/secureguard.sock"
    echo ""
    echo "Commands:"
    echo "  Status:  sudo systemctl status secureguard"
    echo "  Stop:    sudo systemctl stop secureguard"
    echo "  Start:   sudo systemctl start secureguard"
    echo "  Logs:    sudo journalctl -u secureguard -f"
else
    echo ""
    echo "Warning: Service may not have started correctly."
    echo "Check logs: sudo journalctl -u secureguard"
fi
