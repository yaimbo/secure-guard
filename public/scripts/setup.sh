#!/bin/bash
# =============================================================================
# SecureGuard VPN Server - Setup Wizard
# =============================================================================
#
# This script guides you through setting up SecureGuard VPN Server:
# 1. Checks prerequisites (Docker, Docker Compose)
# 2. Prompts for configuration values
# 3. Generates secure random secrets
# 4. Creates .env file from template
# 5. Pulls and starts all containers
#
# Usage:
#   ./install.sh                    # Interactive setup
#   ./install.sh --non-interactive  # Use defaults/env vars (for CI/CD)
#
# =============================================================================

set -e

# Version
VERSION="1.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Banner
print_banner() {
    echo ""
    echo -e "${CYAN}"
    echo "   ____                           ____                     _ "
    echo "  / ___|  ___  ___ _   _ _ __ ___/ ___|_   _  __ _ _ __ __| |"
    echo "  \\___ \\ / _ \\/ __| | | | '__/ _ \\ |  _| | | |/ _\` | '__/ _\` |"
    echo "   ___) |  __/ (__| |_| | | |  __/ |_| | |_| | (_| | | | (_| |"
    echo "  |____/ \\___|\\___|\\__,_|_|  \\___|\\____|\\__,_|\\__,_|_|  \\__,_|"
    echo -e "${NC}"
    echo -e "  ${GREEN}Enterprise WireGuard VPN Server${NC}  v${VERSION}"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        echo ""
        echo "  Install Docker:"
        echo "    curl -fsSL https://get.docker.com | sh"
        echo ""
        exit 1
    fi
    log_success "Docker found: $(docker --version | cut -d' ' -f3 | tr -d ',')"

    # Check Docker Compose (v2 or standalone)
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
        log_success "Docker Compose found: $(docker compose version --short)"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
        log_success "Docker Compose found: $(docker-compose --version | cut -d' ' -f3 | tr -d ',')"
    else
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    log_success "Docker daemon is running"

    # Check for openssl
    if ! command -v openssl &> /dev/null; then
        log_error "OpenSSL is not installed. Please install OpenSSL first."
        exit 1
    fi
    log_success "OpenSSL found"

    echo ""
}

# Generate random secret
generate_secret() {
    openssl rand -base64 "$1" | tr -d '\n'
}

# Prompt for input with default
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -p "$prompt: " value
    fi

    eval "$var_name='$value'"
}

# Validate domain
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Validate email
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Validate IP address
validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    return 0
}

# Interactive configuration
interactive_config() {
    log_info "Starting interactive configuration..."
    echo ""

    # Domain
    while true; do
        prompt_with_default "Enter your domain (e.g., vpn.company.com)" "" DOMAIN
        if validate_domain "$DOMAIN"; then
            break
        else
            log_error "Invalid domain format. Please try again."
        fi
    done

    # Email
    while true; do
        prompt_with_default "Enter your email for Let's Encrypt" "admin@$DOMAIN" ACME_EMAIL
        if validate_email "$ACME_EMAIL"; then
            break
        else
            log_error "Invalid email format. Please try again."
        fi
    done

    # Public IP
    # Try to auto-detect
    DETECTED_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -s --connect-timeout 5 icanhazip.com 2>/dev/null || echo "")
    while true; do
        prompt_with_default "Enter your server's public IP" "$DETECTED_IP" VPN_PUBLIC_IP
        if validate_ip "$VPN_PUBLIC_IP"; then
            break
        else
            log_error "Invalid IP address format. Please try again."
        fi
    done

    # Monitoring
    echo ""
    read -p "Enable monitoring stack (Prometheus + Grafana)? [y/N]: " ENABLE_MONITORING
    ENABLE_MONITORING="${ENABLE_MONITORING:-n}"

    if [[ "$ENABLE_MONITORING" =~ ^[Yy]$ ]]; then
        prompt_with_default "Enter Grafana subdomain" "grafana.$DOMAIN" GRAFANA_DOMAIN
    else
        GRAFANA_DOMAIN="grafana.localhost"
    fi

    echo ""
}

# Generate secrets
generate_secrets() {
    log_info "Generating secure secrets..."

    # Create secrets directory
    mkdir -p "$INSTALL_DIR/secrets"

    # Generate each secret
    echo "$(generate_secret 32)" > "$INSTALL_DIR/secrets/db_password.txt"
    echo "$(generate_secret 32)" > "$INSTALL_DIR/secrets/redis_password.txt"
    echo "$(generate_secret 64)" > "$INSTALL_DIR/secrets/jwt_secret.txt"
    echo "$(generate_secret 32)" > "$INSTALL_DIR/secrets/encryption_key.txt"
    echo "$(generate_secret 32)" > "$INSTALL_DIR/secrets/grafana_admin_password.txt"

    # Set permissions (readable by containers)
    chmod 644 "$INSTALL_DIR/secrets/"*.txt

    log_success "Secrets generated in secrets/"
}

