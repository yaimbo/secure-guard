# SecureGuard VPN

**Enterprise-grade WireGuard VPN server with web management console.**

SecureGuard VPN provides a complete VPN solution for organizations, featuring a modern web interface, SSO integration, and automated security hardening.

---

## Features

- **Modern WireGuard Protocol** - Fast, secure VPN using the latest cryptographic standards
- **Web Management Console** - Intuitive admin interface for client management
- **SSO Integration** - Azure AD, Okta, and Google Workspace authentication
- **Automatic HTTPS** - Let's Encrypt certificates with zero configuration
- **Built-in Monitoring** - Optional Prometheus/Grafana dashboards
- **Brute-Force Protection** - Fail2ban integration with automatic IP blocking
- **Multi-Architecture** - Runs on x86_64 and ARM64 servers
- **Automatic Updates** - Watchtower keeps your deployment current

---

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/YOUR_ORG/secureguard.git
cd secureguard

# 2. Run the installer
./install.sh

# 3. Access your VPN server
# Open https://your-domain.com in a browser
```

The installer will guide you through configuration and start all services automatically.

---

## Requirements

### Server

- **Operating System**: Ubuntu 22.04+, Debian 12+, or any modern Linux with Docker
- **CPU**: 1+ cores (2+ recommended for production)
- **RAM**: 2GB minimum (4GB+ recommended)
- **Storage**: 10GB minimum

### Network

| Port | Protocol | Purpose |
|------|----------|---------|
| 80 | TCP | HTTP (redirects to HTTPS) |
| 443 | TCP/UDP | HTTPS + HTTP/3 QUIC |
| 51820 | UDP | WireGuard VPN |

### DNS

A domain name with an A record pointing to your server's public IP address.

### Software

- **Docker** 24.0+ with Compose V2
- **OpenSSL** (for secret generation)

#### Install Docker (if needed)

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Log out and back in, then verify
docker --version
docker compose version
```

---

## Installation

### Interactive Setup

```bash
./install.sh
```

The setup wizard will prompt you for:

1. **Domain name** - Your VPN server's domain (e.g., `vpn.company.com`)
2. **Email address** - For Let's Encrypt certificate notifications
3. **Server IP** - Your server's public IP (auto-detected)
4. **Enable monitoring** - Optional Prometheus/Grafana stack

### Non-Interactive Setup (CI/CD)

```bash
export DOMAIN=vpn.company.com
export ACME_EMAIL=admin@company.com
export VPN_PUBLIC_IP=203.0.113.1

./install.sh --non-interactive
```

---

## Configuration

All configuration is stored in `.env`. The installer creates this file from `.env.example`.

### Required Settings

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN` | Your VPN domain | `vpn.company.com` |
| `ACME_EMAIL` | Let's Encrypt notification email | `admin@company.com` |
| `VPN_PUBLIC_IP` | Server's public IP address | `203.0.113.1` |

### Optional Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PORT` | `80` | HTTP port (for ACME challenges) |
| `HTTPS_PORT` | `443` | HTTPS port |
| `VPN_UDP_PORT` | `51820` | WireGuard UDP port |
| `GRAFANA_DOMAIN` | `grafana.localhost` | Grafana subdomain (monitoring only) |
| `TZ` | `UTC` | Timezone for logs |
| `VERSION` | `latest` | Docker image version to use |

### Secrets

Secrets are auto-generated during setup and stored in `secrets/`:

- `db_password.txt` - PostgreSQL database password
- `redis_password.txt` - Redis authentication
- `jwt_secret.txt` - JWT signing key
- `encryption_key.txt` - AES-256 encryption key
- `grafana_admin_password.txt` - Grafana admin password (if monitoring enabled)

> **Important**: Never commit the `secrets/` directory to version control.

---

## Architecture

```
                    Internet
                       │
                       ▼
              ┌────────────────┐
              │     Caddy      │ :443 (HTTPS)
              │ (Reverse Proxy)│ :80  (HTTP→HTTPS)
              └───────┬────────┘
                      │
         ┌────────────┼────────────┐
         ▼            ▼            ▼
    ┌─────────┐ ┌──────────┐ ┌──────────┐
    │   API   │ │  Console │ │  Grafana │
    │ (Dart)  │ │(Flutter) │ │(optional)│
    │  :8080  │ │   :80    │ │  :3000   │
    └────┬────┘ └──────────┘ └────┬─────┘
         │                        │
         ▼                        ▼
    ┌─────────┐              ┌──────────┐
    │   VPN   │              │Prometheus│
    │ Daemon  │ :51820/udp   │(optional)│
    │ (Rust)  │              └──────────┘
    └────┬────┘
         │
    ┌────┴────┐
    ▼         ▼
┌────────┐ ┌───────┐
│Postgres│ │ Redis │
│  :5432 │ │ :6379 │
└────────┘ └───────┘
```

### Services

