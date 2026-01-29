#!/bin/bash
# SecureGuard VPN Service Uninstaller for Linux
# This script removes the daemon service and cleans up

set -e

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

SERVICE_NAME="secureguard"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

echo "=== SecureGuard VPN Service Uninstaller ==="
echo ""

# Stop and disable the service
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Stopping service..."
    systemctl stop "$SERVICE_NAME"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Disabling service..."
    systemctl disable "$SERVICE_NAME"
fi

# Remove systemd service file
if [ -f "$SYSTEMD_DIR/secureguard.service" ]; then
    echo "Removing systemd service..."
    rm -f "$SYSTEMD_DIR/secureguard.service"
    systemctl daemon-reload
fi

# Remove binary
if [ -f "$INSTALL_DIR/secureguard-service" ]; then
    echo "Removing binary..."
    rm -f "$INSTALL_DIR/secureguard-service"
fi

# Remove socket
if [ -S "/var/run/secureguard/secureguard.sock" ]; then
    echo "Removing socket..."
    rm -f "/var/run/secureguard/secureguard.sock"
fi

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "Note: Data directory at /var/lib/secureguard was preserved."
echo "To remove: sudo rm -rf /var/lib/secureguard"
echo ""
echo "Note: Run directory at /var/run/secureguard was preserved."
echo "To remove: sudo rm -rf /var/run/secureguard"
