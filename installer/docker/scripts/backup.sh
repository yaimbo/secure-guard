#!/bin/bash
# =============================================================================
# SecureGuard Backup Script
# =============================================================================
#
# Creates a complete backup of all SecureGuard data:
# - PostgreSQL database dump
# - Redis data
# - Configuration files
# - Docker secrets
# - Let's Encrypt certificates (Caddy data)
#
# Usage:
#   ./scripts/backup.sh                     # Backup to default location
#   ./scripts/backup.sh /custom/backup/dir  # Backup to custom location
#
# Backups are timestamped and compressed.
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

# Backup settings
BACKUP_BASE="${1:-$DOCKER_DIR/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_BASE/secureguard_$TIMESTAMP"

# Docker Compose command
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Create backup directory
create_backup_dir() {
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
}

# Backup PostgreSQL
backup_postgres() {
    log_info "Backing up PostgreSQL database..."

    cd "$DOCKER_DIR"

    # Check if container is running
    if ! $COMPOSE_CMD ps postgres | grep -q "running"; then
        log_error "PostgreSQL container is not running!"
        return 1
    fi

    # Dump database
    $COMPOSE_CMD exec -T postgres pg_dump -U secureguard -Fc secureguard > "$BACKUP_DIR/postgres.dump"

    # Also create SQL dump for readability
    $COMPOSE_CMD exec -T postgres pg_dump -U secureguard secureguard | gzip > "$BACKUP_DIR/postgres.sql.gz"

    log_success "PostgreSQL backup complete ($(du -sh "$BACKUP_DIR/postgres.dump" | cut -f1))"
}

# Backup Redis
backup_redis() {
    log_info "Backing up Redis data..."

    cd "$DOCKER_DIR"

    # Check if container is running
    if ! $COMPOSE_CMD ps redis | grep -q "running"; then
        log_warning "Redis container is not running, skipping..."
        return 0
    fi

    # Trigger BGSAVE
    $COMPOSE_CMD exec -T redis redis-cli BGSAVE > /dev/null 2>&1 || true
    sleep 2

    # Copy RDB file
    REDIS_CONTAINER=$($COMPOSE_CMD ps -q redis)
    docker cp "$REDIS_CONTAINER:/data/dump.rdb" "$BACKUP_DIR/redis.rdb" 2>/dev/null || {
        log_warning "No Redis dump file found (may be empty)"
        return 0
    }

    log_success "Redis backup complete ($(du -sh "$BACKUP_DIR/redis.rdb" | cut -f1))"
}

# Backup configuration
backup_config() {
    log_info "Backing up configuration files..."

    # Copy .env
    if [ -f "$DOCKER_DIR/.env" ]; then
        cp "$DOCKER_DIR/.env" "$BACKUP_DIR/"
        log_success "Backed up .env"
    fi

    # Copy secrets
    if [ -d "$DOCKER_DIR/secrets" ]; then
        cp -r "$DOCKER_DIR/secrets" "$BACKUP_DIR/"
        log_success "Backed up secrets/"
    fi

    # Copy Caddyfile
    if [ -f "$DOCKER_DIR/Caddyfile" ]; then
        cp "$DOCKER_DIR/Caddyfile" "$BACKUP_DIR/"
        log_success "Backed up Caddyfile"
    fi

    # Copy custom configs
    if [ -d "$DOCKER_DIR/config" ]; then
        cp -r "$DOCKER_DIR/config" "$BACKUP_DIR/"
        log_success "Backed up config/"
    fi
}

# Backup Caddy certificates
backup_caddy() {
    log_info "Backing up Let's Encrypt certificates..."

    cd "$DOCKER_DIR"

    # Check if container is running
    if ! $COMPOSE_CMD ps caddy | grep -q "running"; then
        log_warning "Caddy container is not running, skipping certificates..."
        return 0
    fi

    # Copy Caddy data (contains certificates)
    CADDY_CONTAINER=$($COMPOSE_CMD ps -q caddy)
    docker cp "$CADDY_CONTAINER:/data" "$BACKUP_DIR/caddy_data" 2>/dev/null || {
        log_warning "No Caddy data found"
        return 0
    }

    log_success "Caddy certificates backup complete"
}

# Create archive
create_archive() {
    log_info "Creating compressed archive..."

    cd "$BACKUP_BASE"
    ARCHIVE_NAME="secureguard_$TIMESTAMP.tar.gz"

    tar -czf "$ARCHIVE_NAME" "secureguard_$TIMESTAMP"

    log_success "Archive created: $BACKUP_BASE/$ARCHIVE_NAME"
    echo ""
    echo "Archive size: $(du -sh "$BACKUP_BASE/$ARCHIVE_NAME" | cut -f1)"
}

# Cleanup old backups (keep last 7)
cleanup_old_backups() {
    log_info "Cleaning up old backups (keeping last 7)..."

    cd "$BACKUP_BASE"

    # Count backups
    BACKUP_COUNT=$(ls -1 secureguard_*.tar.gz 2>/dev/null | wc -l)

    if [ "$BACKUP_COUNT" -gt 7 ]; then
        # Remove oldest backups
        ls -1t secureguard_*.tar.gz | tail -n +8 | xargs rm -f
        log_success "Removed $(($BACKUP_COUNT - 7)) old backup(s)"
    else
        log_info "No old backups to remove"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   Backup Complete!                            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Backup location: $BACKUP_BASE/secureguard_$TIMESTAMP.tar.gz"
    echo ""
    echo "Contents:"
    echo "  - postgres.dump      PostgreSQL binary dump"
    echo "  - postgres.sql.gz    PostgreSQL SQL dump (compressed)"
    echo "  - redis.rdb          Redis snapshot"
    echo "  - .env               Environment configuration"
    echo "  - secrets/           Docker secrets"
    echo "  - caddy_data/        Let's Encrypt certificates"
    echo "  - config/            Custom configurations"
    echo ""
    echo -e "To restore: ${BLUE}./scripts/restore.sh $BACKUP_DIR${NC}"
    echo ""
}

# Main
main() {
    echo ""
    echo -e "${BLUE}SecureGuard Backup${NC}"
    echo "===================="
    echo ""

    create_backup_dir
    backup_postgres
    backup_redis
    backup_config
    backup_caddy
    create_archive
    cleanup_old_backups
    print_summary
}

main "$@"
