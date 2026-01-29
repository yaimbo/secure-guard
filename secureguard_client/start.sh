#!/bin/bash
# SecureGuard VPN Client Startup Script
# Starts the Rust daemon and Flutter desktop client

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== SecureGuard VPN Client ===${NC}"
echo ""

# Kill any existing instances
echo -e "${YELLOW}Stopping any existing instances...${NC}"

# Kill existing Rust daemon
if pgrep -f "secureguard-poc.*--daemon" > /dev/null 2>&1; then
    echo "  Stopping existing daemon..."
    sudo pkill -f "secureguard-poc.*--daemon" 2>/dev/null || true
    sleep 1
fi

# Kill existing Flutter client
if pgrep -f "secureguard_client" > /dev/null 2>&1; then
    echo "  Stopping existing Flutter client..."
    pkill -f "secureguard_client" 2>/dev/null || true
    sleep 1
fi

# Check if Rust binary exists
RUST_BINARY="$PROJECT_ROOT/target/release/secureguard-poc"
if [ ! -f "$RUST_BINARY" ]; then
    echo -e "${YELLOW}Rust binary not found. Building...${NC}"
    cd "$PROJECT_ROOT"
    cargo build --release
fi

# Start the Rust daemon
echo -e "${GREEN}Starting Rust daemon...${NC}"
cd "$PROJECT_ROOT"

# Check if we need sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Note: Daemon requires root privileges for TUN device${NC}"
    sudo "$RUST_BINARY" --daemon &
else
    "$RUST_BINARY" --daemon &
fi

DAEMON_PID=$!
echo "  Daemon started (PID: $DAEMON_PID)"

# Wait for socket to be available
echo "  Waiting for daemon socket..."
for i in {1..10}; do
    if [ -S /var/run/secureguard.sock ]; then
        echo -e "  ${GREEN}Socket ready${NC}"
        break
    fi
    if [ $i -eq 10 ]; then
        echo -e "${RED}Error: Daemon socket not available after 10 seconds${NC}"
        exit 1
    fi
    sleep 1
done

# Start Flutter client
echo -e "${GREEN}Starting Flutter desktop client...${NC}"
cd "$SCRIPT_DIR"

# Get dependencies if needed
if [ ! -d ".dart_tool" ]; then
    echo "  Running flutter pub get..."
    flutter pub get
fi

# Detect platform and run
case "$(uname -s)" in
    Darwin)
        PLATFORM="macos"
        ;;
    Linux)
        PLATFORM="linux"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        PLATFORM="windows"
        ;;
    *)
        echo -e "${RED}Unsupported platform: $(uname -s)${NC}"
        exit 1
        ;;
esac

echo "  Platform: $PLATFORM"
flutter run -d "$PLATFORM" &
FLUTTER_PID=$!

echo ""
echo -e "${GREEN}=== SecureGuard VPN Started ===${NC}"
echo "  Daemon PID: $DAEMON_PID"
echo "  Flutter PID: $FLUTTER_PID"
echo ""
echo "Press Ctrl+C to stop all processes"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down...${NC}"

    # Kill Flutter client
    if kill -0 $FLUTTER_PID 2>/dev/null; then
        echo "  Stopping Flutter client..."
        kill $FLUTTER_PID 2>/dev/null || true
    fi

    # Kill daemon
    echo "  Stopping daemon..."
    sudo pkill -f "secureguard-poc.*--daemon" 2>/dev/null || true

    echo -e "${GREEN}Done${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Wait for Flutter to exit
wait $FLUTTER_PID 2>/dev/null || true

# If Flutter exits, cleanup
cleanup
