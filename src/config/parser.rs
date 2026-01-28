//! WireGuard configuration file parser
//!
//! Parses standard WireGuard `.conf` files with [Interface] and [Peer] sections.

use std::net::{IpAddr, SocketAddr};
use std::path::Path;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ipnet::IpNet;

use crate::error::ConfigError;

/// Complete WireGuard configuration
#[derive(Debug, Clone)]
pub struct WireGuardConfig {
    /// Interface configuration (our side)
    pub interface: InterfaceConfig,
    /// Peer configurations
    pub peers: Vec<PeerConfig>,
}

/// Interface (local) configuration
#[derive(Debug, Clone)]
pub struct InterfaceConfig {
    /// Our private key (32 bytes)
    pub private_key: [u8; 32],
    /// Our VPN IP addresses with prefix
    pub address: Vec<ipnet::Ipv4Net>,
    /// DNS servers (optional)
    pub dns: Vec<IpAddr>,
    /// Listen port (optional, for servers)
    pub listen_port: Option<u16>,
    /// MTU (optional, default 1420)
    pub mtu: Option<u16>,
    /// Pre-shared key (optional, stored here for convenience)
    pub preshared_key: Option<[u8; 32]>,
}

/// Peer configuration
#[derive(Debug, Clone)]
pub struct PeerConfig {
    /// Peer's public key (32 bytes)
    pub public_key: [u8; 32],
    /// Pre-shared key (optional, 32 bytes)
    pub preshared_key: Option<[u8; 32]>,
    /// Peer's endpoint (IP:port)
    pub endpoint: Option<SocketAddr>,
    /// Allowed IP ranges for this peer
    pub allowed_ips: Vec<IpNet>,
    /// Keepalive interval in seconds (optional)
    pub persistent_keepalive: Option<u16>,
}

