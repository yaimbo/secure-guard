#!/bin/bash
# SecureGuard VPN Service Uninstaller for macOS
# This script removes the daemon service and cleans up

set -e

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

SERVICE_NAME="com.secureguard.vpn-service"
HELPER_TOOLS_DIR="/Library/PrivilegedHelperTools"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
SOCKET_PATH="/var/run/secureguard.sock"

echo "=== SecureGuard VPN Service Uninstaller ==="
echo ""

# Stop the service
if launchctl list | grep -q "$SERVICE_NAME"; then
    echo "Stopping service..."
    launchctl unload "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" 2>/dev/null || true
    sleep 1
fi

# Remove plist
if [ -f "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" ]; then
    echo "Removing LaunchDaemon plist..."
    rm -f "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
fi

# Remove binary
if [ -f "$HELPER_TOOLS_DIR/secureguard-service" ]; then
    echo "Removing binary..."
    rm -f "$HELPER_TOOLS_DIR/secureguard-service"
fi

# Remove socket
if [ -S "$SOCKET_PATH" ]; then
    echo "Removing socket..."
    rm -f "$SOCKET_PATH"
fi

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "Note: Log files at /var/log/secureguard*.log were preserved."
echo "To remove: sudo rm /var/log/secureguard*.log"
echo ""
echo "Note: Data directory at /var/lib/secureguard was preserved."
echo "To remove: sudo rm -rf /var/lib/secureguard"
