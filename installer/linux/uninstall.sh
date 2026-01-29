#!/bin/bash
# SecureGuard VPN Service Uninstaller for Linux
# This script removes the daemon service and cleans up

set -euo pipefail

# Configuration
SERVICE_NAME="secureguard"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
DATA_DIR="/var/lib/secureguard"
RUN_DIR="/var/run/secureguard"
LOG_DIR="/var/log/secureguard"
SOCKET_PATH="$RUN_DIR/secureguard.sock"

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
echo "║       SecureGuard VPN Service Uninstaller for Linux       ║"
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
            echo "  --logs    Remove log directory (/var/log/secureguard)"
            echo "  -h, --help  Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Stop and disable service
stop_service() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping service..."
        systemctl stop "$SERVICE_NAME" || true
        sleep 2
    else
        log_info "Service not currently running"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "Disabling service..."
        systemctl disable "$SERVICE_NAME" || true
    fi
}

# Remove systemd service file
remove_service() {
    if [ -f "$SYSTEMD_DIR/secureguard.service" ]; then
        log_info "Removing systemd service..."
        rm -f "$SYSTEMD_DIR/secureguard.service"
        systemctl daemon-reload
    fi
}

# Remove binary
remove_binary() {
    if [ -f "$INSTALL_DIR/secureguard-service" ]; then
        log_info "Removing binary..."
        rm -f "$INSTALL_DIR/secureguard-service"
    fi
}

# Remove socket and runtime directory
remove_runtime() {
    if [ -S "$SOCKET_PATH" ]; then
        log_info "Removing socket..."
        rm -f "$SOCKET_PATH"
    fi

    if [ -d "$RUN_DIR" ]; then
        log_info "Removing runtime directory..."
        rm -rf "$RUN_DIR"
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
    if [ "$REMOVE_LOGS" = true ] && [ -d "$LOG_DIR" ]; then
        log_info "Removing log directory..."
        rm -rf "$LOG_DIR"
    fi
}

# Print completion message
print_completion() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           Uninstallation Complete Successfully!           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    if [ "$REMOVE_DATA" = false ] && [ -d "$DATA_DIR" ]; then
        echo "Note: Data directory preserved at $DATA_DIR"
        echo "      To remove: sudo rm -rf $DATA_DIR"
        echo ""
    fi

    if [ "$REMOVE_LOGS" = false ] && [ -d "$LOG_DIR" ]; then
        echo "Note: Log directory preserved at $LOG_DIR"
        echo "      To remove: sudo rm -rf $LOG_DIR"
        echo ""
    fi

    echo "To completely remove all traces, run:"
    echo "  sudo $0 --all"
    echo ""
}

# Main uninstallation flow
main() {
    stop_service
    remove_service
    remove_binary
    remove_runtime
    remove_data
    remove_logs
    print_completion
}

# Run main
main "$@"
