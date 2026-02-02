# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## CRITICAL: WORK METHODOLOGY

### DO NOT ADD THIS COMMENT TO GIT COMMITS

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>

**These rules take absolute priority over all other considerations:**

### 1. Deep Thinking Over Speed
- **ALWAYS use maximum tokens** available for each request
- **NEVER rush to solutions** - thoroughness and accuracy are the top priority
- **Think deeply** about implications, edge cases, and system-wide impact before making changes
- Consider all related components that might be affected
- Review existing patterns and conventions in the codebase before implementing

### 2. Planning and Organization
- **ALWAYS create a detailed plan** before starting implementation, even when not explicitly in planning mode
- **ALWAYS use the TodoWrite tool** to create and maintain a task list for multi-step work
- Break down complex tasks into specific, actionable items
- **Show the todo list** at the start and update it as you progress
- Mark items as `in_progress` when starting, `completed` when finished
- If the plan is not fully implemented, say so and explain why

### 3. Verification and Quality Assurance
- **ALWAYS check your work** against the original plan when completed
- Verify that all requirements have been met
- Review all changes for consistency with codebase patterns
- Test critical paths mentally before declaring work complete
- Look for potential issues introduced by the changes

### 4. Communication and Transparency
- **ALWAYS provide maximum feedback** as you work through tasks
- Explain what you're doing and why at each step
- Share your reasoning for implementation decisions
- Call out any assumptions or uncertainties
- Describe what you're looking for when searching/reading code
- **Keep the todo list visible** and updated throughout the conversation

### 5. No Silent Work
- NEVER make changes without explaining them
- NEVER skip showing intermediate steps
- NEVER assume the user knows what you're thinking
- **Always narrate your process** so the user can follow along



This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Run Commands

```bash
# Build (release)
cargo build --release

# Run VPN client (requires root/sudo on macOS, root/CAP_NET_ADMIN on Linux)
sudo ./target/release/minnowvpn -c docs/clients/vpn.fronthouse.ai.conf

# Run with verbose logging
sudo ./target/release/minnowvpn -c docs/clients/vpn.fronthouse.ai.conf -v

# Run tests
cargo test

# Run a single test
cargo test test_name

# Check without building
cargo check

# Linux: Grant capability instead of running as root
sudo setcap cap_net_admin=eip ./target/release/minnowvpn

# macOS: Set up setuid root permissions (run after each build)
sudo ./setuid.sh
```

## Important Development Notes

### Cross-Platform Compatibility
The Flutter desktop client must run on **Windows, macOS, and Linux**. Always consider all three platforms when making changes to:
- File paths (use platform-specific paths)
- System APIs (credentials, networking, permissions)
- Build configurations and dependencies

### Testing Prerequisites
Before testing the Rust client or server process, you must run setuid setup:
```bash
sudo ./setuid.sh
```
This grants the necessary root permissions for TUN device access and routing.

### Test Configuration Files
Test configs are located in `docs/clients/`:

| File | Purpose | IP Subnet |
|------|---------|-----------|
| `local-client.conf` | Local client testing | 10.200.0.9/24 |
| `wg0.conf` | Local server testing | 10.100.0.1/24 |
| `vpn.fronthouse.ai.conf` | Testing client connection to official WireGuard server | - |

**Important**: The local configs use separate subnets (10.100.x.x and 10.200.x.x) to avoid routing conflicts when running both client and server on the same machine.

Example usage:
```bash
# Start local server (in one terminal)
./target/release/minnowvpn -c docs/clients/wg0.conf --server -v

# Start local client (in another terminal)
./target/release/minnowvpn -c docs/clients/local-client.conf -v

# Test tunnel connectivity
ping 10.100.0.1  # From client, ping server through tunnel

# Test against official server
./target/release/minnowvpn -c docs/clients/vpn.fronthouse.ai.conf
```

## Architecture

This is a WireGuard-compatible VPN client/server implementing the Noise IKpsk2 handshake protocol.

### Core Modules