# Configure system for VPN
configure_system() {
    log_info "Configuring system for VPN..."

    # Enable IP forwarding (required for VPN routing)
    if [ -f /proc/sys/net/ipv4/ip_forward ]; then
        echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
        echo 1 | sudo tee /proc/sys/net/ipv4/conf/all/src_valid_mark > /dev/null
        echo 1 | sudo tee /proc/sys/net/ipv6/conf/all/forwarding > /dev/null 2>&1 || true
        log_success "IP forwarding enabled"
    fi

    # Make persistent across reboots
    if [ -d /etc/sysctl.d ]; then
        cat << EOF | sudo tee /etc/sysctl.d/99-secureguard.conf > /dev/null
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv6.conf.all.forwarding = 1
EOF
        log_success "Sysctl configuration persisted"
    fi
}

# Create .env file
create_env_file() {
    log_info "Creating .env configuration file..."

    cat > "$INSTALL_DIR/.env" << EOF
# =============================================================================
# SecureGuard VPN Configuration
# Generated by setup.sh on $(date)
# =============================================================================

# Domain & Email (required)
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
VPN_PUBLIC_IP=$VPN_PUBLIC_IP

# Ports (optional - these are the defaults)
HTTP_PORT=80
HTTPS_PORT=443
VPN_UDP_PORT=51820

# Monitoring subdomain
GRAFANA_DOMAIN=$GRAFANA_DOMAIN

# Image version (leave as 'latest' for auto-updates)
VERSION=latest

# Watchtower auto-updates (daily at 4am UTC)
WATCHTOWER_SCHEDULE=0 0 4 * * *

# Timezone
TZ=UTC
EOF

    log_success "Configuration saved to .env"
}

# Pull and start containers
start_containers() {
    log_info "Pulling SecureGuard images from Docker Hub..."
    echo ""

    cd "$INSTALL_DIR"

    if [[ "$ENABLE_MONITORING" =~ ^[Yy]$ ]]; then
        $COMPOSE_CMD --profile monitoring pull
        echo ""
        log_info "Starting containers with monitoring stack..."
        $COMPOSE_CMD --profile monitoring up -d
    else
        $COMPOSE_CMD pull
        echo ""
        log_info "Starting containers..."
        $COMPOSE_CMD up -d
    fi

    echo ""
    log_success "Containers started successfully!"
}

# Wait for health checks
wait_for_health() {
    log_info "Waiting for services to become healthy..."

    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "https://$DOMAIN/health" > /dev/null 2>&1; then
            echo ""
            log_success "All services are healthy!"
            return 0
        fi

        # Also try HTTP in case HTTPS isn't ready yet
        if curl -sf "http://$DOMAIN/health" > /dev/null 2>&1; then
            log_success "Services responding (waiting for HTTPS certificate)..."
        fi

        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    echo ""
    log_warning "Services may still be starting. Check with: docker compose logs -f"
    return 1
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                      Setup Complete!                              ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Access your SecureGuard console at:${NC}"
    echo -e "  ${GREEN}https://$DOMAIN${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "  1. Create your first admin account at the setup screen"
    echo "  2. Add VPN clients through the web console"
    echo "  3. Download client configs and connect"
    echo ""

    if [[ "$ENABLE_MONITORING" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Grafana dashboard:${NC}"
        echo -e "  ${GREEN}https://$GRAFANA_DOMAIN${NC}"
        echo -e "  Username: admin"
        echo -e "  Password: $(cat "$INSTALL_DIR/secrets/grafana_admin_password.txt")"
        echo ""
    fi

    echo -e "${BLUE}Useful commands:${NC}"
    echo "  View logs:     docker compose logs -f"
    echo "  Stop:          docker compose down"
    echo "  Backup:        ./scripts/backup.sh"
    echo "  Restore:       ./scripts/restore.sh <backup-file>"
    echo ""

    echo -e "${YELLOW}Important:${NC}"
    echo "  - Ensure UDP port 51820 is open in your firewall"
    echo "  - Ensure TCP ports 80 and 443 are open for web access"
    echo "  - Backup your secrets/ directory regularly"
    echo ""
}

# Main
main() {
    print_banner
    check_prerequisites

    # Parse arguments
    NON_INTERACTIVE=false
    for arg in "$@"; do
        case $arg in
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --version|-v)
                echo "SecureGuard VPN v${VERSION}"
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --non-interactive  Use environment variables (for CI/CD)"
                echo "  --version, -v      Show version"
                echo "  --help, -h         Show this help"
                echo ""
                echo "Environment variables (for --non-interactive):"
                echo "  DOMAIN             Your VPN server domain"
                echo "  ACME_EMAIL         Email for Let's Encrypt"
                echo "  VPN_PUBLIC_IP      Server's public IP address"
                echo "  ENABLE_MONITORING  Enable Prometheus/Grafana (y/n)"
                echo "  GRAFANA_DOMAIN     Grafana subdomain"
                exit 0
                ;;
        esac
    done

    if [ "$NON_INTERACTIVE" = true ]; then
        log_info "Running in non-interactive mode..."
        # Use environment variables or defaults
        DOMAIN="${DOMAIN:-localhost}"
        ACME_EMAIL="${ACME_EMAIL:-admin@localhost}"
        VPN_PUBLIC_IP="${VPN_PUBLIC_IP:-127.0.0.1}"
        GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-grafana.localhost}"
        ENABLE_MONITORING="${ENABLE_MONITORING:-n}"
    else
        interactive_config
    fi

    generate_secrets
    create_env_file
    configure_system
    start_containers
    wait_for_health
    print_summary
}

# Run main
main "$@"
