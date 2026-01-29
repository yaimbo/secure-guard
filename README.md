# SecureGuard VPN

A WireGuard-compatible VPN solution with enterprise management capabilities.

## Overview

SecureGuard is a complete VPN management platform consisting of:

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

### Admin Console (Flutter Web)
- Dashboard with connection statistics
- Client management (create, edit, enable/disable, delete)
- Manual config download and QR code generation
- Audit log viewer
- Dark/light theme support

### Desktop Client (Flutter)
- Native macOS, Windows, and Linux support
- System tray integration with connection status icons
- Custom draggable title bar with window controls
- IPC communication with Rust daemon (JSON-RPC 2.0)
- Auto-update functionality:
  - Periodic config version checking (every 5 minutes)
  - Automatic binary update detection (every hour)
  - SHA256 hash verification for downloads
  - Ed25519 signature verification framework
- Seamless config updates while connected
- Traffic statistics (bytes sent/received)
- Error handling with retry support

## Quick Start

### Prerequisites

- Rust 1.70+ (for VPN client)
- Dart 3.0+ (for server)
- Flutter 3.16+ (for console)
- PostgreSQL 14+ (for server database)

### 1. Build the VPN Client

```bash
cargo build --release
```

### 2. Start the Server

```bash
cd secureguard-server

# Configure database connection
cp .env.example .env
# Edit .env with your PostgreSQL credentials

# Install dependencies and run
dart pub get
dart run bin/server.dart
```

### 3. Start the Admin Console

```bash
cd secureguard_console
flutter pub get
flutter run -d chrome --dart-define=API_URL=http://localhost:8080/api/v1
```

Or use the convenience script:
```bash
cd secureguard_console
./start.sh
```

### 4. Build the Desktop Client

```bash
cd secureguard_client
flutter pub get

# Run in development mode (requires daemon running)
flutter run -d macos   # or -d linux, -d windows

# Build for production
flutter build macos --release   # or linux, windows
```

## Usage

### VPN Client Modes

#### Client Mode (Connect to VPN Server)
```bash
# Auto-detected if peer has Endpoint
sudo ./target/release/secureguard-poc -c client.conf

# Force client mode
sudo ./target/release/secureguard-poc -c client.conf --client

# With verbose logging
sudo ./target/release/secureguard-poc -c client.conf -v
```

#### Server Mode (Accept Incoming Connections)
```bash
# Auto-detected if ListenPort set and no peer Endpoint
sudo ./target/release/secureguard-poc -c server.conf

# Force server mode
sudo ./target/release/secureguard-poc -c server.conf --server
```

#### Daemon Mode (For UI Control)
```bash
# Run as daemon with default socket
sudo ./target/release/secureguard-poc --daemon

# Run with custom socket path
sudo ./target/release/secureguard-poc --daemon --socket /custom/path.sock
```

### Daemon IPC Protocol

The daemon accepts JSON-RPC 2.0 commands over Unix socket (`/var/run/secureguard.sock`).

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
- Binary to `/Library/PrivilegedHelperTools/secureguard-service`
- LaunchDaemon plist to `/Library/LaunchDaemons/`
- Logs to `/var/log/secureguard.log`

**Service commands:**
```bash
# Stop service
sudo launchctl unload /Library/LaunchDaemons/com.secureguard.vpn-service.plist

# Start service
sudo launchctl load /Library/LaunchDaemons/com.secureguard.vpn-service.plist

# Check status
sudo launchctl list | grep secureguard

# View logs
tail -f /var/log/secureguard.log
```

### Linux (systemd)

```bash
# Build release binary
cargo build --release

# Install as system service
sudo ./installer/linux/install.sh
```

This installs:
- Binary to `/usr/local/bin/secureguard-service`
- systemd unit to `/etc/systemd/system/secureguard.service`
- Sets required capabilities (CAP_NET_ADMIN)

**Service commands:**
```bash
sudo systemctl status secureguard
sudo systemctl stop secureguard
sudo systemctl start secureguard
sudo journalctl -u secureguard -f
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
┌─────────────────────────────────────────────────────────────────┐
│                     MANAGEMENT PLANE                            │
│  ┌─────────────────┐  ┌──────────────────┐                     │
│  │  Flutter Web    │  │  Dart REST API   │                     │
│  │  Admin Console  │  │  Server          │                     │
│  └────────┬────────┘  └────────┬─────────┘                     │
│           │                    │                                │
│           └────────────────────┴──────────────┐                │
│                                               │                 │
│                              ┌────────────────┴───────────────┐│
│                              │   PostgreSQL                   ││
│                              └────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              │                     │                     │
              ▼                     ▼                     ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────┐
│  SecureGuard Client │  │  SecureGuard Client │  │ Legacy WireGuard│
│  (Flutter + Rust)   │  │  (CLI Mode)         │  │ (manual config) │
│  Desktop App        │  │                     │  │                 │
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
DB_HOST=localhost
DB_PORT=5432
DB_NAME=secureguard
DB_USER=secureguard
DB_PASSWORD=your_password
JWT_SECRET=your_jwt_secret
PORT=8080
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
cd secureguard-server
dart pub get
dart run bin/server.dart
```

### Console (Flutter Web)

```bash
cd secureguard_console
flutter pub get

# Development
flutter run -d chrome

# Production build
flutter build web --release
```

### Desktop Client (Flutter)

```bash
cd secureguard_client
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

## Security Considerations

- The VPN client requires root/administrator privileges to create TUN devices
- On Linux, you can use capabilities instead of root: `sudo setcap cap_net_admin=eip ./secureguard-poc`
- Private keys are encrypted at rest in the database
- JWT tokens expire after 24 hours
- All API endpoints (except health and setup) require authentication

## License

Proprietary

## Contributing

This is a private project. Contact the maintainers for contribution guidelines.
