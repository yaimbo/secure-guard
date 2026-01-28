# SecureGuard: FIPS-Compliant WireGuard Alternative

## Project Overview

A from-scratch implementation of a WireGuard-compatible VPN with dual-mode cryptography (FIPS + Classic), enterprise management features, and cross-platform support.

**Codename:** SecureGuard (internal), public name TBD

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Tunnel Mode** | Userspace only | Simpler, portable, easier to maintain across all platforms |
| **Multi-Tenancy** | Single-org per deployment | Simpler architecture, can be added later if needed |
| **Licensing** | Commercial | Proprietary, paid licenses |
| **Compliance** | FIPS 140-3 only | Focus on core FIPS requirement |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MANAGEMENT PLANE                                   │
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────────────────┐ │
│  │  Flutter Web    │  │  REST API        │  │  Config Distribution        │ │
│  │  Admin Console  │  │  (Rust/Axum)     │  │  Service                    │ │
│  └────────┬────────┘  └────────┬─────────┘  └──────────────┬──────────────┘ │
│           │                    │                           │                 │
│           └────────────────────┴───────────────────────────┘                 │
│                                    │                                         │
│                         ┌──────────┴──────────┐                              │
│                         │   PostgreSQL        │                              │
│                         │   (State/Audit)     │                              │
│                         └─────────────────────┘                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                          ┌──────────┴──────────┐
                          │   Redis (Sessions,  │
                          │   Temp Configs)     │
                          └─────────────────────┘
                                     │
┌─────────────────────────────────────────────────────────────────────────────┐
│                             DATA PLANE                                       │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     SecureGuard Engine (Rust)                           ││
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐  ││
│  │  │ FIPS Crypto │  │ Classic     │  │ Protocol    │  │ Tunnel         │  ││
│  │  │ Module      │  │ Crypto      │  │ Negotiator  │  │ Manager        │  ││
│  │  │ (AES-GCM,   │  │ (ChaCha20,  │  │             │  │ (TUN/TAP)      │  ││
│  │  │ P-384, SHA) │  │ Curve25519) │  │             │  │                │  ││
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └────────────────┘  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
│  │ Linux    │  │ macOS    │  │ Windows  │  │ Android  │  │ iOS          │   │
│  │ (TUN)    │  │ (utun)   │  │ (Wintun) │  │ (VpnSvc) │  │ (NE)         │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  └──────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Core Cryptographic Engine (Rust)

### 1.1 Dual Cryptographic Backend

**FIPS Mode (Primary):**
| Function | Algorithm | Library |
|----------|-----------|---------|
| Key Exchange | ECDH P-384 | `aws-lc-rs` (FIPS-validated) |
| Encryption | AES-256-GCM | `aws-lc-rs` |
| Hashing | SHA-384 | `aws-lc-rs` |
| KDF | HKDF-SHA384 | `aws-lc-rs` |
| Signatures | ECDSA P-384 | `aws-lc-rs` |

**Classic Mode (WireGuard Compatible):**
| Function | Algorithm | Library |
|----------|-----------|---------|
| Key Exchange | Curve25519 (X25519) | `ring` or `x25519-dalek` |
| Encryption | ChaCha20-Poly1305 | `ring` or `chacha20poly1305` |
| Hashing | BLAKE2s | `blake2` |
| KDF | HKDF-BLAKE2s | Custom |

**Why `aws-lc-rs`:** AWS-LC is a FIPS 140-3 validated cryptographic library with Rust bindings. It's the most practical choice for FIPS compliance in Rust.

### 1.2 Protocol Negotiation

```
Client                                Server
  │                                      │
  │──── Hello (capabilities bitmap) ────►│
  │     [FIPS=1, CLASSIC=1, VERSION=1]   │
  │                                      │
  │◄─── ServerHello (selected mode) ─────│
  │     [MODE=FIPS, SERVER_PUBKEY]       │
  │                                      │
  │──── ClientKeyExchange ──────────────►│
  │     [CLIENT_PUBKEY, PROOF]           │
  │                                      │
  │◄─── Established ─────────────────────│
  │     [SESSION_ID, ENCRYPTED_CONFIG]   │
  │                                      │
  │◄═══ Encrypted Tunnel ═══════════════►│
```

