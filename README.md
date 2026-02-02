# MinnowVPN

A WireGuard-compatible VPN solution with enterprise management capabilities.

## Overview

MinnowVPN is a complete VPN management platform consisting of:

- **Rust VPN Client/Server** - WireGuard-compatible implementation with daemon mode for UI control
- **Dart REST API Server** - Centralized client management, config generation, and device enrollment
- **Flutter Web Console** - Admin interface for managing VPN clients and viewing logs
- **Flutter Desktop Client** - End-user VPN application with system tray and auto-updates

## Features

### VPN Core (Rust)
- Full WireGuard protocol support (Noise IKpsk2)
- Both client (initiator) and server (responder) modes
- Cross-platform TUN device support (macOS, Linux)
- Multi-peer support in server mode
- Automatic session rekey (every 120 seconds)
- Keepalive support
- Cookie/DoS protection (MAC2)
- Connection retry with exponential backoff
- Daemon mode with IPC socket for UI integration

### Management Server (Dart)
- Client/device management with auto-generated keys
- WireGuard config generation and distribution
- Device enrollment API for automated provisioning
- Audit, error, and connection logging
- JWT-based authentication
- First-run setup wizard
- **SSO Authentication** (Azure AD, Okta, Google Workspace)
- **Real-time WebSocket** for live dashboard updates
- **Redis pub/sub** for event streaming across instances

### Admin Console (Flutter Web)
- **Real-time dashboard** with live connection statistics via WebSocket
- Active connections, bandwidth, and error monitoring
- Client management (create, edit, enable/disable, delete)
- Manual config download and QR code generation
- Audit, error, and connection log viewers
- SSO provider configuration
- Dark/light theme support

### Desktop Client (Flutter)
- Native macOS, Windows, and Linux support
- System tray integration with connection status icons
- Custom draggable title bar with window controls
- IPC communication with Rust daemon (JSON-RPC 2.0)
- **SSO authentication** via device code flow (Azure AD, Okta, Google)
- **Connection event reporting** to server for real-time monitoring
- Auto-update functionality:
  - Periodic config version checking (every 5 minutes)
  - Automatic binary update detection (every hour)
  - SHA256 hash verification for downloads
  - Ed25519 signature verification framework
- Seamless config updates while connected
- Traffic statistics (bytes sent/received)
- Periodic heartbeat to server (every 60 seconds)
- Error handling with retry support

## Quick Start

### Prerequisites

- Rust 1.70+ (for VPN client)
- Dart 3.0+ (for server)
- Flutter 3.16+ (for console and desktop client)
- PostgreSQL 14+ (for server database)
- Redis 6+ (for real-time events and session caching)

### 1. Build the VPN Client

```bash
cargo build --release
```

### 2. Start the Server

```bash
cd minnowvpn-server

# Configure database connection
cp .env.example .env
# Edit .env with your PostgreSQL credentials

# Install dependencies and run
dart pub get
dart run bin/server.dart
```

### 3. Start the Admin Console

```bash
cd minnowvpn_console
flutter pub get
flutter run -d chrome --dart-define=API_URL=http://localhost:8080/api/v1
```

Or use the convenience script:
```bash
cd minnowvpn_console
./start.sh
```

### 4. Run the Desktop Client

```bash
cd minnowvpn_client

# Start both daemon and Flutter client (recommended)
./start.sh

# Or run manually:
flutter pub get
flutter run -d macos   # or -d linux, -d windows

# Stop all instances
./stop.sh

# Build for production
flutter build macos --release   # or linux, windows
```

## Usage

### VPN Client Modes

#### Client Mode (Connect to VPN Server)
```bash
# Auto-detected if peer has Endpoint
sudo ./target/release/minnowvpn -c client.conf

# Force client mode
sudo ./target/release/minnowvpn -c client.conf --client

# With verbose logging
sudo ./target/release/minnowvpn -c client.conf -v
```

#### Server Mode (Accept Incoming Connections)
```bash
# Auto-detected if ListenPort set and no peer Endpoint
sudo ./target/release/minnowvpn -c server.conf

# Force server mode
sudo ./target/release/minnowvpn -c server.conf --server
```

#### Daemon Mode (For UI Control)
```bash
# Run as daemon with default socket
sudo ./target/release/minnowvpn --daemon

# Run with custom socket path
sudo ./target/release/minnowvpn --daemon --socket /custom/path.sock
```

### Daemon IPC Protocol

The daemon accepts JSON-RPC 2.0 commands over Unix socket (`/var/run/minnowvpn.sock`).

**Connect to VPN:**
```json
{"jsonrpc": "2.0", "method": "connect", "params": {"config": "[Interface]\nPrivateKey=..."}, "id": 1}
```

