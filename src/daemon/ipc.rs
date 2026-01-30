//! IPC message types for JSON-RPC 2.0 protocol
//!
//! Defines the request/response types for communication between
//! the Flutter UI client and the Rust VPN daemon.

use serde::{Deserialize, Serialize};

/// JSON-RPC 2.0 request
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
    pub id: Option<serde_json::Value>,
}

/// JSON-RPC 2.0 response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
    pub id: Option<serde_json::Value>,
}

/// JSON-RPC 2.0 error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

/// JSON-RPC 2.0 notification (no id, no response expected)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcNotification {
    pub jsonrpc: String,
    pub method: String,
    pub params: serde_json::Value,
}

// Standard JSON-RPC error codes
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

// Application-specific error codes (client mode)
pub const NOT_CONNECTED: i32 = -1;
pub const ALREADY_CONNECTED: i32 = -2;
pub const CONNECTION_FAILED: i32 = -3;
pub const INVALID_CONFIG: i32 = -4;
pub const CONFIG_VALIDATION_FAILED: i32 = -5;
pub const UPDATE_FAILED: i32 = -6;

// Application-specific error codes (server mode)
pub const SERVER_NOT_RUNNING: i32 = -10;
pub const ALREADY_RUNNING: i32 = -11;
pub const PEER_NOT_FOUND: i32 = -12;
pub const PEER_ALREADY_EXISTS: i32 = -13;
pub const INVALID_PUBLIC_KEY: i32 = -14;
pub const INVALID_ALLOWED_IPS: i32 = -15;

/// Connect request parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectParams {
    /// WireGuard configuration content (not a file path)
    pub config: String,
}

/// VPN connection state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
    Error,
}

/// Status response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusResponse {
    pub state: ConnectionState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vpn_ip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_endpoint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected_at: Option<String>,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_handshake: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

/// Status changed notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusChangedParams {
    pub state: ConnectionState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vpn_ip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_endpoint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connected_at: Option<String>,
    pub bytes_sent: u64,
    pub bytes_received: u64,
}

/// Error notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorParams {
    pub code: String,
    pub message: String,
}

// ============================================================================
// Client Mode Config Update Types
// ============================================================================

/// Update config request parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateConfigParams {
    /// New WireGuard configuration content
    pub config: String,
}

/// Update config response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateConfigResponse {
    pub updated: bool,
    /// New VPN IP if config changed Address
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vpn_ip: Option<String>,
    /// New server endpoint if changed
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_endpoint: Option<String>,
}

/// Config update notification params (for Flutter client)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigUpdatedParams {
    pub vpn_ip: String,
    pub server_endpoint: String,
    /// True if reconnection was required
    pub reconnected: bool,
}

/// Config update failed notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigUpdateFailedParams {
    pub error: String,
    /// True if rolled back to previous config
    pub rolled_back: bool,
}

// ============================================================================
// Server Mode IPC Types
// ============================================================================

/// Start server request parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartServerParams {
    /// WireGuard configuration content (bootstrap config, peers optional)
    pub config: String,
}

/// Add peer request parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddPeerParams {
    /// Base64-encoded 32-byte public key
    pub public_key: String,
    /// Allowed IPs in CIDR notation (e.g., ["10.0.0.2/32", "192.168.1.0/24"])
    pub allowed_ips: Vec<String>,
    /// Optional base64-encoded 32-byte preshared key
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preshared_key: Option<String>,
}

/// Remove peer request parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemovePeerParams {
    /// Base64-encoded 32-byte public key
    pub public_key: String,
}

/// Peer status request parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerStatusParams {
    /// Base64-encoded 32-byte public key
    pub public_key: String,
}

/// Server status response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerStatusResponse {
    pub state: ConnectionState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub listen_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interface_address: Option<String>,
    pub peer_count: usize,
    pub connected_peer_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

/// Information about a single peer
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerInfo {
    /// Base64-encoded public key
    pub public_key: String,
    /// Allowed IPs in CIDR notation
    pub allowed_ips: Vec<String>,
    /// Last known endpoint address (IP:port)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    /// Whether the peer has an active session
    pub has_session: bool,
    /// ISO 8601 timestamp of last successful handshake
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_handshake: Option<String>,
    /// Bytes sent to this peer
    pub bytes_sent: u64,
    /// Bytes received from this peer
    pub bytes_received: u64,
}

/// List peers response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListPeersResponse {
    pub peers: Vec<PeerInfo>,
}

/// Add peer response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddPeerResponse {
    pub added: bool,
    pub public_key: String,
}

/// Remove peer response
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemovePeerResponse {
    pub removed: bool,
    pub public_key: String,
    /// True if the peer had an active session that was terminated
    pub was_connected: bool,
}

// ============================================================================
// Server Mode Notification Types
// ============================================================================

/// Peer connected notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerConnectedParams {
    /// Base64-encoded public key
    pub public_key: String,
    /// Peer's endpoint address (IP:port)
    pub endpoint: String,
    /// Peer's allowed IPs
    pub allowed_ips: Vec<String>,
}

/// Peer disconnected notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerDisconnectedParams {
    /// Base64-encoded public key
    pub public_key: String,
    /// Reason for disconnection: "removed", "expired", "error"
    pub reason: String,
}

/// Peer added notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerAddedParams {
    /// Base64-encoded public key
    pub public_key: String,
    /// Allowed IPs in CIDR notation
    pub allowed_ips: Vec<String>,
}

/// Peer removed notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerRemovedParams {
    /// Base64-encoded public key
    pub public_key: String,
    /// True if the peer had an active session
    pub was_connected: bool,
}

/// Server status changed notification params
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerStatusChangedParams {
    pub state: ConnectionState,
    pub peer_count: usize,
    pub connected_peer_count: usize,
    pub bytes_sent: u64,
    pub bytes_received: u64,
}

impl JsonRpcResponse {
    pub fn success(id: Option<serde_json::Value>, result: serde_json::Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            result: Some(result),
            error: None,
            id,
        }
    }

    pub fn error(id: Option<serde_json::Value>, code: i32, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
                data: None,
            }),
            id,
        }
    }
}

impl JsonRpcNotification {
    pub fn new(method: impl Into<String>, params: serde_json::Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            method: method.into(),
            params,
        }
    }
}

impl Default for StatusResponse {
    fn default() -> Self {
        Self {
            state: ConnectionState::Disconnected,
            vpn_ip: None,
            server_endpoint: None,
            connected_at: None,
            bytes_sent: 0,
            bytes_received: 0,
            last_handshake: None,
            error_message: None,
        }
    }
}

impl Default for ServerStatusResponse {
    fn default() -> Self {
        Self {
            state: ConnectionState::Disconnected,
            listen_port: None,
            interface_address: None,
            peer_count: 0,
            connected_peer_count: 0,
            started_at: None,
            bytes_sent: 0,
            bytes_received: 0,
            error_message: None,
        }
    }
}