impl WireGuardConfig {
    /// Parse a WireGuard configuration from a file
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, ConfigError> {
        let path = path.as_ref();
        let content = std::fs::read_to_string(path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                ConfigError::FileNotFound {
                    path: path.display().to_string(),
                }
            } else {
                ConfigError::Io(e)
            }
        })?;
        Self::parse(&content)
    }

    /// Parse a WireGuard configuration from a string
    pub fn parse(content: &str) -> Result<Self, ConfigError> {
        let mut interface: Option<InterfaceConfig> = None;
        let mut peers: Vec<PeerConfig> = Vec::new();
        let mut current_section: Option<Section> = None;

        // Temporary storage for current peer being parsed
        let mut current_peer: Option<PeerBuilder> = None;

        for (line_num, line) in content.lines().enumerate() {
            let line_num = line_num + 1; // 1-indexed
            let line = line.trim();

            // Skip empty lines and comments
            if line.is_empty() || line.starts_with('#') {
                continue;
            }

            // Check for section headers
            if line.eq_ignore_ascii_case("[interface]") {
                // Save any pending peer
                if let Some(peer) = current_peer.take() {
                    peers.push(peer.build()?);
                }
                current_section = Some(Section::Interface);
                continue;
            } else if line.eq_ignore_ascii_case("[peer]") {
                // Save any pending peer
                if let Some(peer) = current_peer.take() {
                    peers.push(peer.build()?);
                }
                current_section = Some(Section::Peer);
                current_peer = Some(PeerBuilder::new());
                continue;
            }

            // Parse key = value pairs
            let Some((key, value)) = line.split_once('=') else {
                return Err(ConfigError::ParseError {
                    line: line_num,
                    message: format!("Expected 'key = value', got: {}", line),
                });
            };

            let key = key.trim().to_lowercase();
            let value = value.trim();

            match current_section {
                Some(Section::Interface) => {
                    let iface = interface.get_or_insert_with(|| InterfaceConfig {
                        private_key: [0u8; 32],
                        address: Vec::new(),
                        dns: Vec::new(),
                        listen_port: None,
                        mtu: None,
                        preshared_key: None,
                    });

                    match key.as_str() {
                        "privatekey" => {
                            iface.private_key = parse_key(value, "PrivateKey")?;
                        }
                        "address" => {
                            // May have multiple addresses separated by comma
                            for addr_str in value.split(',') {
                                let addr_str = addr_str.trim();
                                if addr_str.is_empty() {
                                    continue;
                                }
                                // Parse as IpNet first, then extract Ipv4Net
                                let ip_net: IpNet = addr_str.parse().map_err(|_| ConfigError::InvalidCidr {
                                    value: addr_str.to_string(),
                                })?;
                                if let IpNet::V4(v4net) = ip_net {
                                    iface.address.push(v4net);
                                }
                            }
                        }
                        "dns" => {
                            for dns_str in value.split(',') {
                                let dns_str = dns_str.trim();
                                let dns: IpAddr =
                                    dns_str.parse().map_err(|_| ConfigError::InvalidAddress {
                                        value: dns_str.to_string(),
                                    })?;
                                iface.dns.push(dns);
                            }
                        }
                        "listenport" => {
                            iface.listen_port = Some(value.parse().map_err(|_| {
                                ConfigError::ParseError {
                                    line: line_num,
                                    message: format!("Invalid ListenPort: {}", value),
                                }
                            })?);
                        }
                        "mtu" => {
                            iface.mtu =
                                Some(value.parse().map_err(|_| ConfigError::ParseError {
                                    line: line_num,
                                    message: format!("Invalid MTU: {}", value),
                                })?);
                        }
                        _ => {
                            // Unknown key, ignore (forward compatibility)
                            tracing::debug!("Unknown interface key: {}", key);
                        }
                    }
                }
                Some(Section::Peer) => {
                    let peer = current_peer.as_mut().ok_or(ConfigError::ParseError {
                        line: line_num,
                        message: "Peer value outside of [Peer] section".to_string(),
                    })?;

                    match key.as_str() {
                        "publickey" => {
                            peer.public_key = Some(parse_key(value, "PublicKey")?);
                        }
                        "presharedkey" => {
                            peer.preshared_key = Some(parse_key(value, "PresharedKey")?);
                        }
                        "endpoint" => {
                            peer.endpoint = Some(parse_endpoint(value)?);
                        }
                        "allowedips" => {
                            for ip_str in value.split(',') {
                                let ip_str = ip_str.trim();
                                if ip_str.is_empty() {
                                    continue;
                                }
                                let ip: IpNet =
                                    ip_str.parse().map_err(|_| ConfigError::InvalidCidr {
                                        value: ip_str.to_string(),
                                    })?;
                                peer.allowed_ips.push(ip);
                            }
                        }
                        "persistentkeepalive" => {
                            peer.persistent_keepalive =
                                Some(value.parse().map_err(|_| ConfigError::ParseError {
                                    line: line_num,
                                    message: format!("Invalid PersistentKeepalive: {}", value),
                                })?);
                        }
                        _ => {
                            // Unknown key, ignore
                            tracing::debug!("Unknown peer key: {}", key);
                        }
                    }
                }
                None => {
                    return Err(ConfigError::ParseError {
                        line: line_num,
                        message: "Configuration value outside of any section".to_string(),
                    });
                }
            }
        }

        // Save any pending peer
        if let Some(peer) = current_peer.take() {
            peers.push(peer.build()?);
        }

        let mut interface = interface.ok_or(ConfigError::MissingField {
            field: "[Interface] section".to_string(),
        })?;

        // Validate interface has required fields
        if interface.private_key == [0u8; 32] {
            return Err(ConfigError::MissingField {
                field: "PrivateKey".to_string(),
            });
        }

        // Copy PSK from first peer to interface for convenience
        if let Some(peer) = peers.first() {
            interface.preshared_key = peer.preshared_key;
        }

        Ok(WireGuardConfig { interface, peers })
    }

    /// Get our public key derived from the private key
    pub fn public_key(&self) -> [u8; 32] {
        crate::crypto::x25519::public_key(&self.interface.private_key)
    }
}

/// Section type during parsing
#[derive(Clone, Copy)]
enum Section {
    Interface,
    Peer,
}