| Service | Description |
|---------|-------------|
| **postgres** | PostgreSQL 15 database for configuration and audit logs |
| **redis** | Redis 7 for caching and real-time event streaming |
| **dart-server** | REST API server for client management |
| **flutter-console** | Web management interface |
| **vpn-daemon** | WireGuard VPN server (Rust) |
| **caddy** | HTTPS reverse proxy with automatic certificates |
| **watchtower** | Automatic container updates |
| **fail2ban** | Brute-force protection |

### Monitoring Stack (Optional)

Enable with `--profile monitoring` flag during setup:

| Service | Description |
|---------|-------------|
| **prometheus** | Metrics collection |
| **grafana** | Dashboards and visualization |
| **node-exporter** | Host system metrics |
| **redis-exporter** | Redis metrics |
| **postgres-exporter** | PostgreSQL metrics |

---

## Administration

### Service Management

```bash
# View running services
docker compose ps

# View logs
docker compose logs -f              # All services
docker compose logs -f dart-server  # Specific service

# Restart a service
docker compose restart dart-server

# Stop all services
docker compose down

# Start all services
docker compose up -d

# Start with monitoring
docker compose --profile monitoring up -d
```

### Backup

Create a full backup of all data:

```bash
./scripts/backup.sh
```

Backups include:
- PostgreSQL database (binary + SQL formats)
- Redis data
- Configuration files
- Docker secrets
- Let's Encrypt certificates

Backups are stored in `backups/` with automatic cleanup of files older than 7 days.

### Restore

Restore from a backup:

```bash
# From directory
./scripts/restore.sh backups/secureguard_20240101_120000

# From archive
./scripts/restore.sh backups/secureguard_20240101_120000.tar.gz
```

### Updates

Watchtower automatically updates containers daily at 4 AM UTC.

Manual update:

```bash
docker compose pull
docker compose up -d
```

Pin to a specific version in `.env`:

```bash
VERSION=1.2.3
```

---

## Security

### Automatic Protections

- **HTTPS-only** - All HTTP traffic redirects to HTTPS
- **HSTS** - Strict Transport Security enabled
- **Security Headers** - CSP, X-Frame-Options, X-Content-Type-Options
- **Fail2ban** - Automatic IP blocking after failed login attempts
- **Rate Limiting** - Enrollment endpoint protected against abuse
- **Docker Secrets** - Sensitive data never exposed in environment variables

### Fail2ban Rules

| Jail | Trigger | Ban Duration |
|------|---------|--------------|
| secureguard-auth | 5 failed logins in 5 min | 1 hour |
| secureguard-enrollment | 10 failed attempts in 1 min | 30 minutes |
| secureguard-api | 20 errors in 1 min | 15 minutes |

View banned IPs:

```bash
docker compose exec fail2ban fail2ban-client status secureguard-auth
```

Unban an IP:

```bash
docker compose exec fail2ban fail2ban-client set secureguard-auth unbanip 1.2.3.4
```

### Firewall Configuration

Recommended UFW rules:

```bash
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP (ACME)
ufw allow 443/tcp   # HTTPS
ufw allow 443/udp   # HTTP/3 QUIC
ufw allow 51820/udp # WireGuard
ufw enable
```

---

## Troubleshooting

### Containers not starting

Check Docker logs:

```bash
docker compose logs -f
```

Verify all health checks:

```bash
docker compose ps
```

### HTTPS certificate issues

Ensure your domain's DNS is pointing to the server:

```bash
dig +short your-domain.com
```

Check Caddy logs:

```bash
docker compose logs caddy
```

### VPN clients can't connect

1. Verify UDP port 51820 is open:
   ```bash
   nc -uzv your-server-ip 51820
   ```

2. Check VPN daemon status:
   ```bash
   docker compose logs vpn-daemon
   ```

3. Verify client configuration matches server settings

### Database connection errors

Check PostgreSQL health:

```bash
docker compose exec postgres pg_isready
```

View database logs:

```bash
docker compose logs postgres
```

### Reset everything

```bash
# Stop all services
docker compose down

# Remove all data (DESTRUCTIVE!)
docker compose down -v

# Remove secrets
rm -rf secrets/

# Re-run setup
./install.sh
```

---

## Monitoring

If you enabled the monitoring stack:

### Access Grafana

1. Open `https://grafana.your-domain.com`
2. Login with:
   - Username: `admin`
   - Password: (see `secrets/grafana_admin_password.txt`)

### Pre-built Dashboards

The SecureGuard dashboard shows:
- CPU and memory usage
- Network traffic
- Database connections
- Redis operations
- Active VPN sessions

### Prometheus Metrics

Access raw metrics at `http://localhost:9090` (internal only) or via Grafana's Explore feature.

---

## Uninstall

```bash
# Stop and remove all containers
docker compose down

# Remove all data (optional)
docker compose down -v

# Remove the directory
cd ..
rm -rf secureguard/
```

---

## Support

- **Issues**: https://github.com/YOUR_ORG/secureguard/issues
- **Discussions**: https://github.com/YOUR_ORG/secureguard/discussions
- **Documentation**: https://docs.secureguard.dev

---

## License

MIT License - see [LICENSE](LICENSE) for details.