- **crypto/** - Cryptographic primitives
  - `blake2s.rs` - BLAKE2s hash, HMAC (RFC 2104 via `SimpleHmac`), and KDF functions
  - `aead.rs` - ChaCha20-Poly1305 and XChaCha20-Poly1305 encryption
  - `x25519.rs` - X25519 Diffie-Hellman key exchange
  - `noise.rs` - Noise protocol state machine (MixHash, MixKey, encrypt/decrypt)

- **protocol/** - WireGuard protocol implementation
  - `messages.rs` - Wire format structs (Handshake Initiation/Response, Transport, Cookie)
  - `handshake.rs` - Noise IKpsk2 handshake (InitiatorHandshake + ResponderHandshake)
  - `transport.rs` - Encrypted packet send/receive with replay protection
  - `session.rs` - Session state, rekey timing, and PeerManager for multi-peer support
  - `cookie.rs` - Cookie/DoS protection (MAC2)

- **tunnel/** - Cross-platform TUN device
  - `mod.rs` - TunDevice wrapper and RouteManager for endpoint bypass routing

- **config/** - WireGuard `.conf` file parser

- **client.rs** - Client event loop: TUN ↔ UDP with keepalive and rekey (initiator mode)

- **server.rs** - Server event loop: multi-peer support, incoming handshake handling (responder mode)

- **daemon/** - Daemon mode for service/REST API control
  - `mod.rs` - DaemonService with HTTP server (axum), auto-connect on startup
  - `ipc.rs` - Message types and DTOs (reused from JSON-RPC)
  - `auth.rs` - Token generation and Bearer auth middleware
  - `routes.rs` - REST API route handlers
  - `persistence.rs` - Connection state persistence for auto-reconnect on reboot

### CLI Usage

```bash
# Client mode (auto-detected if peer has Endpoint)
./minnowvpn -c client.conf

# Server mode (auto-detected if ListenPort set and no peer Endpoint)
./minnowvpn -c server.conf

# Force specific mode
./minnowvpn -c config.conf --server
./minnowvpn -c config.conf --client

# Daemon mode (for Flutter UI control via REST API)
sudo ./minnowvpn --daemon
sudo ./minnowvpn --daemon --port 51820

# Run client and server daemons simultaneously (for testing)
sudo ./minnowvpn --daemon --port 51820  # Client mode (default)
sudo ./minnowvpn --daemon --port 51821  # Server mode (separate port)
```

### Daemon Mode

The daemon runs as a background service, controlled via REST API with Bearer token authentication.

**HTTP Ports (convention for running both modes simultaneously):**
- Client mode daemon: `127.0.0.1:51820` (default)
- Server mode daemon: `127.0.0.1:51821`

The Flutter desktop client connects to the client port. The Dart REST server connects to the server port for peer management.

**Authentication:**
- On startup, daemon generates a 32-byte random token
- Token is written to a protected file with group-based permissions
- Clients read token from file and include as `Authorization: Bearer <token>` header
- Token file paths:
  - Unix: `/var/run/minnowvpn/auth-token` (permissions: `root:minnowvpn 0640`)
  - Windows: `C:\ProgramData\MinnowVPN\auth-token` (ACL: SYSTEM + Administrators full, Users read)

**REST API Endpoints (Client Mode):**
- `POST /api/v1/connect` - Start VPN client (body: `{"config": "<wireguard-config>"}`)
- `POST /api/v1/disconnect` - Stop VPN client
- `GET /api/v1/status` - Get connection status
- `PUT /api/v1/config` - Update config dynamically (body: `{"config": "<wireguard-config>"}`)

**REST API Endpoints (Server Mode):**
- `POST /api/v1/server/start` - Start VPN server (body: `{"config": "<wireguard-config>"}`)
- `POST /api/v1/server/stop` - Stop VPN server
- `GET /api/v1/server/peers` - List all configured peers
- `GET /api/v1/server/peers/:pubkey` - Get specific peer status
- `POST /api/v1/server/peers` - Add peer (body: `{"public_key": "<base64>", "allowed_ips": ["10.0.0.2/32"], "preshared_key": "<optional>"}`)
- `DELETE /api/v1/server/peers/:pubkey` - Remove peer

**Server-Sent Events (SSE):**
- `GET /api/v1/events` - Real-time notification stream

**SSE Event Types (Client Mode):**
- `status_changed` - Connection state changes
- `config_updated` - Config update succeeded (includes vpn_ip, server_endpoint)
- `config_update_failed` - Config update failed (includes error, rolled_back)
- `auto_connect_retry` - Auto-reconnect attempt status (includes attempt, status, next_retry_secs, error)

**SSE Event Types (Server Mode):**
- `server_status_changed` - Server state changes
- `peer_connected` - Peer completed handshake
- `peer_disconnected` - Peer session terminated
- `peer_added` - New peer added dynamically
- `peer_removed` - Peer removed

**Platform installers:**
- macOS: `installer/macos/install.sh` (LaunchDaemon manual install)
- macOS: `installer/macos/build-dmg.sh` (unified PKG installer)
- macOS: `installer/macos/uninstall.sh` (CLI uninstall, also bundled in PKG for in-app use)
- Linux: `installer/linux/install.sh` (systemd manual install)
- Linux: `installer/linux/build-package.sh` (.deb/.rpm packages via Docker)
- Linux: `installer/linux/uninstall.sh` (CLI uninstall)
- Windows: `installer/windows/install.ps1` (Windows Service)
- Windows: `installer/windows/uninstall.ps1` (PowerShell uninstall)
- Docker: `installer/docker/` (Docker Compose deployment)

**macOS Installer Build:**

Prerequisites:
- Rust toolchain with both x86_64-apple-darwin and aarch64-apple-darwin targets
- Flutter SDK
- Xcode Command Line Tools (pkgbuild, productbuild, lipo)

Build the PKG installer:
```bash
cd installer/macos
./build-dmg.sh <VERSION>   # e.g., ./build-dmg.sh 1.0.1
```

The build script performs:
1. Builds Rust daemon as universal binary (x86_64 + arm64) using `lipo`
2. Builds Flutter macOS app with `flutter build macos --release`
3. Creates unified PKG installer via `create-pkg.sh`

Output: `installer/macos/build/MinnowVPN-<VERSION>.pkg` (~20MB)

The PKG installer includes:
- `MinnowVPN.app` installed to `/Applications`
- VPN daemon service at `/Library/PrivilegedHelperTools/minnowvpn-service`
- LaunchDaemon plist for auto-start at boot
- Uninstall script at `/Library/Application Support/MinnowVPN/uninstall.sh` (for in-app uninstall)
- Preinstall script (stops existing services, cleans old tokens)
- Postinstall script (creates minnowvpn group, sets permissions, starts service)

To install the PKG:
```bash
# Double-click the PKG file in Finder, or:
sudo installer -pkg installer/macos/build/MinnowVPN-<VERSION>.pkg -target /
```

To uninstall:
```bash
# Option 1: From the app (recommended for end users)
# Right-click system tray → "Uninstall MinnowVPN..."

# Option 2: Command line
cd installer/macos
sudo ./uninstall.sh          # Remove service only
sudo ./uninstall.sh --all    # Remove everything including app, data, logs
```

**Linux Installer Build:**

Prerequisites (native build):
- Rust toolchain
- Flutter SDK
- `dpkg-deb` (for .deb packages)
- `rpmbuild` (for .rpm packages)

Build packages using Docker (works from macOS/Windows):
```bash
cd installer/linux
./build-package.sh 1.0.0                           # Build native arch, both formats
./build-package.sh 1.0.0 --arch=aarch64            # Build ARM64
./build-package.sh 1.0.0 --arch=x86_64             # Build x86_64
./build-package.sh 1.0.0 --format=deb              # Build .deb only
./build-package.sh 1.0.0 --format=rpm              # Build .rpm only
./build-package.sh 1.0.0 --docker                  # Force Docker build
```

Output: `installer/linux/build/minnowvpn_<VERSION>_<ARCH>.deb` and/or `minnowvpn-<VERSION>-1.<ARCH>.rpm`

The packages include:
- VPN daemon service at `/usr/local/bin/minnowvpn-service`
- Flutter client at `/opt/minnowvpn/minnowvpn_client`
- Symlink `/usr/local/bin/minnowvpn` -> client
- systemd service file at `/etc/systemd/system/minnowvpn.service`
- Desktop file for app menu integration
- preinst/postinst scripts (create group, set permissions, start service)

To test installation in Docker:
```bash
./installer/linux/docker-test.sh debian    # Test .deb on Debian
./installer/linux/docker-test.sh fedora    # Test .rpm on Fedora
```

To install:
```bash
# Debian/Ubuntu
sudo dpkg -i minnowvpn_1.0.0_arm64.deb
sudo apt-get install -f  # Fix dependencies if needed

# Fedora/RHEL
sudo rpm -i minnowvpn-1.0.0-1.aarch64.rpm
```

**Docker Deployment:**

All-in-one Docker Compose deployment with automatic HTTPS, monitoring, and security hardening.

```bash
cd installer/docker
./scripts/setup.sh
```

The setup wizard prompts for domain, email, and server IP, then:
1. Generates secure random secrets
2. Builds all containers (multi-arch: amd64 + arm64)
3. Starts the full stack with Let's Encrypt HTTPS

**Publish to Docker Hub:**
```bash
cd installer/docker/scripts
./publish.sh 1.0.0                    # Build + push all (both arch)
./publish.sh 1.0.0 --no-push          # Build only
./publish.sh 1.0.0 --amd64-only       # x86_64 only
./publish.sh 1.0.0 --arm64-only       # ARM64 only
./publish.sh 1.0.0 --image=api        # Single image only
./publish.sh 1.0.0 -y                 # Skip prompts (CI/CD)
```

**Docker Images:**
- `minnowvpn/api` - Dart REST API server
- `minnowvpn/console` - Flutter web management console
- `minnowvpn/vpn` - Rust WireGuard VPN daemon

**Docker Services:**
- `postgres` - PostgreSQL 15 database
- `redis` - Redis 7 cache/pub-sub
- `dart-server` - REST API server
- `flutter-console` - Web management console (nginx)
- `vpn-daemon` - Rust WireGuard VPN server (host network)
- `caddy` - Reverse proxy with auto-HTTPS
- `watchtower` - Automatic container updates (daily)
- `fail2ban` - Brute-force protection

**Monitoring Stack** (enable with `--profile monitoring`):
- `prometheus` - Metrics collection
- `grafana` - Dashboards
- `node-exporter`, `redis-exporter`, `postgres-exporter`

**Docker Secrets:**
Sensitive values are stored in `installer/docker/secrets/` (never committed):
- `db_password.txt`, `redis_password.txt`, `jwt_secret.txt`, `encryption_key.txt`

**Configuration:**
- `.env` - Domain, email, ports (user-configurable)
- `Caddyfile` - Reverse proxy with security headers
- `config/fail2ban/` - Login protection rules
- `config/prometheus.yml` - Metrics scrape config

### Key Implementation Details

1. **HMAC Construction**: Uses `SimpleHmac<Blake2s256>` (RFC 2104) for KDFs, not BLAKE2s keyed mode. This is critical for handshake compatibility.

2. **Endpoint Bypass Routing**: Routes must be set up AFTER handshake completes. A specific route for the VPN endpoint goes through the default gateway to prevent routing loops.

3. **Session Rekey**: Sessions automatically rekey after 120 seconds. Old session remains valid during rekey.

4. **Stale Route Cleanup**: Uses a persistent state file (`/var/run/minnowvpn_routes.json` on Unix, `C:\ProgramData\MinnowVPN\routes.json` on Windows) to track routes added during a session. On startup, if the state file exists and the recorded interface no longer exists, the exact routes from the file are cleaned up. This deterministic approach avoids the fragility of parsing routing tables.

5. **Graceful Shutdown**: Handles both Ctrl+C (SIGINT) and SIGTERM signals. On shutdown, all routes added during the session are removed and the state file is deleted to prevent orphaned routes.

6. **Auto-Reconnect on Boot**: The daemon persists connection state to enable automatic reconnection after system reboot. When the daemon starts, it checks for a state file and auto-connects if `desired_state` is `connected`. The auto-reconnect uses infinite retry with exponential backoff (5s → 10s → 30s → 60s, then 60s forever) to handle network unavailability at boot. Retries only stop when: (1) connection succeeds, or (2) user explicitly disconnects via the API.

   **State file locations:**
   - Unix: `/var/lib/minnowvpn/connection-state.json` (permissions: `root:minnowvpn 0640`)
   - Windows: `C:\ProgramData\MinnowVPN\connection-state.json`

   **State persistence triggers:**
   - `POST /connect` - Saves state BEFORE connecting (ensures config survives crash during connect)
   - `POST /disconnect` - Sets `desired_state=disconnected` (prevents auto-reconnect)
   - `PUT /config` - Updates stored config (auto-reconnect uses new config after reboot)

### Debug Binaries

Various verification tools in `src/bin/` for testing crypto primitives against known test vectors.

## Dart REST API Server

Located in `minnowvpn-server/`. A Dart server using Shelf for VPN client management.

### Setup

```bash
cd minnowvpn-server

# Create .env file with your database settings
# Required variables: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, JWT_SECRET

# Get dependencies
dart pub get

# Run server
dart run bin/server.dart
```

### API Endpoints

- `GET /api/v1/health` - Health check
- `GET /api/v1/auth/setup/status` - Check if initial setup is needed
- `POST /api/v1/auth/setup` - Create first admin account
- `POST /api/v1/auth/login` - Admin login
- `POST /api/v1/auth/logout` - Admin logout
- `POST /api/v1/auth/refresh` - Refresh JWT token
- `GET/POST/PUT/DELETE /api/v1/clients/*` - Client management (auth required)
- `GET /api/v1/logs/*` - Audit/error/connection logs (auth required)
- `POST /api/v1/enrollment/register` - Device enrollment (returns client_id)
- `POST /api/v1/enrollment/redeem` - Redeem enrollment code for device token + config (rate limited: 5/min per IP)
- `GET /api/v1/enrollment/config` - Fetch WireGuard config (device auth required)
- `GET /api/v1/enrollment/config/version` - Check config version for updates
- `POST /api/v1/enrollment/heartbeat` - Report device status (includes hostname locking)

**Hostname Locking:**

The heartbeat endpoint enforces hostname-based device identity:
- First heartbeat with a hostname: locks the client record to that hostname
- Subsequent heartbeats: hostname must match or request is rejected with 403
- Mismatches create `HOSTNAME_MISMATCH` audit log entries
- Console shows amber warning icon for clients with security alerts

**Enrollment Code Management (admin auth required):**
- `GET /api/v1/clients/:id/enrollment-code` - Get active enrollment code for client
- `POST /api/v1/clients/:id/enrollment-code` - Generate new enrollment code (24h expiry)
- `DELETE /api/v1/clients/:id/enrollment-code` - Revoke enrollment code

**Security Alerts (admin auth required):**
- `GET /api/v1/clients/:id/security-alerts` - Get security alerts for client (hostname mismatches)

**SSO Authentication (public):**
- `GET /api/v1/auth/sso/providers` - List enabled SSO providers
- `GET /api/v1/auth/sso/:provider/authorize` - Start OAuth authorization flow
- `GET /api/v1/auth/sso/:provider/callback` - OAuth callback handler
- `POST /api/v1/auth/sso/:provider/device` - Start device code flow (for desktop apps)
- `POST /api/v1/auth/sso/:provider/device/poll` - Poll device code completion

**SSO Configuration (admin auth required):**
- `GET /api/v1/admin/sso/configs` - List SSO provider configs
- `POST /api/v1/admin/sso/configs` - Save SSO provider config
- `DELETE /api/v1/admin/sso/configs/:provider` - Delete SSO provider config

**Email Settings (admin auth required):**
- `GET /api/v1/admin/settings/email` - Get SMTP email settings (password excluded)
- `PUT /api/v1/admin/settings/email` - Update SMTP email settings (password encrypted with AES-256-GCM)
- `POST /api/v1/admin/settings/email/test` - Send test email to verify configuration
- `GET /api/v1/admin/settings/email/queue/stats` - Get email queue statistics
- `POST /api/v1/clients/:id/send-enrollment-email` - Send enrollment email to client

**Dashboard Endpoints (admin auth required):**
- `GET /api/v1/dashboard/stats` - Overall dashboard statistics
- `GET /api/v1/dashboard/active-clients` - List of currently active clients
- `GET /api/v1/dashboard/activity` - Recent activity feed
- `GET /api/v1/dashboard/errors/summary` - Error counts by severity (last 24h)
- `GET /api/v1/dashboard/connections/history` - Connection count time series

**WebSocket (token auth via query param):**
- `WS /api/v1/ws/dashboard?token=<jwt>` - Real-time dashboard updates

### WebSocket Protocol

The dashboard WebSocket provides real-time updates for metrics and events.

**Authentication:** JWT token passed as `token` query parameter.

**Message Types (server → client):**
```json
// Initial state on connect
{"type": "initial_state", "data": {...stats...}}

// Periodic metrics update (every 10s)
{"type": "metrics_update", "data": {...stats...}}

// Connection events (client connect/disconnect)
{"type": "connection_event", "data": {"event": "connected", "client_id": "...", "name": "..."}}

// Error events
{"type": "error_event", "data": {"severity": "error", "message": "..."}}

// Audit events
{"type": "audit_event", "data": {"event_type": "...", "actor_name": "..."}}

// Heartbeat response
{"type": "pong"}
```

**Message Types (client → server):**
```json
// Heartbeat
{"type": "ping"}

// Subscribe to specific channels (optional)
{"type": "subscribe", "channels": ["connections", "errors"]}
```

### Redis Configuration

The server requires Redis for pub/sub event streaming and real-time metrics.

**Environment Variables:**
- `REDIS_HOST` - Redis server hostname (default: localhost)
- `REDIS_PORT` - Redis server port (default: 6379)
- `REDIS_PASSWORD` - Redis password (optional)

**Redis Channels:**
- `channel:connections` - Connection/disconnection events
- `channel:errors` - Error events
- `channel:audit` - Audit log events
- `channel:metrics` - General metrics updates

**Redis Keys:**
- `client:online:<client_id>` - Online client data (TTL: 2 minutes)
- `client:online:set` - Set of all online client IDs
- `metrics:connections:count` - Sorted set time series of connection counts (24h retention)
- `metrics:bandwidth:tx` - Upload bandwidth counter
- `metrics:bandwidth:rx` - Download bandwidth counter
- `metrics:total:connections` - Total connections counter
- `metrics:total:bytes_tx` - Total bytes uploaded
- `metrics:total:bytes_rx` - Total bytes downloaded
- `ratelimit:enrollment:redeem:<ip>` - Rate limit counter (TTL: 60s, max 5/min)
- `email:queue` - Email job queue (List, FIFO with LPUSH/RPOP)
- `email:failed` - Failed email jobs after max retries (List)
- `email:sent:count` - Total emails sent counter (Integer)

### API Response Format Reference

**CRITICAL**: List endpoints return data under DIFFERENT keys. The Flutter console must use the correct key.

| Endpoint | Response Key | Example |
|----------|-------------|---------|
| `GET /clients` | `clients` | `{"clients": [...], "pagination": {...}}` |
| `GET /logs/audit` | `events` | `{"events": [...], "pagination": {...}}` |
| `GET /logs/errors` | `errors` | `{"errors": [...], "pagination": {...}}` |
| `GET /logs/connections` | `connections` | `{"connections": [...], "pagination": {...}}` |
| `GET /admin/settings/admins` | `data` | `{"data": [...]}` |
| `GET /admin/settings/api-keys` | `data` | `{"data": [...]}` |
| `GET /admin/sso/configs` | `configs` | `{"configs": [...]}` |
| `GET /dashboard/active-clients` | `clients` | `{"clients": [...]}` |
| `GET /dashboard/activity` | `events` | `{"events": [...]}` |
| `GET /dashboard/connections/history` | `data` | `{"data": [...]}` |

**Pagination structure** (when present):
```json
{
  "pagination": {
    "page": 1,
    "limit": 50,
    "total": 100,
    "total_pages": 2
  }
}
```

**Error responses** always use:
```json
{"error": "Error message here"}
```

### PostgreSQL Type Handling

Keys and encrypted data are stored as TEXT (base64 encoded) for simplicity. CIDR/INET types may come as `UndecodedBytes` from the postgres v3 driver. Use utilities in `lib/src/database/postgres_utils.dart`:

```dart
import '../database/postgres_utils.dart';

// TEXT (base64) → returns string directly
publicKey: bytesToBase64(row['public_key']),

// TEXT (base64) → Uint8List (for decryption)
passwordEnc: bytesToUint8List(row['password_enc']),

// CIDR/INET → String
ipSubnet: pgToString(row['ip_subnet']),

// INET[] → List<String>
allowedIps: parseInetArray(row['allowed_ips']),

// INET[] with CIDR suffix stripped (for DNS servers)
dnsServers: parseInetArray(row['dns_servers'], stripCidr: true),
```

**Key storage**: Pass base64 strings directly to INSERT/UPDATE - no need to decode to bytes first.

## Flutter Web Management Console

Located in `minnowvpn_console/`. A Flutter web admin interface for managing VPN clients.

### Quick Start

```bash
cd minnowvpn_console

# Start both server and console (recommended)
./start.sh
```

### Manual Build and Run

```bash
cd minnowvpn_console

# Get dependencies
flutter pub get

# Run in development mode (requires server running)
flutter run -d chrome --dart-define=API_URL=http://localhost:8080/api/v1

# Build for production
flutter build web --release
```

### First-Run Setup Flow

On first launch with an empty database:
1. Console checks `/auth/setup/status` endpoint
2. If `needs_setup: true`, redirects to Setup Screen
3. User creates first admin account (email + password min 8 chars)
4. After setup, redirects to Login Screen
5. User logs in with the created credentials

If server is unavailable, shows Connection Error Screen with retry option.

### Architecture

- **State Management**: Riverpod (flutter_riverpod)
- **Routing**: GoRouter with auth redirect and setup flow
- **HTTP Client**: Dio with interceptors for auth tokens
- **Charts**: fl_chart for dashboard visualizations

### Project Structure

```
minnowvpn_console/lib/
├── main.dart              # Entry point
├── app.dart               # MaterialApp.router setup
├── config/
│   ├── theme.dart         # Dark/light theme, semantic colors
│   └── routes.dart        # GoRouter configuration with setup/error handling
├── services/
│   └── api_service.dart   # REST API client + ServerUnavailableException
├── providers/
│   ├── auth_provider.dart      # Authentication state + serverUnavailable flag
│   ├── clients_provider.dart   # Client list management
│   ├── dashboard_provider.dart # Real-time dashboard state + WebSocket
│   ├── logs_provider.dart      # Audit/error/connection logs
│   └── settings_provider.dart  # Server config
├── models/
│   ├── client.dart        # Client data model
│   └── logs.dart          # Log entry models
├── screens/
│   ├── connection_error_screen.dart  # Server unavailable error
│   ├── setup_screen.dart             # First-run admin setup
│   ├── login_screen.dart
│   ├── dashboard_screen.dart
│   ├── clients_screen.dart
│   ├── client_detail_screen.dart
│   ├── logs_screen.dart
│   └── settings_screen.dart
└── widgets/
    ├── app_shell.dart     # Navigation rail shell
    └── stat_card.dart     # Dashboard stat cards
```

### API Configuration

The API base URL is configured via environment variable:
```bash
flutter run --dart-define=API_URL=http://localhost:8080/api/v1
```

Default: `http://localhost:8080/api/v1`

### Session Persistence

Authentication tokens are stored in `SharedPreferences` (localStorage on web) to survive browser refreshes. Tokens are automatically refreshed on app initialization if valid.

**Stored Keys:**
- `access_token` - JWT access token
- `refresh_token` - JWT refresh token

### Enrollment Settings

Global enrollment preferences are stored in `SharedPreferences`:

- `enrollment_auto_send_email` - Auto-send enrollment email when codes are generated (default: `true`)

These settings are configurable in Settings → Enrollment Settings.

### Known Limitations (TODOs)

- Log export not yet implemented (shows "coming soon" message)
- Client key regeneration UI exists but action not connected
- Logout doesn't invalidate refresh tokens in Redis (TODO: implement token blacklist)

## Flutter Desktop Client

Located in `minnowvpn_client/`. A Flutter desktop app for end-users to control the VPN connection.

### Quick Start

```bash
cd minnowvpn_client

# Start both daemon and Flutter client (recommended)
./start.sh

# Stop all instances
./stop.sh

# Or run manually:
flutter pub get
flutter run -d macos   # or -d linux, -d windows

# Build for production
flutter build macos --release
```

### Architecture

- **State Management**: Riverpod (flutter_riverpod)
- **Daemon Communication**: HTTP REST API with Bearer token auth + SSE for events
- **System Tray**: tray_manager for menu bar/system tray integration
- **Window Management**: window_manager for custom title bar

### Project Structure

```
minnowvpn_client/lib/
├── main.dart              # Entry point, service initialization, deep link handling
├── screens/
│   ├── home_screen.dart       # Main VPN control screen
│   └── enrollment_screen.dart # Enrollment code / deep link enrollment
├── services/
│   ├── ipc_client.dart        # HTTP REST API client to Rust daemon + SSE
│   ├── tray_service.dart      # System tray integration + uninstall menu
│   ├── api_client.dart        # HTTP client for server API
│   ├── update_service.dart    # Auto-update functionality
│   ├── credential_storage.dart # Secure platform credential storage
│   ├── enrollment_service.dart # SSO auth and device enrollment
│   └── uninstall_service.dart # Cross-platform uninstall with elevation
├── providers/
│   └── vpn_provider.dart  # VPN state management
└── widgets/
    ├── status_card.dart       # Connection status display
    ├── traffic_stats.dart     # Bytes sent/received
    ├── connection_button.dart # Connect/disconnect button
    ├── config_dialog.dart     # WireGuard config input
    └── uninstall_dialog.dart  # Uninstall confirmation dialog
```

### Daemon Communication

The client communicates with the Rust daemon via HTTP REST API at `http://127.0.0.1:51820/api/v1`.

**Authentication:**
- Token is read from platform-specific path on startup:
  - Unix: `/var/run/minnowvpn/auth-token`
  - Windows: `C:\ProgramData\MinnowVPN\auth-token`
- Token is sent as `Authorization: Bearer <token>` header with all requests

**REST Endpoints:**
- `POST /connect` - Connect with WireGuard config
- `POST /disconnect` - Disconnect VPN
- `GET /status` - Get current connection status
- `PUT /config` - Update config dynamically (validates before disconnect, reconnects with new config)

**Real-time Events:**
- `GET /events` - SSE stream for status notifications

### Auto-Update Service

The client automatically checks for updates:
- **Config version check**: Every 5 minutes
- **Binary update check**: Every 1 hour

When a config update is detected, the client:
1. Fetches new config from server
2. If connected, uses `update_config` IPC for seamless reconnection (validates config before disconnect)
3. If disconnected, stores config for next connection

Binary updates:
1. Download update with SHA256 verification
2. Ed25519 signature verification (requires UPDATE_SIGNING_PUBLIC_KEY at build time)
3. Platform-specific installation

### System Tray

The app minimizes to system tray on close:
- **Icons**: Shield icons in green/gray/amber/red for connection states
- **Menu**: Connect, Disconnect, Show Window, Uninstall MinnowVPN..., Quit
- **Click**: Shows/focuses the main window

### In-App Uninstallation

Users can uninstall MinnowVPN directly from the system tray menu:

1. Right-click tray icon → "Uninstall MinnowVPN..."
2. Confirmation dialog appears explaining what will be removed
3. User is prompted for admin/root password (platform-specific elevation)
4. Uninstall script runs with elevated privileges
5. App exits after successful uninstall

**Platform-specific elevation methods:**

| Platform | Elevation Method | Script Location |
|----------|------------------|-----------------|
| macOS | `osascript` with administrator privileges | `/Library/Application Support/MinnowVPN/uninstall.sh` |
| Windows | PowerShell `Start-Process -Verb RunAs` (UAC) | `C:\Program Files\MinnowVPN\uninstall.ps1` |
| Linux | `pkexec` (PolicyKit) | `/opt/minnowvpn/uninstall.sh` |

**Implementation files:**
- `lib/services/uninstall_service.dart` - Platform-specific uninstall execution
- `lib/widgets/uninstall_dialog.dart` - Confirmation dialog UI

**Note for Linux installers:** Ensure the uninstall script is installed to `/opt/minnowvpn/uninstall.sh` for the Flutter app to find it.

### Known Limitations (TODOs)

- Ed25519 signature verification is a placeholder (validates lengths only)
- For production, implement via flutter_rust_bridge or platform channels

### Deep Links / URL Scheme

The client supports `minnowvpn://` deep links for enrollment:

**URL Format:**
```
minnowvpn://enroll?server=https://vpn.company.com&code=ABCD-1234
```

**Platform Registration:**
- **macOS**: `macos/Runner/Info.plist` - CFBundleURLTypes
- **Windows**: `windows/install_url_scheme.ps1` - Registry HKCR\minnowvpn
- **Linux**: `linux/minnowvpn_client.desktop` - MimeType x-scheme-handler/minnowvpn

**Enrollment Screen:**
- Pre-fills server URL and code from deep link
- Auto-enrolls when launched from deep link
- Manual fallback: user enters domain + code (format: XXXX-XXXX)

### SSO Integration

The client supports SSO authentication via the device code flow:
- **CredentialStorage**: Platform-specific secure storage (Keychain on macOS, Credential Manager on Windows, libsecret on Linux)
- **EnrollmentService**: Handles SSO provider discovery, device code flow, device registration, and token refresh
- Supported providers: Azure AD (Entra ID), Okta, Google Workspace (server-side configuration required)

**Server-side JWT Verification Status:**
- **Google**: Full RS256 signature verification using JWKS (with 1-hour caching)
- **Okta**: Full RS256 signature verification using JWKS (with 1-hour caching)
- **Azure AD**: Full RS256 signature verification using JWKS (with 1-hour caching)

