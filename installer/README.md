# SecureGuard VPN Service Installers

Platform-specific installers for the SecureGuard VPN daemon service.

## Overview

The SecureGuard VPN daemon runs as a system service, providing an IPC socket
for the Flutter desktop client to control VPN connections. The daemon requires
elevated privileges to create TUN devices for VPN tunneling.

## Prerequisites

Before installing, build the release binary:

```bash
cargo build --release
```

The binary will be at `target/release/secureguard-poc` (or `secureguard-poc.exe` on Windows).

## macOS Installation

### Install

```bash
cd installer/macos
sudo ./install.sh
```

The installer will:
- Install binary to `/Library/PrivilegedHelperTools/secureguard-service`
- Install LaunchDaemon plist to `/Library/LaunchDaemons/`
- Create data directory at `/var/lib/secureguard`
- Create IPC socket at `/var/run/secureguard.sock`
- Start the service automatically

### Uninstall

```bash
cd installer/macos
sudo ./uninstall.sh          # Preserves data and logs
sudo ./uninstall.sh --all    # Removes everything
```

### Management Commands

```bash
# Check status
sudo launchctl list | grep secureguard

# Stop service
sudo launchctl bootout system/com.secureguard.vpn-service

# Start service
sudo launchctl bootstrap system /Library/LaunchDaemons/com.secureguard.vpn-service.plist

# View logs
tail -f /var/log/secureguard.log
```

### Security Features

- Runs as root (required for TUN device)
- Strict file permissions (0077 umask)
- Resource limits configured
- Sandbox profile available (optional)
- Socket permissions restricted

## Linux Installation

### Install

```bash
cd installer/linux
sudo ./install.sh
```

The installer will:
- Install binary to `/usr/local/bin/secureguard-service`
- Install systemd unit to `/etc/systemd/system/secureguard.service`
- Set required capabilities (CAP_NET_ADMIN, CAP_NET_RAW)
- Create data directory at `/var/lib/secureguard`
- Create IPC socket at `/var/run/secureguard/secureguard.sock`
- Enable and start the service

### Uninstall

```bash
cd installer/linux
sudo ./uninstall.sh          # Preserves data and logs
sudo ./uninstall.sh --all    # Removes everything
```

### Management Commands

```bash
# Check status
sudo systemctl status secureguard

# Stop service
sudo systemctl stop secureguard

# Start service
sudo systemctl start secureguard

# Restart service
sudo systemctl restart secureguard

# View logs
sudo journalctl -u secureguard -f
```

### Security Features (systemd hardening)

- **Filesystem**: ProtectSystem=strict, ProtectHome=yes, PrivateTmp=yes
- **Capabilities**: Limited to CAP_NET_ADMIN, CAP_NET_RAW, CAP_NET_BIND_SERVICE
- **Memory**: MemoryDenyWriteExecute=yes
- **Syscalls**: SystemCallFilter restricts to safe syscalls
- **Namespaces**: PrivateIPC=yes, RestrictNamespaces=yes
- **Privilege**: NoNewPrivileges=yes, LockPersonality=yes
- **Address Families**: Restricted to AF_INET, AF_INET6, AF_UNIX, AF_NETLINK

## Windows Installation

### PowerShell Install (Manual)

Run PowerShell as Administrator:

```powershell
cd installer\windows
.\install.ps1
```

Or specify a custom binary path:

```powershell
.\install.ps1 -BinaryPath "C:\path\to\secureguard-service.exe"
```

### PowerShell Uninstall

```powershell
.\install.ps1 -Uninstall
```

### NSIS Installer (GUI)

Build the installer (requires NSIS 3.0+):

```bash
cd installer/windows
makensis secureguard.nsi
```

This creates `SecureGuard-1.0.0-Setup.exe` which can be distributed.

### Management Commands (PowerShell as Admin)

```powershell
# Check status
Get-Service SecureGuardVPN

# Stop service
Stop-Service SecureGuardVPN

# Start service
Start-Service SecureGuardVPN

# View logs (Event Viewer)
Get-EventLog -LogName Application -Source SecureGuardVPN
```

### Security Features

- Runs as LocalSystem (required for network adapters)
- Data directory with restricted ACLs (SYSTEM and Administrators only)
- Automatic restart on failure
- Firewall rules for WireGuard UDP traffic

## IPC Socket

The daemon creates an IPC socket for communication with the desktop client:

| Platform | Socket Path |
|----------|-------------|
| macOS | `/var/run/secureguard.sock` |
| Linux | `/var/run/secureguard/secureguard.sock` |
| Windows | `\\.\pipe\secureguard` |

The socket uses JSON-RPC 2.0 protocol. See the main README for protocol details.

## Troubleshooting

### macOS

```bash
# Check if service is loaded
sudo launchctl list | grep secureguard

# Check error log
cat /var/log/secureguard.error.log

# Check system log
log show --predicate 'subsystem == "com.secureguard"' --last 1h
```

### Linux

```bash
# Check service status
sudo systemctl status secureguard

# Check journal logs
sudo journalctl -u secureguard -n 100

# Check if socket exists
ls -la /var/run/secureguard/

# Verify capabilities
getcap /usr/local/bin/secureguard-service
```

### Windows

```powershell
# Check service status
sc query SecureGuardVPN

# Check Event Viewer
Get-EventLog -LogName Application -Source SecureGuardVPN -Newest 20

# Check if pipe exists
[System.IO.Directory]::GetFiles("\\.\pipe\") | Where-Object { $_ -like "*secureguard*" }
```

## Building Cross-Platform Binaries

For distribution, build binaries for each platform:

```bash
# macOS (native)
cargo build --release

# macOS Universal (Intel + Apple Silicon)
cargo build --release --target x86_64-apple-darwin
cargo build --release --target aarch64-apple-darwin
lipo -create target/x86_64-apple-darwin/release/secureguard-poc \
     target/aarch64-apple-darwin/release/secureguard-poc \
     -output secureguard-service-macos-universal

# Linux x86_64 (using cross or native)
cargo build --release --target x86_64-unknown-linux-gnu

# Linux aarch64
cross build --release --target aarch64-unknown-linux-gnu

# Windows x86_64
cargo build --release --target x86_64-pc-windows-msvc
```
