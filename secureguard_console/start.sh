#!/bin/bash

# SecureGuard Console Startup Script
# Kills existing processes and starts both the API server and Flutter web console

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$PROJECT_ROOT/secureguard-server"
CONSOLE_DIR="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}SecureGuard Console Startup${NC}"
echo "================================"

# Function to kill processes on a specific port
kill_port() {
    local port=$1
    local pids=$(lsof -ti :$port 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo -e "${YELLOW}Killing existing processes on port $port...${NC}"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

# Function to kill processes by name pattern
kill_by_pattern() {
    local pattern=$1
    local pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo -e "${YELLOW}Killing existing $pattern processes...${NC}"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

# Kill existing instances
echo -e "\n${YELLOW}Stopping existing services...${NC}"

# Kill any process on port 8080 (API server)
kill_port 8080

# Kill any process on port 5000 (Flutter web dev server default)
kill_port 5000

# Kill any flutter run processes for this project
kill_by_pattern "flutter.*secureguard_console"

# Kill any dart server processes for this project
kill_by_pattern "dart.*secureguard-server"

echo -e "${GREEN}Existing services stopped.${NC}"

# Check if server directory exists
if [ ! -d "$SERVER_DIR" ]; then
    echo -e "${RED}Error: Server directory not found at $SERVER_DIR${NC}"
    exit 1
fi

# Check if console directory exists
if [ ! -d "$CONSOLE_DIR" ]; then
    echo -e "${RED}Error: Console directory not found at $CONSOLE_DIR${NC}"
    exit 1
fi

# Start the Dart API server
echo -e "\n${YELLOW}Starting Dart API server...${NC}"
cd "$SERVER_DIR"

# Get dependencies if needed
if [ ! -d ".dart_tool" ]; then
    echo "Running dart pub get for server..."
    dart pub get
fi

# Start server in background
dart run bin/server.dart > /tmp/secureguard-server.log 2>&1 &
SERVER_PID=$!
echo -e "${GREEN}API server started (PID: $SERVER_PID)${NC}"
echo "Server logs: /tmp/secureguard-server.log"

# Wait for server to be ready
echo "Waiting for API server to be ready..."
for i in {1..30}; do
    if curl -s http://localhost:8080/api/v1/health > /dev/null 2>&1; then
        echo -e "${GREEN}API server is ready!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${YELLOW}Warning: API server may not be fully ready yet${NC}"
    fi
    sleep 1
done

# Start the Flutter web console
echo -e "\n${YELLOW}Starting Flutter web console...${NC}"
cd "$CONSOLE_DIR"

# Get dependencies if needed
if [ ! -d ".dart_tool" ]; then
    echo "Running flutter pub get for console..."
    flutter pub get
fi

# Start Flutter web in Chrome
echo -e "${GREEN}Launching Flutter web console in Chrome...${NC}"
flutter run -d chrome --dart-define=API_URL=http://localhost:8080/api/v1

# When Flutter exits, clean up the server
echo -e "\n${YELLOW}Shutting down API server...${NC}"
kill $SERVER_PID 2>/dev/null || true
echo -e "${GREEN}Done.${NC}"
