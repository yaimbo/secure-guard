#!/bin/bash
# SecureGuard VPN Service Installer for macOS
# This script installs the daemon service with proper permissions

set -e

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="com.secureguard.vpn-service"
HELPER_TOOLS_DIR="/Library/PrivilegedHelperTools"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
LOG_DIR="/var/log"
DATA_DIR="/var/lib/secureguard"

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
if launchctl list | grep -q "$SERVICE_NAME"; then
    echo "Stopping existing service..."
    launchctl unload "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" 2>/dev/null || true
fi

# Create directories
echo "Creating directories..."
mkdir -p "$HELPER_TOOLS_DIR"
mkdir -p "$DATA_DIR"

# Copy binary
echo "Installing binary..."
cp "$BINARY_PATH" "$HELPER_TOOLS_DIR/secureguard-service"
chmod 755 "$HELPER_TOOLS_DIR/secureguard-service"
chown root:wheel "$HELPER_TOOLS_DIR/secureguard-service"

# Copy plist
echo "Installing LaunchDaemon..."
cp "$SCRIPT_DIR/com.secureguard.vpn-service.plist" "$LAUNCH_DAEMONS_DIR/"
chmod 644 "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
chown root:wheel "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"

# Set up log files
touch "$LOG_DIR/secureguard.log"
touch "$LOG_DIR/secureguard.error.log"
chmod 644 "$LOG_DIR/secureguard.log" "$LOG_DIR/secureguard.error.log"

# Load the service
echo "Starting service..."
launchctl load "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"

# Verify service is running
sleep 1
if launchctl list | grep -q "$SERVICE_NAME"; then
    echo ""
    echo "=== Installation Complete ==="
    echo ""
    echo "Service installed and running."
    echo "Socket: /var/run/secureguard.sock"
    echo "Logs: /var/log/secureguard.log"
    echo ""
    echo "Commands:"
    echo "  Stop:    sudo launchctl unload $LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
    echo "  Start:   sudo launchctl load $LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
    echo "  Status:  sudo launchctl list | grep secureguard"
    echo "  Logs:    tail -f /var/log/secureguard.log"
else
    echo ""
    echo "Warning: Service may not have started correctly."
    echo "Check logs: tail /var/log/secureguard.error.log"
fi
