#!/bin/bash
# =============================================================================
# MinnowVPN Restore Script
# =============================================================================
#
# Restores MinnowVPN from a backup:
# - PostgreSQL database
# - Redis data
# - Configuration files
# - Docker secrets
# - Let's Encrypt certificates
#
# Usage:
#   ./scripts/restore.sh <backup-dir>
#   ./scripts/restore.sh /path/to/minnowvpn_20240101_120000.tar.gz
#
# WARNING: This will overwrite existing data!
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"

# Docker Compose command
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Check arguments
if [ -z "$1" ]; then
    log_error "Usage: $0 <backup-dir-or-archive>"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/minnowvpn_20240101_120000"
    echo "  $0 /path/to/minnowvpn_20240101_120000.tar.gz"
    exit 1
fi

BACKUP_PATH="$1"

# Extract archive if needed
prepare_backup() {
    if [[ "$BACKUP_PATH" == *.tar.gz ]]; then
        log_info "Extracting backup archive..."
        TEMP_DIR=$(mktemp -d)
        tar -xzf "$BACKUP_PATH" -C "$TEMP_DIR"
        BACKUP_DIR="$TEMP_DIR/$(ls "$TEMP_DIR")"
    else
        BACKUP_DIR="$BACKUP_PATH"
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi

    log_success "Backup directory: $BACKUP_DIR"
}

# Confirm restore
confirm_restore() {
    echo ""
    echo -e "${YELLOW}WARNING: This will overwrite existing data!${NC}"
    echo ""
    echo "The following will be restored:"
    [ -f "$BACKUP_DIR/postgres.dump" ] && echo "  - PostgreSQL database"
    [ -f "$BACKUP_DIR/redis.rdb" ] && echo "  - Redis data"
    [ -f "$BACKUP_DIR/.env" ] && echo "  - Environment configuration"
    [ -d "$BACKUP_DIR/secrets" ] && echo "  - Docker secrets"
    [ -d "$BACKUP_DIR/caddy_data" ] && echo "  - Let's Encrypt certificates"
    [ -d "$BACKUP_DIR/config" ] && echo "  - Custom configurations"
    echo ""

    read -p "Are you sure you want to continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Restore cancelled."
        exit 0
    fi
}

# Stop containers
stop_containers() {
    log_info "Stopping containers..."
    cd "$DOCKER_DIR"
    $COMPOSE_CMD down --remove-orphans 2>/dev/null || true
}

# Restore configuration
restore_config() {
    log_info "Restoring configuration files..."

    # Restore .env
    if [ -f "$BACKUP_DIR/.env" ]; then
        cp "$BACKUP_DIR/.env" "$DOCKER_DIR/.env"
        log_success "Restored .env"
    fi

    # Restore secrets
    if [ -d "$BACKUP_DIR/secrets" ]; then
        rm -rf "$DOCKER_DIR/secrets"
        cp -r "$BACKUP_DIR/secrets" "$DOCKER_DIR/"
        chmod 600 "$DOCKER_DIR/secrets/"*.txt
        log_success "Restored secrets/"
    fi

    # Restore Caddyfile
    if [ -f "$BACKUP_DIR/Caddyfile" ]; then
        cp "$BACKUP_DIR/Caddyfile" "$DOCKER_DIR/"
        log_success "Restored Caddyfile"
    fi

    # Restore custom configs
    if [ -d "$BACKUP_DIR/config" ]; then
        cp -r "$BACKUP_DIR/config/"* "$DOCKER_DIR/config/" 2>/dev/null || true
        log_success "Restored config/"
    fi
}

# Start infrastructure containers
start_infrastructure() {
    log_info "Starting infrastructure containers..."
    cd "$DOCKER_DIR"
    $COMPOSE_CMD up -d postgres redis

    # Wait for PostgreSQL
    log_info "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if $COMPOSE_CMD exec -T postgres pg_isready -U minnowvpn > /dev/null 2>&1; then
            log_success "PostgreSQL is ready"
            break
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
}

