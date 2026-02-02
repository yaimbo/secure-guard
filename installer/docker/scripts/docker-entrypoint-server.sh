#!/bin/bash
# =============================================================================
# MinnowVPN Dart Server - Docker Entrypoint
# =============================================================================
#
# This script handles Docker secrets by converting _FILE environment variables
# to their regular counterparts before starting the server.
#
# For example:
#   DB_PASSWORD_FILE=/run/secrets/db_password
#   becomes:
#   DB_PASSWORD=<contents of /run/secrets/db_password>
#
# =============================================================================

set -e

# Function to read secret from file
read_secret() {
    local var_name="$1"
    local file_var="${var_name}_FILE"
    local file_path="${!file_var}"

    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        # Read secret from file, trim whitespace
        export "$var_name"="$(cat "$file_path" | tr -d '\n\r')"
        echo "[entrypoint] Loaded secret from $file_var"
    elif [ -z "${!var_name}" ]; then
        echo "[entrypoint] Warning: Neither $var_name nor $file_var is set"
    fi
}

# Read all secrets from files
read_secret "DB_PASSWORD"
read_secret "REDIS_PASSWORD"
read_secret "JWT_SECRET"
read_secret "ENCRYPTION_KEY"

# Log startup info
echo "[entrypoint] Starting MinnowVPN API Server..."
echo "[entrypoint] Host: ${HOST:-0.0.0.0}:${PORT:-8080}"
echo "[entrypoint] Database: ${DB_HOST:-localhost}:${DB_PORT:-5432}/${DB_NAME:-minnowvpn}"
echo "[entrypoint] Redis: ${REDIS_HOST:-localhost}:${REDIS_PORT:-6379}"

# Execute the main command
exec "$@"
