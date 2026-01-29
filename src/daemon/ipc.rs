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

// Application-specific error codes
pub const NOT_CONNECTED: i32 = -1;
pub const ALREADY_CONNECTED: i32 = -2;
pub const CONNECTION_FAILED: i32 = -3;
pub const INVALID_CONFIG: i32 = -4;

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
