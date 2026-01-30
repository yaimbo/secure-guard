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
sudo ./target/release/secureguard-poc -c docs/clients/vpn.fronthouse.ai.conf

# Run with verbose logging
sudo ./target/release/secureguard-poc -c docs/clients/vpn.fronthouse.ai.conf -v

# Run tests
cargo test

# Run a single test
cargo test test_name

# Check without building
cargo check

# Linux: Grant capability instead of running as root
sudo setcap cap_net_admin=eip ./target/release/secureguard-poc

# macOS: Set up setuid root permissions (run after each build)
sudo ./setuid.sh
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

- **daemon/** - Daemon mode for service/IPC control
  - `mod.rs` - DaemonService with Unix socket listener
  - `ipc.rs` - JSON-RPC 2.0 message types and protocol

### CLI Usage

```bash
# Client mode (auto-detected if peer has Endpoint)
./secureguard-poc -c client.conf

# Server mode (auto-detected if ListenPort set and no peer Endpoint)
./secureguard-poc -c server.conf

# Force specific mode
./secureguard-poc -c config.conf --server
./secureguard-poc -c config.conf --client

# Daemon mode (for Flutter UI control via IPC)
sudo ./secureguard-poc --daemon
sudo ./secureguard-poc --daemon --socket /custom/path.sock
```

### Daemon Mode

The daemon runs as a background service, controlled via Unix socket IPC (JSON-RPC 2.0 protocol).

**Socket path:** `/var/run/secureguard.sock` (default)

**IPC Commands:**
- `connect` - Start VPN with config: `{"method": "connect", "params": {"config": "<wireguard-config>"}}`
- `disconnect` - Stop VPN: `{"method": "disconnect"}`
- `status` - Get connection status: `{"method": "status"}`

**Status notifications** are pushed to connected clients when state changes.

**Platform installers:**
- macOS: `installer/macos/install.sh` (LaunchDaemon)
- Linux: `installer/linux/install.sh` (systemd)
- Windows: `installer/windows/install.ps1` (Windows Service)

### Key Implementation Details

1. **HMAC Construction**: Uses `SimpleHmac<Blake2s256>` (RFC 2104) for KDFs, not BLAKE2s keyed mode. This is critical for handshake compatibility.

2. **Endpoint Bypass Routing**: Routes must be set up AFTER handshake completes. A specific route for the VPN endpoint goes through the default gateway to prevent routing loops.

3. **Session Rekey**: Sessions automatically rekey after 120 seconds. Old session remains valid during rekey.

### Debug Binaries

Various verification tools in `src/bin/` for testing crypto primitives against known test vectors.

## Dart REST API Server

Located in `secureguard-server/`. A Dart server using Shelf for VPN client management.

### Setup

```bash
cd secureguard-server

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
- `POST /api/v1/enrollment/heartbeat` - Report device status

**Enrollment Code Management (admin auth required):**
- `GET /api/v1/clients/:id/enrollment-code` - Get active enrollment code for client
- `POST /api/v1/clients/:id/enrollment-code` - Generate new enrollment code (24h expiry)
- `DELETE /api/v1/clients/:id/enrollment-code` - Revoke enrollment code

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
- `metrics:connections:*` - Time series connection data
- `ratelimit:enrollment:redeem:<ip>` - Rate limit counter for enrollment code redemption (TTL: 60s)
- `email:queue` - Email job queue (List, FIFO with LPUSH/RPOP)
- `email:failed` - Failed email jobs after max retries (List)
- `email:sent:count` - Total emails sent counter (Integer)

### PostgreSQL Type Handling

The postgres v3 Dart driver returns BYTEA, CIDR, INET, and INET[] columns as `UndecodedBytes` objects instead of `Uint8List` or `String`. Use the shared utilities in `lib/src/database/postgres_utils.dart`:

```dart
import '../database/postgres_utils.dart';

// BYTEA → base64 string (for JSON responses)
publicKey: bytesToBase64(row['public_key']),

// BYTEA → Uint8List (for internal use)
passwordEnc: bytesToUint8List(row['password_enc']),

// CIDR/INET → String
ipSubnet: pgToString(row['ip_subnet']),

// INET[] → List<String>
allowedIps: parseInetArray(row['allowed_ips']),

// INET[] with CIDR suffix stripped (for DNS servers)
dnsServers: parseInetArray(row['dns_servers'], stripCidr: true),
```

**Important**: Never cast PostgreSQL column values directly to `Uint8List` or assume they are `String`. Always use these utilities to handle `UndecodedBytes`.

## Flutter Web Management Console

Located in `secureguard_console/`. A Flutter web admin interface for managing VPN clients.

### Quick Start

```bash
cd secureguard_console

# Start both server and console (recommended)
./start.sh
```

### Manual Build and Run

```bash
cd secureguard_console

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
secureguard_console/lib/
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

### Known Limitations (TODOs)

- Log export not yet implemented (shows "coming soon" message)
- Client key regeneration UI exists but action not connected
- Logout doesn't invalidate refresh tokens in Redis (TODO: implement token blacklist)

## Flutter Desktop Client

Located in `secureguard_client/`. A Flutter desktop app for end-users to control the VPN connection.

### Quick Start

```bash
cd secureguard_client

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
- **IPC**: Unix socket communication with Rust daemon (JSON-RPC 2.0)
- **System Tray**: tray_manager for menu bar/system tray integration
- **Window Management**: window_manager for custom title bar

### Project Structure

```
secureguard_client/lib/
├── main.dart              # Entry point, service initialization, deep link handling
├── screens/
│   ├── home_screen.dart       # Main VPN control screen
│   └── enrollment_screen.dart # Enrollment code / deep link enrollment
├── services/
│   ├── ipc_client.dart        # Unix socket IPC to Rust daemon
│   ├── tray_service.dart      # System tray integration
│   ├── api_client.dart        # HTTP client for server API
│   ├── update_service.dart    # Auto-update functionality
│   ├── credential_storage.dart # Secure platform credential storage
│   └── enrollment_service.dart # SSO auth and device enrollment
├── providers/
│   └── vpn_provider.dart  # VPN state management
└── widgets/
    ├── status_card.dart       # Connection status display
    ├── traffic_stats.dart     # Bytes sent/received
    ├── connection_button.dart # Connect/disconnect button
    └── config_dialog.dart     # WireGuard config input
```

### IPC Communication

The client communicates with the Rust daemon via Unix socket at `/var/run/secureguard.sock`.

**JSON-RPC Commands:**
- `connect` - Connect with WireGuard config
- `disconnect` - Disconnect VPN
- `status` - Get current connection status

### Auto-Update Service

The client automatically checks for updates:
- **Config version check**: Every 5 minutes
- **Binary update check**: Every 1 hour

When a config update is detected, the client:
1. Fetches new config from server
2. If connected, seamlessly reconnects with new config
3. If disconnected, stores config for next connection

Binary updates:
1. Download update with SHA256 verification
2. Ed25519 signature verification (requires UPDATE_SIGNING_PUBLIC_KEY at build time)
3. Platform-specific installation

### System Tray

The app minimizes to system tray on close:
- **Icons**: Shield icons in green/gray/amber/red for connection states
- **Menu**: Connect, Disconnect, Show Window, Quit
- **Click**: Shows/focuses the main window

### Known Limitations (TODOs)

- Ed25519 signature verification is a placeholder (validates lengths only)
- For production, implement via flutter_rust_bridge or platform channels

### Deep Links / URL Scheme

The client supports `secureguard://` deep links for enrollment:

**URL Format:**
```
secureguard://enroll?server=https://vpn.company.com&code=ABCD-1234
```

**Platform Registration:**
- **macOS**: `macos/Runner/Info.plist` - CFBundleURLTypes
- **Windows**: `windows/install_url_scheme.ps1` - Registry HKCR\secureguard
- **Linux**: `linux/secureguard_client.desktop` - MimeType x-scheme-handler/secureguard

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