# Restore PostgreSQL
restore_postgres() {
    if [ -f "$BACKUP_DIR/postgres.dump" ]; then
        log_info "Restoring PostgreSQL database..."

        cd "$DOCKER_DIR"

        # Drop and recreate database
        $COMPOSE_CMD exec -T postgres psql -U minnowvpn -d postgres -c "DROP DATABASE IF EXISTS minnowvpn;" 2>/dev/null || true
        $COMPOSE_CMD exec -T postgres psql -U minnowvpn -d postgres -c "CREATE DATABASE minnowvpn;" 2>/dev/null || true

        # Restore from binary dump
        cat "$BACKUP_DIR/postgres.dump" | $COMPOSE_CMD exec -T postgres pg_restore -U minnowvpn -d minnowvpn --no-owner --no-privileges 2>/dev/null || {
            # If binary restore fails, try SQL dump
            if [ -f "$BACKUP_DIR/postgres.sql.gz" ]; then
                log_warning "Binary restore failed, trying SQL dump..."
                gunzip -c "$BACKUP_DIR/postgres.sql.gz" | $COMPOSE_CMD exec -T postgres psql -U minnowvpn -d minnowvpn
            fi
        }

        log_success "PostgreSQL database restored"
    else
        log_warning "No PostgreSQL backup found, skipping..."
    fi
}

# Restore Redis
restore_redis() {
    if [ -f "$BACKUP_DIR/redis.rdb" ]; then
        log_info "Restoring Redis data..."

        cd "$DOCKER_DIR"

        # Stop Redis
        $COMPOSE_CMD stop redis

        # Copy RDB file
        REDIS_CONTAINER=$($COMPOSE_CMD ps -q redis)
        docker cp "$BACKUP_DIR/redis.rdb" "$REDIS_CONTAINER:/data/dump.rdb"

        # Start Redis
        $COMPOSE_CMD start redis

        log_success "Redis data restored"
    else
        log_warning "No Redis backup found, skipping..."
    fi
}

# Restore Caddy certificates
restore_caddy() {
    if [ -d "$BACKUP_DIR/caddy_data" ]; then
        log_info "Restoring Let's Encrypt certificates..."

        cd "$DOCKER_DIR"

        # Start Caddy briefly to get container
        $COMPOSE_CMD up -d caddy
        sleep 2

        # Copy data
        CADDY_CONTAINER=$($COMPOSE_CMD ps -q caddy)
        docker cp "$BACKUP_DIR/caddy_data/." "$CADDY_CONTAINER:/data/"

        # Restart Caddy
        $COMPOSE_CMD restart caddy

        log_success "Certificates restored"
    else
        log_warning "No Caddy certificates found, will obtain new ones..."
    fi
}

# Start all containers
start_all_containers() {
    log_info "Starting all containers..."
    cd "$DOCKER_DIR"

    # Check if monitoring profile was used
    if grep -q "GRAFANA_DOMAIN" "$DOCKER_DIR/.env" 2>/dev/null; then
        GRAFANA_DOMAIN=$(grep "GRAFANA_DOMAIN" "$DOCKER_DIR/.env" | cut -d'=' -f2)
        if [ -n "$GRAFANA_DOMAIN" ] && [ "$GRAFANA_DOMAIN" != "grafana.localhost" ]; then
            $COMPOSE_CMD --profile monitoring up -d
        else
            $COMPOSE_CMD up -d
        fi
    else
        $COMPOSE_CMD up -d
    fi

    log_success "All containers started"
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   Restore Complete!                           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "MinnowVPN has been restored from backup."
    echo ""
    echo "Next steps:"
    echo "  1. Check container status: docker compose ps"
    echo "  2. View logs: docker compose logs -f"
    echo "  3. Access console: https://$(grep DOMAIN "$DOCKER_DIR/.env" | cut -d'=' -f2)"
    echo ""
}

# Cleanup
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Main
main() {
    echo ""
    echo -e "${BLUE}MinnowVPN Restore${NC}"
    echo "===================="
    echo ""

    prepare_backup
    confirm_restore
    stop_containers
    restore_config
    start_infrastructure
    restore_postgres
    restore_redis
    start_all_containers
    restore_caddy
    print_summary
}

main "$@"
