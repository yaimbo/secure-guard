#!/bin/bash
# SecureGuard VPN Client Stop Script
# Stops all running instances

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Stopping SecureGuard VPN...${NC}"

# Kill Flutter client
if pgrep -f "secureguard_client" > /dev/null 2>&1; then
    echo "  Stopping Flutter client..."
    pkill -f "secureguard_client" 2>/dev/null || true
else
    echo "  Flutter client not running"
fi

# Kill Rust daemon
if pgrep -f "secureguard-poc.*--daemon" > /dev/null 2>&1; then
    echo "  Stopping daemon (requires sudo)..."
    sudo pkill -f "secureguard-poc.*--daemon" 2>/dev/null || true
else
    echo "  Daemon not running"
fi

# Remove stale socket if exists
if [ -S /var/run/secureguard.sock ]; then
    echo "  Removing stale socket..."
    sudo rm -f /var/run/secureguard.sock 2>/dev/null || true
fi

echo -e "${GREEN}Done${NC}"