/// Builder for PeerConfig during parsing
struct PeerBuilder {
    public_key: Option<[u8; 32]>,
    preshared_key: Option<[u8; 32]>,
    endpoint: Option<SocketAddr>,
    allowed_ips: Vec<IpNet>,
    persistent_keepalive: Option<u16>,
}

impl PeerBuilder {
    fn new() -> Self {
        Self {
            public_key: None,
            preshared_key: None,
            endpoint: None,
            allowed_ips: Vec::new(),
            persistent_keepalive: None,
        }
    }

    fn build(self) -> Result<PeerConfig, ConfigError> {
        let public_key = self.public_key.ok_or(ConfigError::MissingField {
            field: "PublicKey in [Peer]".to_string(),
        })?;

        Ok(PeerConfig {
            public_key,
            preshared_key: self.preshared_key,
            endpoint: self.endpoint,
            allowed_ips: self.allowed_ips,
            persistent_keepalive: self.persistent_keepalive,
        })
    }
}

/// Parse a base64-encoded 32-byte key
fn parse_key(value: &str, field_name: &str) -> Result<[u8; 32], ConfigError> {
    let bytes = BASE64
        .decode(value)
        .map_err(|_| ConfigError::InvalidKey {
            field: field_name.to_string(),
        })?;

    if bytes.len() != 32 {
        return Err(ConfigError::InvalidKey {
            field: field_name.to_string(),
        });
    }

    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    Ok(key)
}

/// Parse an endpoint (host:port)
fn parse_endpoint(value: &str) -> Result<SocketAddr, ConfigError> {
    // Try to parse as IP:port first
    if let Ok(addr) = value.parse::<SocketAddr>() {
        return Ok(addr);
    }

    // If that fails, it might be hostname:port
    // For simplicity, we require IP addresses in the PoC
    Err(ConfigError::InvalidAddress {
        value: value.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_CONFIG: &str = r#"
[Interface]
PrivateKey = UOvtcWdILFwjb1UnsnK+a9lcqYvNTmtPv+fvqIVOz3w=
Address = 10.0.0.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=
AllowedIPs = 10.0.0.0/24, 0.0.0.0/0
Endpoint = 13.239.46.151:51820
PersistentKeepalive = 25
"#;

    #[test]
    fn test_parse_config() {
        let config = WireGuardConfig::parse(TEST_CONFIG).unwrap();

        // Check interface
        assert_eq!(config.interface.address.len(), 1);
        assert_eq!(config.interface.address[0].to_string(), "10.0.0.2/24");
        assert_eq!(config.interface.dns.len(), 1);
        assert_eq!(config.interface.dns[0].to_string(), "8.8.8.8");

        // Check peer
        assert_eq!(config.peers.len(), 1);
        let peer = &config.peers[0];
        assert_eq!(peer.endpoint.unwrap().to_string(), "13.239.46.151:51820");
        assert_eq!(peer.persistent_keepalive, Some(25));
        assert_eq!(peer.allowed_ips.len(), 2);
    }

    #[test]
    fn test_parse_key() {
        let key_b64 = "UOvtcWdILFwjb1UnsnK+a9lcqYvNTmtPv+fvqIVOz3w=";
        let key = parse_key(key_b64, "TestKey").unwrap();
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn test_invalid_key() {
        let result = parse_key("invalid-base64!", "TestKey");
        assert!(result.is_err());

        let result = parse_key("dG9vIHNob3J0", "TestKey"); // "too short" in base64
        assert!(result.is_err());
    }

    #[test]
    fn test_missing_interface() {
        let config = "[Peer]\nPublicKey = YgkBjKXER5YarD8STsvMFURw/5nhCLIFOJ5uKWrrMW4=\n";
        let result = WireGuardConfig::parse(config);
        assert!(result.is_err());
    }

    #[test]
    fn test_missing_private_key() {
        let config = "[Interface]\nAddress = 10.0.0.2/24\n";
        let result = WireGuardConfig::parse(config);
        assert!(result.is_err());
    }
}