**Capabilities Bitmap:**
- Bit 0: FIPS mode supported
- Bit 1: Classic mode supported
- Bit 2-7: Reserved for future modes
- Bit 8-15: Protocol version

**Fallback Logic:**
1. Server advertises supported modes in order of preference
2. Client sends Hello with its capabilities
3. Server selects highest-priority mutually supported mode
4. If no overlap → connection rejected with clear error

### 1.3 Packet Format

**SecureGuard Header (extends WireGuard):**
```
┌────────────────────────────────────────────────────────────────┐
│ Type (1) │ Mode (1) │ Reserved (2) │ Receiver Index (4)        │
├────────────────────────────────────────────────────────────────┤
│ Counter (8)                                                    │
├────────────────────────────────────────────────────────────────┤
│ Encrypted Payload (variable)                                   │
├────────────────────────────────────────────────────────────────┤
│ Auth Tag (16)                                                  │
└────────────────────────────────────────────────────────────────┘
```

**Mode byte:**
- `0x00`: Classic WireGuard (for backwards compatibility)
- `0x01`: FIPS mode
- `0x02-0xFF`: Reserved

When Mode=0x00, packet format is byte-identical to WireGuard for interop.

### 1.4 Project Structure

```
secureguard-core/
├── Cargo.toml
├── src/
│   ├── lib.rs
│   ├── crypto/
│   │   ├── mod.rs
│   │   ├── fips.rs          # FIPS crypto impl (aws-lc-rs)
│   │   ├── classic.rs       # WireGuard crypto impl
│   │   ├── negotiation.rs   # Mode selection logic
│   │   └── traits.rs        # CryptoBackend trait
│   ├── protocol/
│   │   ├── mod.rs
│   │   ├── handshake.rs     # Noise-like handshake
│   │   ├── packet.rs        # Packet encoding/decoding
│   │   ├── session.rs       # Session state machine
│   │   └── wireguard.rs     # WG compatibility layer
│   ├── tunnel/
│   │   ├── mod.rs
│   │   ├── tun_linux.rs     # Linux TUN device
│   │   ├── tun_macos.rs     # macOS utun
│   │   ├── tun_windows.rs   # Wintun
│   │   ├── tun_android.rs   # Android VpnService
│   │   └── tun_ios.rs       # iOS NetworkExtension
│   └── config/
│       ├── mod.rs
│       ├── parser.rs        # Config file parsing
│       └── generator.rs     # Config generation
```

---

## Phase 2: Platform Abstraction Layer

### 2.1 Platform-Specific Implementations

| Platform | Tunnel Method | Privileges | Notes |
|----------|---------------|------------|-------|
| **Linux** | Userspace TUN (`/dev/net/tun`) | root or CAP_NET_ADMIN | Portable, no kernel module needed |
| **macOS** | utun (userspace) | root | NetworkExtension for App Store |
| **Windows** | Wintun | Administrator | Wintun is the modern choice |
| **Android** | VpnService API | VPN permission | Userspace only, no root |
| **iOS** | NetworkExtension | Entitlement | Must use NE framework |

### 2.2 Rust FFI for Mobile

```rust
// Unified C API for mobile platforms
#[no_mangle]
pub extern "C" fn sg_init(config: *const c_char) -> *mut SGContext;

#[no_mangle]
pub extern "C" fn sg_connect(ctx: *mut SGContext) -> SGResult;

#[no_mangle]
pub extern "C" fn sg_disconnect(ctx: *mut SGContext) -> SGResult;

#[no_mangle]
pub extern "C" fn sg_get_stats(ctx: *mut SGContext) -> *mut SGStats;

#[no_mangle]
pub extern "C" fn sg_free(ctx: *mut SGContext);
```

