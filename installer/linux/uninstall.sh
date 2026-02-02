#!/bin/bash
# MinnowVPN VPN Uninstaller for Linux
# This script removes the daemon service, client app, and cleans up

set -euo pipefail

# Configuration
SERVICE_NAME="minnowvpn"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
DATA_DIR="/var/lib/minnowvpn"
RUN_DIR="/var/run/minnowvpn"
LOG_DIR="/var/log/minnowvpn"
CLIENT_DIR="/opt/minnowvpn"
DESKTOP_FILE="/usr/share/applications/minnowvpn.desktop"
MINNOWVPN_GROUP="minnowvpn"

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
echo "=============================================================="
echo "             MinnowVPN Uninstaller for Linux                 "
echo "=============================================================="
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
REMOVE_CLIENT=true  # Default: remove client with daemon

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            REMOVE_DATA=true
            REMOVE_LOGS=true
            REMOVE_CLIENT=true
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
        --daemon-only)
            REMOVE_CLIENT=false
            shift
            ;;
        -h|--help)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --all          Remove everything including data and logs"
            echo "  --data         Remove data directory (/var/lib/minnowvpn)"
            echo "  --logs         Remove log directory (/var/log/minnowvpn)"
            echo "  --daemon-only  Only remove daemon, keep client app"
            echo "  -h, --help     Show this help message"
            echo ""
            echo "By default, removes both daemon and client but preserves data/logs."
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Stop Flutter desktop app if running
stop_app() {
    log_info "Checking for running MinnowVPN app..."

    # Kill any running MinnowVPN GUI processes
    if pkill -f "minnowvpn_client" 2>/dev/null; then
        log_info "Stopped minnowvpn_client"
        sleep 1
    fi

    if pkill -f "MinnowVPN" 2>/dev/null; then
        log_info "Stopped MinnowVPN"
        sleep 1
    fi
}

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
    if [ -f "$SYSTEMD_DIR/minnowvpn.service" ]; then
        log_info "Removing systemd service..."
        rm -f "$SYSTEMD_DIR/minnowvpn.service"
        systemctl daemon-reload
    fi
}

# Remove daemon binary
remove_daemon_binary() {
    if [ -f "$INSTALL_DIR/minnowvpn-service" ]; then
        log_info "Removing daemon binary..."
        rm -f "$INSTALL_DIR/minnowvpn-service"
    fi
}

# Remove client application
remove_client() {
    if [ "$REMOVE_CLIENT" = false ]; then
        return
    fi

    # Remove client symlink
    if [ -L "$INSTALL_DIR/minnowvpn" ]; then
        log_info "Removing client symlink..."
        rm -f "$INSTALL_DIR/minnowvpn"
    fi

    # Remove client application directory
    if [ -d "$CLIENT_DIR" ]; then
        log_info "Removing client application..."
        rm -rf "$CLIENT_DIR"
    fi

    # Remove desktop file
    if [ -f "$DESKTOP_FILE" ]; then
        log_info "Removing desktop file..."
        rm -f "$DESKTOP_FILE"
    fi

    # Also check for user-specific desktop entries
    for user_home in /home/*; do
        local user_desktop="$user_home/.local/share/applications/minnowvpn.desktop"
        if [ -f "$user_desktop" ]; then
            log_info "Removing user desktop entry: $user_desktop"
            rm -f "$user_desktop"
        fi
    done

    # Remove icons
    for size in 48 128 256; do
        local icon_path="/usr/share/icons/hicolor/${size}x${size}/apps/minnowvpn.png"
        if [ -f "$icon_path" ]; then
            rm -f "$icon_path"
        fi
    done
    log_info "Removed icons"

    # Update desktop database
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database /usr/share/applications 2>/dev/null || true
    fi

    # Update icon cache
    if command -v gtk-update-icon-cache &>/dev/null; then
        gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    fi
}

# Remove runtime directory
remove_runtime() {
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

# Remove group if empty
remove_group() {
    if [ "$REMOVE_DATA" = true ]; then
        if getent group "$MINNOWVPN_GROUP" > /dev/null 2>&1; then
            # Check if any users are still in the group
            local group_members
            group_members=$(getent group "$MINNOWVPN_GROUP" | cut -d: -f4)
            if [ -z "$group_members" ]; then
                log_info "Removing $MINNOWVPN_GROUP group..."
                groupdel "$MINNOWVPN_GROUP" 2>/dev/null || true
            else
                log_info "Group $MINNOWVPN_GROUP still has members, keeping it"
            fi
        fi
    fi
}

# Print completion message
print_completion() {
    echo ""
    echo "=============================================================="
    echo "           Uninstallation Complete Successfully!              "
    echo "=============================================================="
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
    stop_app
    stop_service
    remove_service
    remove_daemon_binary
    remove_client
    remove_runtime
    remove_data
    remove_logs
    remove_group
    print_completion
}

# Run main
main "$@"
