#!/bin/bash
# SecureGuard VPN Service Uninstaller for macOS
# This script removes the daemon service and cleans up

set -euo pipefail

# Configuration
SERVICE_NAME="com.secureguard.vpn-service"
HELPER_TOOLS_DIR="/Library/PrivilegedHelperTools"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
APPLICATION_SUPPORT_DIR="/Library/Application Support/SecureGuard"
LOG_DIR="/var/log"
DATA_DIR="/var/lib/secureguard"
SOCKET_PATH="/var/run/secureguard.sock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Print banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║       SecureGuard VPN Service Uninstaller for macOS       ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    echo "Usage: sudo $0"
    exit 1
fi

# Parse arguments
REMOVE_DATA=false
REMOVE_LOGS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            REMOVE_DATA=true
            REMOVE_LOGS=true
            shift
            ;;
        --data)
            REMOVE_DATA=true
            shift
            ;;
        --logs)
            REMOVE_LOGS=true
            shift
            ;;
        -h|--help)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all     Remove everything including data and logs"
            echo "  --data    Remove data directory (/var/lib/secureguard)"
            echo "  --logs    Remove log files (/var/log/secureguard*.log)"
            echo "  -h, --help  Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Stop the service
stop_service() {
    if launchctl list 2>/dev/null | grep -q "$SERVICE_NAME"; then
        log_info "Stopping service..."
        # Try modern bootout first, fall back to legacy unload
        launchctl bootout system/"$SERVICE_NAME" 2>/dev/null || \
        launchctl unload "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" 2>/dev/null || true
        sleep 2
    else
        log_info "Service not currently running"
    fi
}

# Remove plist
remove_plist() {
    if [ -f "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist" ]; then
        log_info "Removing LaunchDaemon plist..."
        rm -f "$LAUNCH_DAEMONS_DIR/$SERVICE_NAME.plist"
    fi
}

# Remove binary
remove_binary() {
    if [ -f "$HELPER_TOOLS_DIR/secureguard-service" ]; then
        log_info "Removing binary..."
        rm -f "$HELPER_TOOLS_DIR/secureguard-service"
    fi
}

# Remove socket
remove_socket() {
    if [ -S "$SOCKET_PATH" ]; then
        log_info "Removing socket..."
        rm -f "$SOCKET_PATH"
    fi
}

# Remove application support
remove_app_support() {
    if [ -d "$APPLICATION_SUPPORT_DIR" ]; then
        log_info "Removing application support directory..."
        rm -rf "$APPLICATION_SUPPORT_DIR"
    fi
}

# Remove data (optional)
remove_data() {
    if [ "$REMOVE_DATA" = true ] && [ -d "$DATA_DIR" ]; then
        log_info "Removing data directory..."
        rm -rf "$DATA_DIR"
    fi
}

# Remove logs (optional)
remove_logs() {
    if [ "$REMOVE_LOGS" = true ]; then
        log_info "Removing log files..."
        rm -f "$LOG_DIR/secureguard.log" "$LOG_DIR/secureguard.error.log"
    fi
}

# Print completion message
print_completion() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           Uninstallation Complete Successfully!           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    if [ "$REMOVE_DATA" = false ]; then
        echo "Note: Data directory preserved at $DATA_DIR"
        echo "      To remove: sudo rm -rf $DATA_DIR"
        echo ""
    fi

    if [ "$REMOVE_LOGS" = false ]; then
        echo "Note: Log files preserved at $LOG_DIR/secureguard*.log"
        echo "      To remove: sudo rm -f $LOG_DIR/secureguard*.log"
        echo ""
    fi

    echo "To completely remove all traces, run:"
    echo "  sudo $0 --all"
    echo ""
}

# Main uninstallation flow
main() {
    stop_service
    remove_plist
    remove_binary
    remove_socket
    remove_app_support
    remove_data
    remove_logs
    print_completion
}

# Run main
main "$@"