**Build Targets:**
- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`
- `x86_64-pc-windows-msvc`
- `aarch64-linux-android`
- `armv7-linux-androideabi`
- `aarch64-apple-ios`
- `x86_64-apple-ios` (simulator)

---

## Phase 3: Management Server

### 3.1 Server Components

```
secureguard-server/
├── Cargo.toml
├── src/
│   ├── main.rs
│   ├── api/
│   │   ├── mod.rs
│   │   ├── auth.rs          # JWT + API key auth
│   │   ├── clients.rs       # Client CRUD
│   │   ├── configs.rs       # Config distribution
│   │   ├── networks.rs      # Network/subnet management
│   │   ├── temp_access.rs   # Temporary config issuance
│   │   └── audit.rs         # Audit log queries
│   ├── services/
│   │   ├── mod.rs
│   │   ├── config_generator.rs
│   │   ├── key_manager.rs
│   │   ├── audit_service.rs
│   │   └── notification_service.rs
│   ├── models/
│   │   ├── mod.rs
│   │   ├── client.rs
│   │   ├── network.rs
│   │   ├── config.rs
│   │   └── audit_event.rs
│   └── db/
│       ├── mod.rs
│       ├── postgres.rs
│       └── redis.rs
```

### 3.2 Database Schema (PostgreSQL)

```sql
-- Instance settings (single-org, one row)
CREATE TABLE settings (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- Singleton
    instance_name VARCHAR(255) NOT NULL,
    admin_email VARCHAR(255),
    fips_required BOOLEAN DEFAULT true,
    allow_classic_fallback BOOLEAN DEFAULT true,
    settings JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Networks (VPN networks/subnets)
CREATE TABLE networks (
    id UUID PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    subnet CIDR NOT NULL,
    dns_servers INET[],
    fips_required BOOLEAN DEFAULT true,  -- Override instance setting per network
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Clients (devices/users)
CREATE TABLE clients (
    id UUID PRIMARY KEY,
    network_id UUID REFERENCES networks(id),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    public_key_fips BYTEA,       -- P-384 public key (FIPS mode)
    public_key_classic BYTEA,    -- Curve25519 public key (Classic mode)
    assigned_ip INET NOT NULL,
    allowed_ips CIDR[] DEFAULT '{0.0.0.0/0}',
    persistent_keepalive INTEGER DEFAULT 25,
    is_relay BOOLEAN DEFAULT false,
    enabled BOOLEAN DEFAULT true,
    last_handshake TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(assigned_ip)
);

-- Admin users (for management console)
CREATE TABLE admin_users (
    id UUID PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(50) DEFAULT 'admin',  -- 'super_admin', 'admin', 'viewer'
    enabled BOOLEAN DEFAULT true,
    last_login TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Temporary Access Tokens
CREATE TABLE temp_access (
    id UUID PRIMARY KEY,
    network_id UUID REFERENCES networks(id),
    created_by UUID REFERENCES admin_users(id),
    name VARCHAR(255),           -- Descriptive name (e.g., "Contractor access")
    allowed_ips CIDR[],
    expires_at TIMESTAMPTZ NOT NULL,
    max_uses INTEGER DEFAULT 1,
    current_uses INTEGER DEFAULT 0,
    revoked BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Audit Log (append-only, enterprise requirement)
CREATE TABLE audit_log (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    event_type VARCHAR(100) NOT NULL,
    actor_id UUID,
    actor_type VARCHAR(50),      -- 'admin', 'client', 'system', 'temp_access'
    actor_name VARCHAR(255),     -- Denormalized for log readability
    resource_type VARCHAR(100),
    resource_id UUID,
    resource_name VARCHAR(255),  -- Denormalized
    action VARCHAR(50),          -- 'create', 'update', 'delete', 'connect', etc.
    details JSONB,
    source_ip INET,
    user_agent TEXT
);

-- Connection Log (detailed connection tracking)
CREATE TABLE connection_log (
    id BIGSERIAL PRIMARY KEY,
    client_id UUID REFERENCES clients(id),
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    event VARCHAR(50),           -- 'connected', 'disconnected', 'handshake', 'rekey'
    source_ip INET,
    source_port INTEGER,
    crypto_mode VARCHAR(20),     -- 'fips', 'classic'
    bytes_sent BIGINT DEFAULT 0,
    bytes_received BIGINT DEFAULT 0,
    packets_sent BIGINT DEFAULT 0,
    packets_received BIGINT DEFAULT 0,
    session_duration_ms BIGINT,
    disconnect_reason VARCHAR(255)
);

-- Indexes for query performance
CREATE INDEX idx_clients_network ON clients(network_id);
CREATE INDEX idx_clients_enabled ON clients(enabled) WHERE enabled = true;
CREATE INDEX idx_audit_log_time ON audit_log(timestamp DESC);
CREATE INDEX idx_audit_log_event ON audit_log(event_type, timestamp DESC);
CREATE INDEX idx_audit_log_actor ON audit_log(actor_id, timestamp DESC);
CREATE INDEX idx_connection_log_client ON connection_log(client_id, timestamp DESC);
CREATE INDEX idx_connection_log_time ON connection_log(timestamp DESC);
CREATE INDEX idx_temp_access_expires ON temp_access(expires_at) WHERE NOT revoked;
```

### 3.3 Redis Schema (Sessions & Real-Time State)

```
sg:session:{client_id}              # HASH: Active session state (endpoint, crypto_mode, connected_at)
sg:session:{client_id}:stats        # HASH: Real-time stats (bytes_in, bytes_out, packets)
sg:temp_config:{token}              # STRING: Encrypted temp config (TTL = expires_at)
sg:rate_limit:{ip}                  # STRING: Counter with TTL (rate limiting)
sg:client:online:{client_id}        # STRING: Last seen timestamp (TTL 60s heartbeat)
sg:network:{network_id}:online      # SET: Currently online client IDs
sg:metrics:connections              # STRING: Total active connections (gauge)
sg:metrics:bandwidth:{in|out}       # STRING: Total bandwidth counters
sg:handshake:nonce:{client_id}      # STRING: Anti-replay nonce (short TTL)
```

### 3.4 API Endpoints

**Authentication:**
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/auth/login` | User login (JWT) |
| POST | `/api/auth/refresh` | Refresh JWT |
| POST | `/api/auth/client` | Client authentication (returns session) |

**Client Management:**
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/clients` | List clients |
| POST | `/api/clients` | Create client |
| GET | `/api/clients/:id` | Get client details |
| PUT | `/api/clients/:id` | Update client |
| DELETE | `/api/clients/:id` | Delete client |
| GET | `/api/clients/:id/config` | Download client config |
| POST | `/api/clients/:id/regenerate-keys` | Regenerate keys |

**Network Management:**
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/networks` | List networks |
| POST | `/api/networks` | Create network |
| GET | `/api/networks/:id` | Get network details |
| PUT | `/api/networks/:id` | Update network |
| GET | `/api/networks/:id/peers` | Get peer list (for config) |

**Temporary Access:**
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/temp-access` | Create temp access token |
| GET | `/api/temp-access/:token` | Validate & get config |
| DELETE | `/api/temp-access/:token` | Revoke token |
| GET | `/api/temp-access` | List active tokens |

**Audit & Logging:**
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/audit` | Query audit log |
| GET | `/api/connections` | Query connection log |
| GET | `/api/audit/export` | Export audit log (CSV/JSON) |

---

## Phase 4: Flutter Applications

### 4.1 Application Matrix

| App | Platforms | Purpose |
|-----|-----------|---------|
| **SecureGuard Admin** | Web, macOS, Windows, Linux | Management console |
| **SecureGuard Client** | Android, iOS, macOS, Windows, Linux | VPN client |

### 4.2 Admin Console (Flutter Web/Desktop)

```
secureguard-admin/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── providers/
│   │   ├── auth_provider.dart
│   │   ├── clients_provider.dart
│   │   ├── networks_provider.dart
│   │   └── audit_provider.dart
│   ├── services/
│   │   ├── api_service.dart
│   │   └── websocket_service.dart
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── dashboard_screen.dart
│   │   │   ├── clients_screen.dart
│   │   │   ├── networks_screen.dart
│   │   │   ├── temp_access_screen.dart
│   │   │   ├── audit_screen.dart
│   │   │   └── settings_screen.dart
│   │   └── widgets/
│   │       ├── client_card.dart
│   │       ├── network_topology.dart
│   │       ├── connection_chart.dart
│   │       └── audit_table.dart
│   └── models/
│       ├── client.dart
│       ├── network.dart
│       └── audit_event.dart
```

**Key Screens:**

1. **Dashboard**
   - Active connections (real-time)
   - Bandwidth graphs
   - Recent audit events
   - System health

2. **Clients**
   - Client list with status
   - Create/edit/delete clients
   - Config download (QR code for mobile)
   - Key regeneration

3. **Networks**
   - Network topology visualization
   - Subnet management
   - DNS configuration
   - FIPS enforcement toggle

4. **Temporary Access**
   - Generate time-limited tokens
   - QR codes for easy distribution
   - Token revocation
   - Usage tracking

5. **Audit Log**
   - Searchable audit trail
   - Filter by event type, user, time
   - Export functionality
   - Real-time streaming

### 4.3 Client Application (Flutter + Rust FFI)

```
secureguard-client/
├── lib/
│   ├── main.dart
│   ├── providers/
│   │   ├── vpn_provider.dart
│   │   └── config_provider.dart
│   ├── services/
│   │   ├── vpn_service.dart      # FFI wrapper
│   │   ├── config_service.dart
│   │   └── notification_service.dart
│   ├── ui/
│   │   ├── screens/
│   │   │   ├── home_screen.dart
│   │   │   ├── config_screen.dart
│   │   │   └── settings_screen.dart
│   │   └── widgets/
│   │       ├── connection_button.dart
│   │       ├── status_indicator.dart
│   │       └── traffic_stats.dart
│   └── ffi/
│       └── secureguard_bindings.dart
├── rust/                          # Rust library
│   ├── Cargo.toml
│   └── src/
│       └── lib.rs
├── android/
│   └── app/src/main/
│       └── kotlin/.../VpnService.kt
└── ios/
    └── Runner/
        └── PacketTunnelProvider.swift
```

**Platform Integration:**

**Android:**
```kotlin
class SecureGuardVpnService : VpnService() {
    external fun nativeStart(fd: Int, config: String): Boolean
    external fun nativeStop()
    external fun nativeGetStats(): String

    companion object {
        init {
            System.loadLibrary("secureguard")
        }
    }
}
```

**iOS:**
```swift
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelHandle: OpaquePointer?

    override func startTunnel(options: [String: NSObject]?) async throws {
        let fd = packetFlow.value(forKey: "socket") as! Int32
        tunnelHandle = sg_init(config.cString(using: .utf8))
        sg_connect(tunnelHandle)
    }
}
```

---

## Phase 5: Enterprise Features

### 5.1 Audit System

**Event Categories:**
| Category | Events |
|----------|--------|
| Authentication | `user.login`, `user.logout`, `user.failed_login`, `client.auth` |
| Client Management | `client.created`, `client.updated`, `client.deleted`, `client.keys_regenerated` |
| Network | `network.created`, `network.updated`, `network.deleted` |
| Connections | `connection.established`, `connection.terminated`, `connection.failed` |
| Temp Access | `temp_access.created`, `temp_access.used`, `temp_access.revoked`, `temp_access.expired` |
| Configuration | `config.downloaded`, `config.generated` |
| Admin | `settings.updated`, `org.updated` |

**Audit Event Schema:**
```json
{
  "id": 12345,
  "timestamp": "2025-01-28T12:00:00Z",
  "event_type": "client.created",
  "actor": {
    "id": "user_789",
    "type": "admin",
    "name": "admin@example.com"
  },
  "resource": {
    "type": "client",
    "id": "client_abc",
    "name": "John's Laptop"
  },
  "action": "create",
  "details": {
    "network_id": "net_xyz",
    "assigned_ip": "10.0.0.5",
    "fips_enabled": true
  },
  "source_ip": "203.0.113.45",
  "user_agent": "SecureGuard Admin/1.0"
}
```

### 5.2 Enterprise Logging

**Log Levels:**
- `ERROR`: Failures, security events
- `WARN`: Degraded performance, fallback to classic mode
- `INFO`: Connections, handshakes, config changes
- `DEBUG`: Protocol details (disabled in production)

**Structured Logging (JSON):**
```json
{
  "timestamp": "2025-01-28T12:00:00.123Z",
  "level": "INFO",
  "component": "tunnel",
  "event": "handshake_complete",
  "client_id": "client_abc",
  "crypto_mode": "fips",
  "latency_ms": 45,
  "source_ip": "203.0.113.45"
}
```

**Log Destinations:**
- File (rotating)
- Syslog
- CloudWatch/Datadog/Splunk integration
- Kafka for high-volume deployments

### 5.3 Temporary Config Distribution

**Flow:**
```
Admin                    Server                    Guest
  │                         │                         │
  │── Create temp access ──►│                         │
  │   (duration, max_uses)  │                         │
  │                         │                         │
  │◄── Token + QR code ─────│                         │
  │                         │                         │
  │   (Admin shares QR)     │                         │
  │                         │                         │
  │                         │◄── Scan QR / Enter ─────│
  │                         │    token                │
  │                         │                         │
  │                         │── Validate token ──────►│
  │                         │                         │
  │                         │── Generate ephemeral ──►│
  │                         │   keys + config         │
  │                         │                         │
  │                         │◄══ Tunnel (time-limited)│
  │                         │                         │
  │                         │── Expire + cleanup ────►│
```

**Temp Config Properties:**
- Time-limited (1 hour to 7 days)
- Use-limited (1 to unlimited)
- Can restrict to specific subnets
- Auto-cleanup on expiration
- Full audit trail

---

## Phase 6: Security Considerations

### 6.1 Key Management

| Key Type | Storage | Rotation |
|----------|---------|----------|
| Server private key | HSM or encrypted file | Annual |
| Client private keys | Secure enclave (mobile) or encrypted file | On demand |
| Session keys | Memory only | Per session |
| Temp access keys | Ephemeral, Redis with TTL | Per use |

### 6.2 FIPS Compliance Checklist

- [ ] Use `aws-lc-rs` with FIPS module enabled
- [ ] Disable classic mode in FIPS-only deployments
- [ ] FIPS 140-3 certificate documentation
- [ ] Key storage in FIPS-approved HSM (optional)
- [ ] Audit log integrity verification
- [ ] No hardcoded keys or secrets

### 6.3 Threat Model

| Threat | Mitigation |
|--------|------------|
| Key compromise | Immediate key revocation, forward secrecy |
| MITM | Certificate pinning, authenticated handshake |
| Replay attacks | Nonce/counter per session |
| DoS | Rate limiting, connection limits |
| Privilege escalation | Minimal privileges, sandboxing |

---

## Implementation Roadmap

### Milestone 1: Core Crypto & Protocol (6-8 weeks)
- [ ] Set up Rust workspace with `aws-lc-rs` (FIPS) and `ring` (Classic)
- [ ] Implement `CryptoBackend` trait with FIPS and Classic implementations
- [ ] Protocol negotiation handshake
- [ ] Packet encoding/decoding with dual-mode support
- [ ] Session state machine
- [ ] Comprehensive crypto unit tests
- [ ] WireGuard interop tests (Classic mode)

### Milestone 2: Linux Tunnel & Server (4-6 weeks)
- [ ] Linux userspace TUN implementation
- [ ] Server binary with config file support
- [ ] Basic peer management
- [ ] UDP listener with connection handling
- [ ] Integration tests with real tunnels

### Milestone 3: Cross-Platform Engine (6-8 weeks)
- [ ] macOS utun implementation
- [ ] Windows Wintun implementation
- [ ] C FFI layer for mobile
- [ ] Android JNI bindings
- [ ] iOS Swift bindings
- [ ] Cross-compile CI/CD pipeline

### Milestone 4: Management Server (6-8 weeks)
- [ ] Axum REST API skeleton
- [ ] PostgreSQL schema & migrations (SQLx)
- [ ] JWT authentication
- [ ] Client CRUD endpoints
- [ ] Network management endpoints
- [ ] Config generation service
- [ ] Real-time connection tracking (Redis)

### Milestone 5: Admin Console - Flutter Web (4-6 weeks)
- [ ] Flutter web app scaffold
- [ ] Authentication flow
- [ ] Dashboard with real-time metrics
- [ ] Client management UI
- [ ] Network management UI
- [ ] Audit log viewer with filters

### Milestone 6: Client Apps (8-10 weeks)
- [ ] Flutter client app scaffold
- [ ] Rust FFI integration (`flutter_rust_bridge`)
- [ ] Android VpnService full implementation
- [ ] iOS NetworkExtension full implementation
- [ ] macOS/Windows/Linux desktop apps
- [ ] Config import (file, QR code, URL)
- [ ] Connection status & stats UI

### Milestone 7: Enterprise Features (4-6 weeks)
- [ ] Temporary access token system
- [ ] QR code generation for config distribution
- [ ] Full audit logging with retention
- [ ] Structured logging (JSON) with syslog export
- [ ] Admin roles (super_admin, admin, viewer)

### Milestone 8: Hardening & Release (4 weeks)
- [ ] Security audit (internal or third-party)
- [ ] FIPS 140-3 compliance documentation
- [ ] Performance benchmarking
- [ ] User documentation
- [ ] Deployment guides (Docker, bare metal)
- [ ] License key system

**Total Estimated Timeline: 42-56 weeks (~10-14 months)**

---

## Technology Stack Summary

| Component | Technology | Rationale |
|-----------|------------|-----------|
| **Core Engine** | Rust | Memory safety, performance, cross-platform |
| **FIPS Crypto** | `aws-lc-rs` | FIPS 140-3 validated, well-maintained |
| **Classic Crypto** | `ring` | WireGuard-compatible algorithms |
| **Server Framework** | Axum | Async, ergonomic, Tokio-based |
| **Database** | PostgreSQL + SQLx | Type-safe queries, migrations |
| **Cache/Sessions** | Redis | Real-time state, pub/sub |
| **Admin Console** | Flutter Web | Code reuse with Yaimbo, responsive |
| **Client Apps** | Flutter + Rust FFI | Single codebase, native performance |
| **Mobile FFI** | `flutter_rust_bridge` | Generates Dart bindings automatically |
| **Windows Tunnel** | Wintun | Modern, WireGuard-proven |
| **Build** | Cargo, Flutter, GitHub Actions | CI/CD for all platforms |

---

## Verification Plan

### Unit Tests
- Crypto operations (encrypt/decrypt round-trip, key derivation)
- Protocol negotiation (FIPS→FIPS, FIPS→Classic fallback, Classic→Classic)
- Packet encoding/decoding
- Config parsing

### Integration Tests
- Full handshake between Rust server and Rust client
- WireGuard interop (Classic mode with official `wg` client)
- Tunnel data transfer (ping, TCP throughput)
- Mobile FFI smoke tests

### End-to-End Tests
- Admin console → API → Database → Engine flow
- Client app → Server → Internet connectivity
- Temp access token generation and redemption
- Audit log generation and query

### Performance Tests
- Handshake latency (target: <100ms)
- Throughput (target: >500 Mbps on modern hardware)
- Memory usage under load
- Connection scalability (1000+ concurrent clients)

---

## Remaining Questions

1. **Product Name**: "SecureGuard" is a placeholder. What should the commercial product be called?

2. **Mobile Distribution**: App Store / Play Store, or enterprise-only (MDM) distribution?

3. **License System**: Build custom license validation, or integrate with existing system (e.g., Keygen, LemonSqueezy)?