**Disconnect:**
```json
{"jsonrpc": "2.0", "method": "disconnect", "id": 2}
```

**Get Status:**
```json
{"jsonrpc": "2.0", "method": "status", "id": 3}
```

**Status Notifications** are pushed to connected clients when state changes:
```json
{"jsonrpc": "2.0", "method": "status_changed", "params": {"state": "connected", "vpn_ip": "10.0.0.2", ...}}
```

### WireGuard Config Format

Standard WireGuard configuration files are supported:

```ini
[Interface]
PrivateKey = <base64-encoded-private-key>
Address = 10.0.0.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = <base64-encoded-public-key>
PresharedKey = <optional-preshared-key>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

## Platform Installation

### macOS (LaunchDaemon)

```bash
# Build release binary
cargo build --release

# Install as system service
sudo ./installer/macos/install.sh
```

This installs:
- Binary to `/Library/PrivilegedHelperTools/minnowvpn-service`
- LaunchDaemon plist to `/Library/LaunchDaemons/`
- Logs to `/var/log/minnowvpn.log`

**Service commands:**
```bash
# Stop service
sudo launchctl unload /Library/LaunchDaemons/com.minnowvpn.vpn-service.plist

# Start service
sudo launchctl load /Library/LaunchDaemons/com.minnowvpn.vpn-service.plist

# Check status
sudo launchctl list | grep minnowvpn

# View logs
tail -f /var/log/minnowvpn.log
```

### Linux (systemd)

```bash
# Build release binary
cargo build --release

# Install as system service
sudo ./installer/linux/install.sh
```

This installs:
- Binary to `/usr/local/bin/minnowvpn-service`
- systemd unit to `/etc/systemd/system/minnowvpn.service`
- Sets required capabilities (CAP_NET_ADMIN)

**Service commands:**
```bash
sudo systemctl status minnowvpn
sudo systemctl stop minnowvpn
sudo systemctl start minnowvpn
sudo journalctl -u minnowvpn -f
```

## Server API Endpoints

### Authentication
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/health` | Health check |
| GET | `/api/v1/auth/setup/status` | Check if initial setup needed |
| POST | `/api/v1/auth/setup` | Create first admin account |
| POST | `/api/v1/auth/login` | Admin login |
| POST | `/api/v1/auth/logout` | Admin logout |
| POST | `/api/v1/auth/refresh` | Refresh JWT token |

### Client Management (Admin)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/clients` | List clients (paginated) |
| POST | `/api/v1/clients` | Create client |
| GET | `/api/v1/clients/{id}` | Get client details |
| PUT | `/api/v1/clients/{id}` | Update client |
| DELETE | `/api/v1/clients/{id}` | Delete client |
| POST | `/api/v1/clients/{id}/enable` | Enable client |
| POST | `/api/v1/clients/{id}/disable` | Disable client |
| GET | `/api/v1/clients/{id}/config` | Download WireGuard config |

### Device Enrollment (Client-facing)
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/enrollment/register` | Register new device |
| GET | `/api/v1/enrollment/config` | Fetch config for device |
| GET | `/api/v1/enrollment/config/version` | Check config version |
| POST | `/api/v1/enrollment/heartbeat` | Report device status |

### Logs (Admin)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/logs/audit` | Query audit log |
| GET | `/api/v1/logs/errors` | Query error log |
| GET | `/api/v1/logs/connections` | Query connection log |

### Dashboard (Admin)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/dashboard/stats` | Overall dashboard statistics |
| GET | `/api/v1/dashboard/active-clients` | Currently active clients |
| GET | `/api/v1/dashboard/activity` | Recent activity feed |
| GET | `/api/v1/dashboard/errors/summary` | Error counts by severity |
| GET | `/api/v1/dashboard/connections/history` | Connection time series |
| WS | `/api/v1/ws/dashboard?token=<jwt>` | Real-time WebSocket updates |

### SSO Authentication (Public)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/auth/sso/providers` | List enabled SSO providers |
| GET | `/api/v1/auth/sso/:provider/authorize` | Start OAuth flow |
| GET | `/api/v1/auth/sso/:provider/callback` | OAuth callback |
| POST | `/api/v1/auth/sso/:provider/device` | Start device code flow |
| POST | `/api/v1/auth/sso/:provider/device/poll` | Poll device code status |

### SSO Configuration (Admin)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/admin/sso/configs` | List SSO provider configs |
| POST | `/api/v1/admin/sso/configs` | Save SSO provider config |
| DELETE | `/api/v1/admin/sso/configs/:provider` | Delete SSO provider config |

