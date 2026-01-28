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

### CLI Usage

```bash
# Client mode (auto-detected if peer has Endpoint)
./secureguard-poc -c client.conf

# Server mode (auto-detected if ListenPort set and no peer Endpoint)
./secureguard-poc -c server.conf

# Force specific mode
./secureguard-poc -c config.conf --server
./secureguard-poc -c config.conf --client
```

### Key Implementation Details

1. **HMAC Construction**: Uses `SimpleHmac<Blake2s256>` (RFC 2104) for KDFs, not BLAKE2s keyed mode. This is critical for handshake compatibility.

2. **Endpoint Bypass Routing**: Routes must be set up AFTER handshake completes. A specific route for the VPN endpoint goes through the default gateway to prevent routing loops.

3. **Session Rekey**: Sessions automatically rekey after 120 seconds. Old session remains valid during rekey.

### Debug Binaries

Various verification tools in `src/bin/` for testing crypto primitives against known test vectors.


