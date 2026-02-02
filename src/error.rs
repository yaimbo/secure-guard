//! Error types for MinnowVPN WireGuard client

use thiserror::Error;

/// Main error type for MinnowVPN
#[derive(Error, Debug)]
pub enum MinnowVpnError {
    /// Configuration errors
    #[error("Config error: {0}")]
    Config(#[from] ConfigError),

    /// Cryptographic errors
    #[error("Crypto error: {0}")]
    Crypto(#[from] CryptoError),

    /// Protocol errors
    #[error("Protocol error: {0}")]
    Protocol(#[from] ProtocolError),

    /// Network errors
    #[error("Network error: {0}")]
    Network(#[from] NetworkError),

    /// Tunnel errors
    #[error("Tunnel error: {0}")]
    Tunnel(#[from] TunnelError),

    /// System I/O errors
    #[error("System error: {0}")]
    System(#[from] std::io::Error),
}

/// Configuration parsing errors
#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("File not found: {path}")]
    FileNotFound { path: String },

    #[error("Invalid config format at line {line}: {message}")]
    ParseError { line: usize, message: String },

    #[error("Invalid base64 key: {field}")]
    InvalidKey { field: String },

    #[error("Invalid IP address: {value}")]
    InvalidAddress { value: String },

    #[error("Missing required field: {field}")]
    MissingField { field: String },

    #[error("Invalid CIDR notation: {value}")]
    InvalidCidr { value: String },

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Cryptographic operation errors
#[derive(Error, Debug)]
pub enum CryptoError {
    #[error("Key derivation failed")]
    KeyDerivation,

    #[error("Encryption failed")]
    Encryption,

    #[error("Decryption failed: invalid ciphertext or authentication tag")]
    Decryption,

    #[error("Invalid key length: expected {expected}, got {got}")]
    InvalidKeyLength { expected: usize, got: usize },

    #[error("Invalid nonce")]
    InvalidNonce,

    #[error("DH computation failed")]
    DiffieHellman,
}

/// Protocol-level errors
#[derive(Error, Debug)]
pub enum ProtocolError {
    #[error("Handshake timeout after {seconds}s")]
    HandshakeTimeout { seconds: u64 },

    #[error("Handshake failed: {reason}")]
    HandshakeFailed { reason: String },

    #[error("Invalid message type: {msg_type}")]
    InvalidMessageType { msg_type: u8 },

    #[error("Invalid message length: expected {expected}, got {got}")]
    InvalidMessageLength { expected: usize, got: usize },

    #[error("MAC verification failed")]
    MacVerificationFailed,

    #[error("Replay attack detected: counter {counter} already seen")]
    ReplayDetected { counter: u64 },

    #[error("Session expired")]
    SessionExpired,

    #[error("No active session")]
    NoSession,

    #[error("Invalid sender index: {index}")]
    InvalidSenderIndex { index: u32 },

    #[error("Cookie required but not available")]
    CookieRequired,
}

/// Network-level errors
#[derive(Error, Debug)]
pub enum NetworkError {
    #[error("Connection refused by {endpoint}")]
    ConnectionRefused { endpoint: String },

    #[error("Network unreachable: {endpoint}")]
    NetworkUnreachable { endpoint: String },

    #[error("DNS resolution failed for {host}")]
    DnsResolutionFailed { host: String },

    #[error("Socket bind failed on {addr}: {reason}")]
    BindFailed { addr: String, reason: String },

    #[error("Send failed: {reason}")]
    SendFailed { reason: String },

    #[error("Receive failed: {reason}")]
    ReceiveFailed { reason: String },

    #[error("Endpoint not set")]
    NoEndpoint,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Tunnel device errors
#[derive(Error, Debug)]
pub enum TunnelError {
    #[error("Failed to create TUN device: {reason}")]
    CreateFailed { reason: String },

    #[error("TUN read failed: {reason}")]
    ReadFailed { reason: String },

    #[error("TUN write failed: {reason}")]
    WriteFailed { reason: String },

    #[error("Route setup failed for {network}: {reason}")]
    RouteSetupFailed { network: String, reason: String },

    #[error("Route cleanup failed for {network}: {reason}")]
    RouteCleanupFailed { network: String, reason: String },

    #[error("Insufficient privileges: {message}")]
    InsufficientPrivileges { message: String },

    #[error("Platform not supported: {platform}")]
    UnsupportedPlatform { platform: String },

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[cfg(target_os = "windows")]
    #[error("Wintun DLL load failed: {reason}")]
    WintunLoadFailed { reason: String },
}

impl MinnowVpnError {
    /// Get a user-friendly error message with suggested action
    pub fn user_message(&self) -> String {
        match self {
            Self::Tunnel(TunnelError::InsufficientPrivileges { .. }) => {
                #[cfg(target_os = "linux")]
                return "Insufficient privileges. Run with sudo or grant CAP_NET_ADMIN:\n  \
                        sudo setcap cap_net_admin=eip ./minnowvpn"
                    .to_string();
                #[cfg(target_os = "macos")]
                return "Insufficient privileges. Run with sudo:\n  \
                        sudo ./minnowvpn -c config.conf"
                    .to_string();
                #[cfg(target_os = "windows")]
                return "Insufficient privileges. Run as Administrator.".to_string();
                #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
                return format!("{}", self);
            }

            Self::Config(ConfigError::FileNotFound { path }) => {
                format!(
                    "Config file not found: {}\n  Check the path and try again.",
                    path
                )
            }

            Self::Config(ConfigError::InvalidKey { field }) => {
                format!(
                    "Invalid {} in config. Expected 32-byte base64-encoded key.",
                    field
                )
            }

            Self::Network(NetworkError::ConnectionRefused { endpoint }) => {
                format!(
                    "Connection refused by {}.\n  \
                    Check that the WireGuard server is running and accessible.",
                    endpoint
                )
            }

            Self::Protocol(ProtocolError::HandshakeTimeout { seconds }) => {
                format!(
                    "Handshake timed out after {}s.\n  \
                    Check network connectivity and firewall rules for UDP port 51820.",
                    seconds
                )
            }

            Self::Protocol(ProtocolError::MacVerificationFailed) => {
                "MAC verification failed. The peer's public key may be incorrect.".to_string()
            }

            _ => format!("{}", self),
        }
    }

    /// Check if this error is recoverable
    pub fn is_recoverable(&self) -> bool {
        match self {
            // Fatal errors
            Self::Config(_) => false,
            Self::Tunnel(TunnelError::InsufficientPrivileges { .. }) => false,
            Self::Tunnel(TunnelError::CreateFailed { .. }) => false,
            Self::Tunnel(TunnelError::UnsupportedPlatform { .. }) => false,

            // Recoverable errors
            Self::Protocol(ProtocolError::HandshakeTimeout { .. }) => true,
            Self::Protocol(ProtocolError::SessionExpired) => true,
            Self::Protocol(ProtocolError::NoSession) => true,
            Self::Network(_) => true,
            Self::Crypto(CryptoError::Decryption) => true,
            Self::Protocol(ProtocolError::MacVerificationFailed) => true,
            Self::Protocol(ProtocolError::ReplayDetected { .. }) => true,

            // Default to non-recoverable for safety
            _ => false,
        }
    }

    /// Get the exit code for this error
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Config(_) => 1,
            Self::Tunnel(TunnelError::InsufficientPrivileges { .. }) => 2,
            Self::Network(_) => 3,
            Self::Protocol(_) => 4,
            Self::Crypto(_) => 5,
            Self::Tunnel(_) => 6,
            Self::System(_) => 7,
        }
    }
}

/// Result type alias for MinnowVPN operations
pub type Result<T> = std::result::Result<T, MinnowVpnError>;