### Updates (Client-facing)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/updates/manifest` | Get full update manifest |
| GET | `/api/v1/updates/check` | Check for updates (platform-specific) |
| GET | `/api/v1/updates/download/{version}/{platform}` | Download binary |

### Updates (Admin)
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/updates/releases` | List all releases |
| POST | `/api/v1/updates/releases` | Create new release |
| DELETE | `/api/v1/updates/releases/{id}` | Delete release |

## Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│                         MANAGEMENT PLANE                               │
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │  Flutter Web    │◄─┤  Dart REST API   │  │  SSO Providers       │  │
│  │  Admin Console  │WS│  Server          ├──┤  (Azure/Okta/Google) │  │
│  └────────┬────────┘  └────────┬─────────┘  └──────────────────────┘  │
│           │                    │                                       │
│           └────────────────────┼───────────────┐                      │
│                                │               │                       │
│              ┌─────────────────┴─────────┐ ┌───┴───────────────────┐  │
│              │   PostgreSQL              │ │   Redis               │  │
│              │   (data persistence)      │ │   (pub/sub, sessions) │  │
│              └───────────────────────────┘ └───────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              │                     │                     │
              ▼                     ▼                     ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────┐
│  MinnowVPN Client   │  │  MinnowVPN Client   │  │ Legacy WireGuard│
│  (Flutter + Rust)   │  │  (CLI Mode)         │  │ (manual config) │
│  Desktop App + SSO  │  │                     │  │                 │
└─────────────────────┘  └─────────────────────┘  └─────────────────┘
```

### Rust Modules

- **crypto/** - Cryptographic primitives (X25519, ChaCha20-Poly1305, BLAKE2s)
- **protocol/** - WireGuard protocol (handshake, transport, session management)
- **tunnel/** - TUN device abstraction and route management
- **config/** - WireGuard `.conf` file parser
- **daemon/** - IPC socket server for UI integration
- **client.rs** - Client event loop (initiator mode)
- **server.rs** - Server event loop (responder mode)

## Environment Variables

### Server (.env)
```bash
# Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=minnowvpn
DB_USER=minnowvpn
DB_PASSWORD=your_password

# Redis (for real-time events)
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=          # Optional

# Server
JWT_SECRET=your_jwt_secret
ENCRYPTION_KEY=your_32_char_encryption_key
PORT=8080
HOST=0.0.0.0
```

### Console
```bash
# Set API URL at build time
flutter run --dart-define=API_URL=http://localhost:8080/api/v1
```

## Building from Source

### VPN Client (Rust)

```bash
# Debug build
cargo build

# Release build (optimized)
cargo build --release

# Run tests
cargo test

# Check without building
cargo check
```

### Server (Dart)

```bash
cd minnowvpn-server
dart pub get
dart run bin/server.dart
```

### Console (Flutter Web)

```bash
cd minnowvpn_console
flutter pub get

# Development
flutter run -d chrome

# Production build
flutter build web --release
```

### Desktop Client (Flutter)

```bash
cd minnowvpn_client
flutter pub get

# Development (requires daemon running)
flutter run -d macos   # or -d linux, -d windows

# Production build
flutter build macos --release
flutter build linux --release
flutter build windows --release

# Build with update signing key (for production)
flutter build macos --release --dart-define=UPDATE_SIGNING_PUBLIC_KEY=<base64-key>
```

## Real-time Dashboard

The admin console receives live updates via WebSocket connection to `/api/v1/ws/dashboard`.

### WebSocket Events

| Event Type | Description |
|------------|-------------|
| `initial_state` | Full dashboard state on connection |
| `metrics_update` | Periodic stats update (every 10s) |
| `connection_event` | Client connect/disconnect events |
| `error_event` | System error notifications |
| `audit_event` | Audit log entries |

### Connection Event Reporting

Desktop clients report their connection status to the server:
- **Connected**: Reported when VPN tunnel is established
- **Disconnected**: Reported with traffic stats when tunnel closes
- **Heartbeat**: Sent every 60 seconds while connected

Events are logged to PostgreSQL and published to Redis for real-time dashboard updates.

## Security Considerations

- The VPN client requires root/administrator privileges to create TUN devices
- On Linux, you can use capabilities instead of root: `sudo setcap cap_net_admin=eip ./minnowvpn`
- Private keys are encrypted at rest in the database using AES-256
- JWT tokens expire after 24 hours
- All API endpoints (except health, setup, and SSO flows) require authentication
- WebSocket connections require JWT token passed as query parameter
- SSO tokens are verified using JWKS with RS256 signature validation (Google, Okta)
- Platform-specific secure credential storage (Keychain, Credential Manager, libsecret)

## License

Proprietary

## Contributing

This is a private project. Contact the maintainers for contribution guidelines.
