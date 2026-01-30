//! Daemon mode for SecureGuard VPN service
//!
//! Runs as a background service, accepting commands via Unix socket (macOS/Linux)
//! or named pipe (Windows). The Flutter UI client communicates with this daemon
//! to control the VPN connection.

pub mod ipc;

use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{broadcast, mpsc, watch, Mutex};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use ipnet::IpNet;

use crate::error::ConfigError;
use crate::protocol::session::PeerManager;
use crate::server::{PeerEvent, PeerUpdate};
use crate::{SecureGuardError, WireGuardClient, WireGuardConfig, WireGuardServer};

use ipc::*;

// Re-export TrafficStats from protocol layer for backwards compatibility
pub use crate::protocol::session::TrafficStats;

/// Default socket path for Unix systems (client mode daemon)
#[cfg(unix)]
pub const DEFAULT_SOCKET_PATH: &str = "/var/run/secureguard.sock";

/// Default socket path for server mode daemon (allows running both modes simultaneously)
#[cfg(unix)]
pub const DEFAULT_SERVER_SOCKET_PATH: &str = "/var/run/secureguard-server.sock";

/// Default pipe name for Windows (client mode daemon)
#[cfg(windows)]
pub const DEFAULT_PIPE_NAME: &str = r"\\.\pipe\secureguard";

/// Default pipe name for server mode daemon on Windows
#[cfg(windows)]
pub const DEFAULT_SERVER_PIPE_NAME: &str = r"\\.\pipe\secureguard-server";

// ============================================================================
// VPN Mode and State Types
// ============================================================================

/// The active VPN mode with mode-specific state
enum VpnMode {
    /// Client mode - connects to a VPN server
    Client {
        vpn_ip: String,
        server_endpoint: String,
        /// Current config (for rollback on update failure)
        current_config: WireGuardConfig,
        /// Previous working config (set after successful handshake)
        previous_config: Option<WireGuardConfig>,
    },
    /// Server mode - accepts connections from VPN clients
    Server {
        listen_port: u16,
        interface_address: String,
        /// Channel to send peer updates to the server event loop
        peer_update_tx: mpsc::Sender<PeerUpdate>,
        /// Shared peer manager for IPC queries
        peers: Arc<Mutex<PeerManager>>,
    },
}

/// Daemon service that manages VPN connections via IPC
pub struct DaemonService {
    socket_path: PathBuf,
    state: Arc<Mutex<DaemonState>>,
    status_tx: broadcast::Sender<String>,
}

struct DaemonState {
    /// Current connection state
    connection_state: ConnectionState,
    /// Active VPN mode (None when disconnected)
    mode: Option<VpnMode>,
    /// When the connection/server started
    started_at: Option<String>,
    /// Shared traffic statistics (updated by VPN client/server)
    traffic_stats: Arc<TrafficStats>,
    /// Error message (if in error state)
    error_message: Option<String>,
    /// Shutdown signal sender - send true to stop the VPN
    shutdown_tx: Option<watch::Sender<bool>>,
}

impl Default for DaemonState {
    fn default() -> Self {
        Self {
            connection_state: ConnectionState::Disconnected,
            mode: None,
            started_at: None,
            traffic_stats: Arc::new(TrafficStats::new()),
            error_message: None,
            shutdown_tx: None,
        }
    }
}

impl DaemonService {
    /// Create a new daemon service
    pub fn new(socket_path: Option<PathBuf>) -> Self {
        let path = socket_path.unwrap_or_else(|| {
            #[cfg(unix)]
            {
                PathBuf::from(DEFAULT_SOCKET_PATH)
            }
            #[cfg(windows)]
            {
                PathBuf::from(DEFAULT_PIPE_NAME)
            }
        });

        let (status_tx, _) = broadcast::channel(16);

        Self {
            socket_path: path,
            state: Arc::new(Mutex::new(DaemonState::default())),
            status_tx,
        }
    }

    /// Run the daemon service
    #[cfg(unix)]
    pub async fn run(&self) -> Result<(), SecureGuardError> {
        use tokio::net::UnixListener;

        // Remove existing socket file if present
        if self.socket_path.exists() {
            std::fs::remove_file(&self.socket_path).map_err(|e| {
                SecureGuardError::Config(ConfigError::ParseError {
                    line: 0,
                    message: format!("Failed to remove existing socket: {}", e),
                })
            })?;
        }

        // Create parent directory if needed
        if let Some(parent) = self.socket_path.parent() {
            if !parent.exists() {
                std::fs::create_dir_all(parent).map_err(|e| {
                    SecureGuardError::Config(ConfigError::ParseError {
                        line: 0,
                        message: format!("Failed to create socket directory: {}", e),
                    })
                })?;
            }
        }

        let listener = UnixListener::bind(&self.socket_path).map_err(|e| {
            SecureGuardError::Config(ConfigError::ParseError {
                line: 0,
                message: format!("Failed to bind socket at {:?}: {}", self.socket_path, e),
            })
        })?;

        // Set socket permissions (allow all users to connect)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&self.socket_path, std::fs::Permissions::from_mode(0o666))
                .ok();
        }

        tracing::info!("Daemon listening on {:?}", self.socket_path);

        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let state = Arc::clone(&self.state);
                    let status_rx = self.status_tx.subscribe();
                    let status_tx = self.status_tx.clone();

                    tokio::spawn(async move {
                        if let Err(e) =
                            Self::handle_client(stream, state, status_tx, status_rx).await
                        {
                            tracing::error!("Client handler error: {}", e);
                        }
                    });
                }
                Err(e) => {
                    tracing::error!("Failed to accept connection: {}", e);
                }
            }
        }
    }

    /// Handle a single client connection
    #[cfg(unix)]
    async fn handle_client(
        stream: tokio::net::UnixStream,
        state: Arc<Mutex<DaemonState>>,
        status_tx: broadcast::Sender<String>,
        mut status_rx: broadcast::Receiver<String>,
    ) -> Result<(), SecureGuardError> {
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);
        let mut line = String::new();

        loop {
            tokio::select! {
                // Handle incoming requests
                result = reader.read_line(&mut line) => {
                    match result {
                        Ok(0) => {
                            // Client disconnected
                            tracing::debug!("Client disconnected");
                            break;
                        }
                        Ok(_) => {
                            let response = Self::process_request(&line, &state, &status_tx).await;
                            let response_json = serde_json::to_string(&response)
                                .unwrap_or_else(|_| r#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Serialization error"},"id":null}"#.to_string());

                            if let Err(e) = writer.write_all(response_json.as_bytes()).await {
                                tracing::error!("Failed to write response: {}", e);
                                break;
                            }
                            if let Err(e) = writer.write_all(b"\n").await {
                                tracing::error!("Failed to write newline: {}", e);
                                break;
                            }
                            line.clear();
                        }
                        Err(e) => {
                            tracing::error!("Read error: {}", e);
                            break;
                        }
                    }
                }

                // Forward status notifications to client
                notification = status_rx.recv() => {
                    if let Ok(notification) = notification {
                        if let Err(e) = writer.write_all(notification.as_bytes()).await {
                            tracing::error!("Failed to write notification: {}", e);
                            break;
                        }
                        if let Err(e) = writer.write_all(b"\n").await {
                            tracing::error!("Failed to write newline: {}", e);
                            break;
                        }
                    }
                }
            }
        }

        Ok(())
    }

    /// Process a JSON-RPC request
    async fn process_request(
        request_str: &str,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        // Parse request
        let request: JsonRpcRequest = match serde_json::from_str(request_str.trim()) {
            Ok(r) => r,
            Err(e) => {
                return JsonRpcResponse::error(None, PARSE_ERROR, format!("Parse error: {}", e));
            }
        };

        tracing::debug!("Received request: {:?}", request.method);

        // Dispatch to handler
        match request.method.as_str() {
            // Client mode methods
            "connect" => Self::handle_connect(request, state, status_tx).await,
            "disconnect" => Self::handle_disconnect(request, state, status_tx).await,
            "status" => Self::handle_status(request, state).await,
            "update_config" => Self::handle_update_config(request, state, status_tx).await,
            // Server mode lifecycle
            "start" => Self::handle_start_server(request, state, status_tx).await,
            "stop" => Self::handle_stop_server(request, state, status_tx).await,
            // Server mode peer queries
            "list_peers" => Self::handle_list_peers(request, state).await,
            "peer_status" => Self::handle_peer_status(request, state).await,
            // Server mode dynamic peer management
            "add_peer" => Self::handle_add_peer(request, state, status_tx).await,
            "remove_peer" => Self::handle_remove_peer(request, state, status_tx).await,
            _ => JsonRpcResponse::error(
                request.id,
                METHOD_NOT_FOUND,
                format!("Method not found: {}", request.method),
            ),
        }
    }

    /// Handle connect request (client mode)
    async fn handle_connect(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        // Parse params
        let params: ConnectParams = match serde_json::from_value(request.params.clone()) {
            Ok(p) => p,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PARAMS,
                    format!("Invalid params: {}", e),
                );
            }
        };

        // Check if already running (client or server)
        {
            let s = state.lock().await;
            if s.connection_state == ConnectionState::Connected
                || s.connection_state == ConnectionState::Connecting
            {
                return JsonRpcResponse::error(
                    request.id,
                    ALREADY_CONNECTED,
                    "Already connected or running",
                );
            }
        }

        // Update state to connecting
        {
            let mut s = state.lock().await;
            s.connection_state = ConnectionState::Connecting;
            s.error_message = None;
        }

        // Send status notification
        let _ = Self::send_status_notification(state, status_tx).await;

        // Parse config
        let config = match WireGuardConfig::from_string(&params.config) {
            Ok(c) => c,
            Err(e) => {
                let mut s = state.lock().await;
                s.connection_state = ConnectionState::Error;
                s.error_message = Some(format!("Invalid config: {}", e));
                let _ = Self::send_status_notification(state, status_tx).await;
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_CONFIG,
                    format!("Invalid config: {}", e),
                );
            }
        };

        // Extract endpoint for status
        let server_endpoint = config
            .peers
            .first()
            .and_then(|p| p.endpoint.as_ref())
            .map(|e| e.to_string())
            .unwrap_or_default();

        // Extract VPN IP for status
        let vpn_ip = config.interface.address.first()
            .map(|a| a.to_string())
            .unwrap_or_default();

        // Get traffic stats to pass to client
        let traffic_stats = {
            let s = state.lock().await;
            Arc::clone(&s.traffic_stats)
        };

        // Clone config for storage before moving to client
        let config_for_storage = config.clone();

        // Create and start client with traffic stats
        match WireGuardClient::new(config, Some(traffic_stats)).await {
            Ok(client) => {
                // Create shutdown channel
                let (shutdown_tx, shutdown_rx) = watch::channel(false);

                {
                    let mut s = state.lock().await;
                    s.connection_state = ConnectionState::Connected;
                    s.mode = Some(VpnMode::Client {
                        vpn_ip: vpn_ip.clone(),
                        server_endpoint: server_endpoint.clone(),
                        current_config: config_for_storage,
                        previous_config: None,
                    });
                    s.started_at = Some(chrono_now());
                    s.traffic_stats.reset(); // Reset counters for new connection
                    s.shutdown_tx = Some(shutdown_tx);
                }

                let _ = Self::send_status_notification(state, status_tx).await;

                // Start the client run loop in background
                let state_clone = Arc::clone(state);
                let status_tx_clone = status_tx.clone();
                tokio::spawn(async move {
                    let mut client = client;

                    // Run client with shutdown monitoring
                    let mut shutdown_rx = shutdown_rx;
                    let result = tokio::select! {
                        result = client.run() => result,
                        _ = async {
                            loop {
                                shutdown_rx.changed().await.ok();
                                if *shutdown_rx.borrow() {
                                    break;
                                }
                            }
                        } => {
                            tracing::info!("Shutdown signal received");
                            Ok(())
                        }
                    };

                    // Update state based on result
                    {
                        let mut s = state_clone.lock().await;
                        match result {
                            Ok(_) => {
                                tracing::info!("VPN client disconnected");
                                s.connection_state = ConnectionState::Disconnected;
                            }
                            Err(e) => {
                                tracing::error!("VPN client error: {}", e);
                                s.connection_state = ConnectionState::Error;
                                s.error_message = Some(format!("{}", e));
                            }
                        }
                        s.mode = None;
                        s.started_at = None;
                        s.shutdown_tx = None;
                    }

                    // Send status notification
                    let _ = Self::send_status_notification(&state_clone, &status_tx_clone).await;

                    // Cleanup
                    if let Err(e) = client.cleanup().await {
                        tracing::error!("Cleanup error: {}", e);
                    }
                });

                JsonRpcResponse::success(request.id, serde_json::json!({"connected": true}))
            }
            Err(e) => {
                let mut s = state.lock().await;
                s.connection_state = ConnectionState::Error;
                s.error_message = Some(format!("{}", e));
                drop(s);

                let _ = Self::send_status_notification(state, status_tx).await;

                JsonRpcResponse::error(
                    request.id,
                    CONNECTION_FAILED,
                    format!("Connection failed: {}", e),
                )
            }
        }
    }

    /// Handle disconnect request (client mode)
    async fn handle_disconnect(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        let mut s = state.lock().await;

        // Check if in client mode (ignore config fields with ..)
        match &s.mode {
            Some(VpnMode::Client { .. }) => {}
            Some(VpnMode::Server { .. }) => {
                return JsonRpcResponse::error(
                    request.id,
                    NOT_CONNECTED,
                    "Use 'stop' to stop server mode",
                );
            }
            None => {
                return JsonRpcResponse::error(request.id, NOT_CONNECTED, "Not connected");
            }
        }

        s.connection_state = ConnectionState::Disconnecting;

        // Send shutdown signal to the background task
        if let Some(ref shutdown_tx) = s.shutdown_tx {
            let _ = shutdown_tx.send(true);
        }
        drop(s);

        let _ = Self::send_status_notification(state, status_tx).await;

        // Give the background task a moment to clean up
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        JsonRpcResponse::success(request.id, serde_json::json!({"disconnected": true}))
    }

    /// Handle status request - returns mode-specific response
    async fn handle_status(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
    ) -> JsonRpcResponse {
        let s = state.lock().await;

        match &s.mode {
            Some(VpnMode::Client { vpn_ip, server_endpoint, .. }) => {
                let status = StatusResponse {
                    state: s.connection_state,
                    vpn_ip: Some(vpn_ip.clone()),
                    server_endpoint: Some(server_endpoint.clone()),
                    connected_at: s.started_at.clone(),
                    bytes_sent: s.traffic_stats.get_sent(),
                    bytes_received: s.traffic_stats.get_received(),
                    last_handshake: None,
                    error_message: s.error_message.clone(),
                };
                JsonRpcResponse::success(request.id, serde_json::to_value(status).unwrap())
            }
            Some(VpnMode::Server { listen_port, interface_address, peers, .. }) => {
                // Get peer counts
                let peers_guard = peers.blocking_lock();
                let peer_count = peers_guard.len();
                let connected_peer_count = peers_guard.connected_count();
                drop(peers_guard);

                let status = ServerStatusResponse {
                    state: s.connection_state,
                    listen_port: Some(*listen_port),
                    interface_address: Some(interface_address.clone()),
                    peer_count,
                    connected_peer_count,
                    started_at: s.started_at.clone(),
                    bytes_sent: s.traffic_stats.get_sent(),
                    bytes_received: s.traffic_stats.get_received(),
                    error_message: s.error_message.clone(),
                };
                JsonRpcResponse::success(request.id, serde_json::to_value(status).unwrap())
            }
            None => {
                let status = StatusResponse {
                    state: s.connection_state,
                    vpn_ip: None,
                    server_endpoint: None,
                    connected_at: None,
                    bytes_sent: 0,
                    bytes_received: 0,
                    last_handshake: None,
                    error_message: s.error_message.clone(),
                };
                JsonRpcResponse::success(request.id, serde_json::to_value(status).unwrap())
            }
        }
    }

    /// Send status notification to all connected clients
    async fn send_status_notification(
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> Result<(), ()> {
        let s = state.lock().await;

        // Build notification based on mode
        let notification = match &s.mode {
            Some(VpnMode::Client { vpn_ip, server_endpoint, .. }) => {
                let params = StatusChangedParams {
                    state: s.connection_state,
                    vpn_ip: Some(vpn_ip.clone()),
                    server_endpoint: Some(server_endpoint.clone()),
                    connected_at: s.started_at.clone(),
                    bytes_sent: s.traffic_stats.get_sent(),
                    bytes_received: s.traffic_stats.get_received(),
                };
                JsonRpcNotification::new(
                    "status_changed",
                    serde_json::to_value(params).unwrap_or_default(),
                )
            }
            Some(VpnMode::Server { peers, .. }) => {
                // For server mode, we send a different notification
                let peers_guard = peers.blocking_lock();
                let peer_count = peers_guard.len();
                let connected_peer_count = peers_guard.connected_count();
                drop(peers_guard);

                let params = ServerStatusChangedParams {
                    state: s.connection_state,
                    peer_count,
                    connected_peer_count,
                    bytes_sent: s.traffic_stats.get_sent(),
                    bytes_received: s.traffic_stats.get_received(),
                };
                JsonRpcNotification::new(
                    "server_status_changed",
                    serde_json::to_value(params).unwrap_or_default(),
                )
            }
            None => {
                let params = StatusChangedParams {
                    state: s.connection_state,
                    vpn_ip: None,
                    server_endpoint: None,
                    connected_at: None,
                    bytes_sent: 0,
                    bytes_received: 0,
                };
                JsonRpcNotification::new(
                    "status_changed",
                    serde_json::to_value(params).unwrap_or_default(),
                )
            }
        };

        let json = serde_json::to_string(&notification).map_err(|_| ())?;
        status_tx.send(json).map_err(|_| ())?;

        Ok(())
    }

    // ========================================================================
    // Client Config Update Handler
    // ========================================================================

    /// Handle update_config request (client mode - dynamic config update)
    async fn handle_update_config(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        // Parse params
        let params: UpdateConfigParams = match serde_json::from_value(request.params.clone()) {
            Ok(p) => p,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PARAMS,
                    format!("Invalid params: {}", e),
                );
            }
        };

        // Step 1: Parse and validate new config BEFORE disconnecting
        let new_config = match WireGuardConfig::from_string(&params.config) {
            Ok(c) => c,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    CONFIG_VALIDATION_FAILED,
                    format!("Invalid config: {}", e),
                );
            }
        };

        // Validate config has required fields for client mode
        if new_config.peers.is_empty() {
            return JsonRpcResponse::error(
                request.id,
                CONFIG_VALIDATION_FAILED,
                "Config must have at least one peer",
            );
        }

        let peer = &new_config.peers[0];
        if peer.endpoint.is_none() {
            return JsonRpcResponse::error(
                request.id,
                CONFIG_VALIDATION_FAILED,
                "Peer must have an endpoint for client mode",
            );
        }

        // Extract new connection info
        let new_vpn_ip = new_config
            .interface
            .address
            .first()
            .map(|a| a.addr().to_string())
            .unwrap_or_default();
        let new_server_endpoint = new_config
            .peers
            .first()
            .and_then(|p| p.endpoint.map(|e| e.to_string()))
            .unwrap_or_default();

        let mut s = state.lock().await;

        // Step 2: Check current state
        let (current_config, was_connected) = match &s.mode {
            Some(VpnMode::Client { current_config, .. }) => {
                let connected = s.connection_state == ConnectionState::Connected;
                (Some(current_config.clone()), connected)
            }
            Some(VpnMode::Server { .. }) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_REQUEST,
                    "Cannot update config in server mode",
                );
            }
            None => {
                // Not connected - we can't update config when not in client mode
                // The caller should use 'connect' with the new config instead
                return JsonRpcResponse::error(
                    request.id,
                    NOT_CONNECTED,
                    "Not in client mode. Use 'connect' to start a new connection.",
                );
            }
        };

        // Step 3: If connected, disconnect current session
        if was_connected {
            s.connection_state = ConnectionState::Disconnecting;

            // Send shutdown signal to the background task
            if let Some(ref shutdown_tx) = s.shutdown_tx {
                let _ = shutdown_tx.send(true);
            }
        }

        drop(s);

        // Give the background task time to clean up
        if was_connected {
            tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;
        }

        // Step 4: Reconnect with new config
        let traffic_stats = {
            let s = state.lock().await;
            Arc::clone(&s.traffic_stats)
        };

        // Clone new config for storage
        let config_for_storage = new_config.clone();

        // Create and start client with new config
        match WireGuardClient::new(new_config, Some(traffic_stats)).await {
            Ok(client) => {
                // Create shutdown channel
                let (shutdown_tx, shutdown_rx) = watch::channel(false);

                {
                    let mut s = state.lock().await;
                    s.connection_state = ConnectionState::Connected;
                    s.mode = Some(VpnMode::Client {
                        vpn_ip: new_vpn_ip.clone(),
                        server_endpoint: new_server_endpoint.clone(),
                        current_config: config_for_storage,
                        previous_config: current_config, // Store old config for potential future rollback
                    });
                    s.started_at = Some(chrono_now());
                    s.shutdown_tx = Some(shutdown_tx);
                }

                let _ = Self::send_status_notification(state, status_tx).await;

                // Send config_updated notification
                let notification = JsonRpcNotification::new(
                    "config_updated",
                    serde_json::json!({
                        "vpn_ip": new_vpn_ip,
                        "server_endpoint": new_server_endpoint,
                        "reconnected": was_connected
                    }),
                );
                if let Ok(json) = serde_json::to_string(&notification) {
                    let _ = status_tx.send(json);
                }

                // Start the client run loop in background
                let state_clone = Arc::clone(state);
                let status_tx_clone = status_tx.clone();
                tokio::spawn(async move {
                    let mut client = client;

                    // Run client with shutdown monitoring
                    let mut shutdown_rx = shutdown_rx;
                    let result = tokio::select! {
                        result = client.run() => result,
                        _ = async {
                            loop {
                                shutdown_rx.changed().await.ok();
                                if *shutdown_rx.borrow() {
                                    break;
                                }
                            }
                        } => {
                            tracing::info!("Shutdown signal received");
                            Ok(())
                        }
                    };

                    // Update state based on result
                    {
                        let mut s = state_clone.lock().await;
                        match result {
                            Ok(_) => {
                                tracing::info!("VPN client disconnected");
                                s.connection_state = ConnectionState::Disconnected;
                            }
                            Err(e) => {
                                tracing::error!("VPN client error: {}", e);
                                s.connection_state = ConnectionState::Error;
                                s.error_message = Some(format!("{}", e));
                            }
                        }
                        s.mode = None;
                        s.started_at = None;
                        s.shutdown_tx = None;
                    }

                    // Send status notification
                    let _ = Self::send_status_notification(&state_clone, &status_tx_clone).await;

                    // Cleanup
                    if let Err(e) = client.cleanup().await {
                        tracing::error!("Cleanup error: {}", e);
                    }
                });

                let response = UpdateConfigResponse {
                    updated: true,
                    vpn_ip: Some(new_vpn_ip),
                    server_endpoint: Some(new_server_endpoint),
                };
                JsonRpcResponse::success(request.id, serde_json::to_value(response).unwrap())
            }
            Err(e) => {
                tracing::warn!("Config update failed: {}, attempting rollback", e);

                // Attempt rollback to previous config if available
                if let Some(prev_config) = current_config {
                    let rollback_vpn_ip = prev_config
                        .interface
                        .address
                        .first()
                        .map(|a| a.addr().to_string())
                        .unwrap_or_default();
                    let rollback_endpoint = prev_config
                        .peers
                        .first()
                        .and_then(|p| p.endpoint.map(|ep| ep.to_string()))
                        .unwrap_or_default();

                    // Get fresh traffic stats for rollback attempt
                    let rollback_traffic_stats = {
                        let s = state.lock().await;
                        Arc::clone(&s.traffic_stats)
                    };

                    match WireGuardClient::new(prev_config.clone(), Some(rollback_traffic_stats))
                        .await
                    {
                        Ok(rollback_client) => {
                            tracing::info!(
                                "Rollback successful, reconnected with previous config"
                            );

                            // Create new shutdown channel for rollback session
                            let (rollback_shutdown_tx, rollback_shutdown_rx) =
                                watch::channel(false);

                            {
                                let mut s = state.lock().await;
                                s.connection_state = ConnectionState::Connected;
                                s.mode = Some(VpnMode::Client {
                                    vpn_ip: rollback_vpn_ip.clone(),
                                    server_endpoint: rollback_endpoint.clone(),
                                    current_config: prev_config,
                                    previous_config: None, // No previous after rollback
                                });
                                s.started_at = Some(chrono_now());
                                s.shutdown_tx = Some(rollback_shutdown_tx);
                            }

                            let _ = Self::send_status_notification(state, status_tx).await;

                            // Send rolled_back: true notification
                            let notification = JsonRpcNotification::new(
                                "config_update_failed",
                                serde_json::json!({
                                    "error": e.to_string(),
                                    "rolled_back": true
                                }),
                            );
                            if let Ok(json) = serde_json::to_string(&notification) {
                                let _ = status_tx.send(json);
                            }

                            // Spawn background task for rollback session
                            let state_clone = Arc::clone(state);
                            let status_tx_clone = status_tx.clone();
                            tokio::spawn(async move {
                                let mut client = rollback_client;
                                let mut shutdown_rx = rollback_shutdown_rx;

                                let result = tokio::select! {
                                    result = client.run() => result,
                                    _ = async {
                                        loop {
                                            shutdown_rx.changed().await.ok();
                                            if *shutdown_rx.borrow() {
                                                break;
                                            }
                                        }
                                    } => {
                                        tracing::info!("Shutdown signal received");
                                        Ok(())
                                    }
                                };

                                // Update state based on result
                                {
                                    let mut s = state_clone.lock().await;
                                    match result {
                                        Ok(_) => {
                                            tracing::info!("VPN client disconnected");
                                            s.connection_state = ConnectionState::Disconnected;
                                        }
                                        Err(err) => {
                                            tracing::error!("VPN client error: {}", err);
                                            s.connection_state = ConnectionState::Error;
                                            s.error_message = Some(format!("{}", err));
                                        }
                                    }
                                    s.mode = None;
                                    s.started_at = None;
                                    s.shutdown_tx = None;
                                }

                                let _ = Self::send_status_notification(
                                    &state_clone,
                                    &status_tx_clone,
                                )
                                .await;

                                if let Err(err) = client.cleanup().await {
                                    tracing::error!("Cleanup error: {}", err);
                                }
                            });

                            return JsonRpcResponse::error(
                                request.id,
                                UPDATE_FAILED,
                                format!("Config update failed but rolled back: {}", e),
                            );
                        }
                        Err(rollback_err) => {
                            tracing::error!("Rollback also failed: {}", rollback_err);

                            // Both failed - enter error state
                            let notification = JsonRpcNotification::new(
                                "config_update_failed",
                                serde_json::json!({
                                    "error": format!("Update failed: {}. Rollback also failed: {}", e, rollback_err),
                                    "rolled_back": false
                                }),
                            );
                            if let Ok(json) = serde_json::to_string(&notification) {
                                let _ = status_tx.send(json);
                            }

                            let mut s = state.lock().await;
                            s.connection_state = ConnectionState::Error;
                            s.error_message = Some(format!(
                                "Update failed: {}. Rollback failed: {}",
                                e, rollback_err
                            ));
                            s.mode = None;
                            drop(s);

                            let _ = Self::send_status_notification(state, status_tx).await;

                            return JsonRpcResponse::error(
                                request.id,
                                UPDATE_FAILED,
                                format!(
                                    "Config update failed and rollback failed: {} / {}",
                                    e, rollback_err
                                ),
                            );
                        }
                    }
                } else {
                    // No previous config to roll back to
                    let notification = JsonRpcNotification::new(
                        "config_update_failed",
                        serde_json::json!({
                            "error": e.to_string(),
                            "rolled_back": false
                        }),
                    );
                    if let Ok(json) = serde_json::to_string(&notification) {
                        let _ = status_tx.send(json);
                    }

                    let mut s = state.lock().await;
                    s.connection_state = ConnectionState::Error;
                    s.error_message = Some(format!("Config update failed: {}", e));
                    s.mode = None;
                    drop(s);

                    let _ = Self::send_status_notification(state, status_tx).await;

                    JsonRpcResponse::error(
                        request.id,
                        UPDATE_FAILED,
                        format!("Config update failed (no rollback available): {}", e),
                    )
                }
            }
        }
    }

    // ========================================================================
    // Server Mode Handlers
    // ========================================================================

    /// Handle start server request (server mode)
    async fn handle_start_server(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        // Parse params
        let params: StartServerParams = match serde_json::from_value(request.params.clone()) {
            Ok(p) => p,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PARAMS,
                    format!("Invalid params: {}", e),
                );
            }
        };

        // Check if already running (client or server)
        {
            let s = state.lock().await;
            if s.connection_state == ConnectionState::Connected
                || s.connection_state == ConnectionState::Connecting
            {
                return JsonRpcResponse::error(
                    request.id,
                    ALREADY_RUNNING,
                    "Already running (client or server mode)",
                );
            }
        }

        // Update state to connecting
        {
            let mut s = state.lock().await;
            s.connection_state = ConnectionState::Connecting;
            s.error_message = None;
        }

        let _ = Self::send_status_notification(state, status_tx).await;

        // Parse config
        let config = match WireGuardConfig::from_string(&params.config) {
            Ok(c) => c,
            Err(e) => {
                let mut s = state.lock().await;
                s.connection_state = ConnectionState::Error;
                s.error_message = Some(format!("Invalid config: {}", e));
                let _ = Self::send_status_notification(state, status_tx).await;
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_CONFIG,
                    format!("Invalid config: {}", e),
                );
            }
        };

        // Extract server settings for status
        let listen_port = config.interface.listen_port.unwrap_or(51820);
        let interface_address = config
            .interface
            .address
            .first()
            .map(|a| a.to_string())
            .unwrap_or_default();

        // Get traffic stats to pass to server
        let traffic_stats = {
            let s = state.lock().await;
            Arc::clone(&s.traffic_stats)
        };

        // Create channels for peer management
        let (peer_update_tx, peer_update_rx) = mpsc::channel(32);
        let (peer_event_tx, mut peer_event_rx) = mpsc::channel(32);

        // Create shared peer manager
        let peers = Arc::new(Mutex::new(PeerManager::new()));

        // Initialize peers from bootstrap config (if any)
        {
            let mut peers_guard = peers.lock().await;
            for peer_config in &config.peers {
                let allowed_ips: Vec<IpNet> = peer_config
                    .allowed_ips
                    .iter()
                    .filter_map(|net| {
                        // Convert Ipv4Net to IpNet
                        let ip_net: IpNet = (*net).into();
                        Some(ip_net)
                    })
                    .collect();
                peers_guard.add_peer(
                    peer_config.public_key,
                    peer_config.preshared_key,
                    allowed_ips,
                );
            }
        }

        // Create server with channels
        match WireGuardServer::new_with_channels(
            config,
            Arc::clone(&peers),
            peer_update_rx,
            peer_event_tx,
            traffic_stats,
        )
        .await
        {
            Ok(server) => {
                // Create shutdown channel
                let (shutdown_tx, shutdown_rx) = watch::channel(false);

                {
                    let mut s = state.lock().await;
                    s.connection_state = ConnectionState::Connected;
                    s.mode = Some(VpnMode::Server {
                        listen_port,
                        interface_address: interface_address.clone(),
                        peer_update_tx: peer_update_tx.clone(),
                        peers: Arc::clone(&peers),
                    });
                    s.started_at = Some(chrono_now());
                    s.traffic_stats.reset();
                    s.shutdown_tx = Some(shutdown_tx);
                }

                let _ = Self::send_status_notification(state, status_tx).await;

                // Start the server run loop in background
                let state_clone = Arc::clone(state);
                let status_tx_clone = status_tx.clone();
                tokio::spawn(async move {
                    let mut server = server;
                    let mut shutdown_rx = shutdown_rx;

                    // Spawn peer event forwarder
                    let status_tx_events = status_tx_clone.clone();
                    let event_forwarder = tokio::spawn(async move {
                        while let Some(event) = peer_event_rx.recv().await {
                            Self::send_peer_event_notification(&event, &status_tx_events);
                        }
                    });

                    // Run server with shutdown monitoring
                    let result = tokio::select! {
                        result = server.run() => result,
                        _ = async {
                            loop {
                                shutdown_rx.changed().await.ok();
                                if *shutdown_rx.borrow() {
                                    break;
                                }
                            }
                        } => {
                            tracing::info!("Server shutdown signal received");
                            Ok(())
                        }
                    };

                    // Stop event forwarder
                    event_forwarder.abort();

                    // Update state based on result
                    {
                        let mut s = state_clone.lock().await;
                        match result {
                            Ok(_) => {
                                tracing::info!("VPN server stopped");
                                s.connection_state = ConnectionState::Disconnected;
                            }
                            Err(e) => {
                                tracing::error!("VPN server error: {}", e);
                                s.connection_state = ConnectionState::Error;
                                s.error_message = Some(format!("{}", e));
                            }
                        }
                        s.mode = None;
                        s.started_at = None;
                        s.shutdown_tx = None;
                    }

                    let _ = Self::send_status_notification(&state_clone, &status_tx_clone).await;

                    // Cleanup
                    if let Err(e) = server.cleanup().await {
                        tracing::error!("Server cleanup error: {}", e);
                    }
                });

                JsonRpcResponse::success(request.id, serde_json::json!({"started": true}))
            }
            Err(e) => {
                let mut s = state.lock().await;
                s.connection_state = ConnectionState::Error;
                s.error_message = Some(format!("{}", e));
                drop(s);

                let _ = Self::send_status_notification(state, status_tx).await;

                JsonRpcResponse::error(
                    request.id,
                    CONNECTION_FAILED,
                    format!("Failed to start server: {}", e),
                )
            }
        }
    }

    /// Handle stop server request (server mode)
    async fn handle_stop_server(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        let mut s = state.lock().await;

        // Check if in server mode
        match &s.mode {
            Some(VpnMode::Server { .. }) => {}
            Some(VpnMode::Client { .. }) => {
                return JsonRpcResponse::error(
                    request.id,
                    SERVER_NOT_RUNNING,
                    "Use 'disconnect' to stop client mode",
                );
            }
            None => {
                return JsonRpcResponse::error(
                    request.id,
                    SERVER_NOT_RUNNING,
                    "Server not running",
                );
            }
        }

        s.connection_state = ConnectionState::Disconnecting;

        // Send shutdown signal to the background task
        if let Some(ref shutdown_tx) = s.shutdown_tx {
            let _ = shutdown_tx.send(true);
        }
        drop(s);

        let _ = Self::send_status_notification(state, status_tx).await;

        // Give the background task a moment to clean up
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        JsonRpcResponse::success(request.id, serde_json::json!({"stopped": true}))
    }

    /// Handle list peers request (server mode)
    async fn handle_list_peers(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
    ) -> JsonRpcResponse {
        let s = state.lock().await;

        let peers = match &s.mode {
            Some(VpnMode::Server { peers, .. }) => Arc::clone(peers),
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    SERVER_NOT_RUNNING,
                    "Server not running",
                );
            }
        };
        drop(s);

        let peers_guard = peers.lock().await;
        let peer_list: Vec<PeerInfo> = peers_guard
            .iter()
            .map(|peer_state| {
                PeerInfo {
                    public_key: BASE64.encode(&peer_state.public_key),
                    allowed_ips: peer_state
                        .allowed_ips
                        .iter()
                        .map(|ip| ip.to_string())
                        .collect(),
                    endpoint: peer_state.endpoint.map(|e| e.to_string()),
                    has_session: peer_state.session.is_some(),
                    last_handshake: peer_state.last_handshake.map(|_| chrono_now()),
                    bytes_sent: peer_state.traffic_stats.get_sent(),
                    bytes_received: peer_state.traffic_stats.get_received(),
                }
            })
            .collect();

        let response = ListPeersResponse { peers: peer_list };
        JsonRpcResponse::success(request.id, serde_json::to_value(response).unwrap())
    }

    /// Handle peer status request (server mode)
    async fn handle_peer_status(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
    ) -> JsonRpcResponse {
        // Parse params
        let params: PeerStatusParams = match serde_json::from_value(request.params.clone()) {
            Ok(p) => p,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PARAMS,
                    format!("Invalid params: {}", e),
                );
            }
        };

        // Decode public key
        let public_key: [u8; 32] = match BASE64.decode(&params.public_key) {
            Ok(bytes) if bytes.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&bytes);
                arr
            }
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PUBLIC_KEY,
                    "Invalid public key: must be 32 bytes base64",
                );
            }
        };

        let s = state.lock().await;

        let peers = match &s.mode {
            Some(VpnMode::Server { peers, .. }) => Arc::clone(peers),
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    SERVER_NOT_RUNNING,
                    "Server not running",
                );
            }
        };
        drop(s);

        let peers_guard = peers.lock().await;
        match peers_guard.get_peer(&public_key) {
            Some(peer_state) => {
                let info = PeerInfo {
                    public_key: params.public_key,
                    allowed_ips: peer_state
                        .allowed_ips
                        .iter()
                        .map(|ip| ip.to_string())
                        .collect(),
                    endpoint: peer_state.endpoint.map(|e| e.to_string()),
                    has_session: peer_state.session.is_some(),
                    last_handshake: peer_state.last_handshake.map(|_| chrono_now()),
                    bytes_sent: peer_state.traffic_stats.get_sent(),
                    bytes_received: peer_state.traffic_stats.get_received(),
                };
                JsonRpcResponse::success(request.id, serde_json::to_value(info).unwrap())
            }
            None => JsonRpcResponse::error(request.id, PEER_NOT_FOUND, "Peer not found"),
        }
    }

    /// Handle add peer request (server mode - dynamic peer management)
    async fn handle_add_peer(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        _status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        // Parse params
        let params: AddPeerParams = match serde_json::from_value(request.params.clone()) {
            Ok(p) => p,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PARAMS,
                    format!("Invalid params: {}", e),
                );
            }
        };

        // Decode public key
        let public_key: [u8; 32] = match BASE64.decode(&params.public_key) {
            Ok(bytes) if bytes.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&bytes);
                arr
            }
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PUBLIC_KEY,
                    "Invalid public key: must be 32 bytes base64",
                );
            }
        };

        // Parse allowed IPs
        let allowed_ips: Vec<IpNet> = {
            let mut ips = Vec::new();
            for ip_str in &params.allowed_ips {
                match ip_str.parse::<IpNet>() {
                    Ok(ip) => ips.push(ip),
                    Err(_) => {
                        return JsonRpcResponse::error(
                            request.id,
                            INVALID_ALLOWED_IPS,
                            format!("Invalid CIDR notation: {}", ip_str),
                        );
                    }
                }
            }
            ips
        };

        // Decode optional PSK
        let psk: Option<[u8; 32]> = match &params.preshared_key {
            Some(psk_str) => match BASE64.decode(psk_str) {
                Ok(bytes) if bytes.len() == 32 => {
                    let mut arr = [0u8; 32];
                    arr.copy_from_slice(&bytes);
                    Some(arr)
                }
                _ => {
                    return JsonRpcResponse::error(
                        request.id,
                        INVALID_PARAMS,
                        "Invalid preshared key: must be 32 bytes base64",
                    );
                }
            },
            None => None,
        };

        let s = state.lock().await;

        let (peer_update_tx, peers) = match &s.mode {
            Some(VpnMode::Server {
                peer_update_tx,
                peers,
                ..
            }) => (peer_update_tx.clone(), Arc::clone(peers)),
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    SERVER_NOT_RUNNING,
                    "Server not running",
                );
            }
        };
        drop(s);

        // Check peer doesn't already exist
        {
            let peers_guard = peers.lock().await;
            if peers_guard.has_peer(&public_key) {
                return JsonRpcResponse::error(
                    request.id,
                    PEER_ALREADY_EXISTS,
                    "Peer already exists",
                );
            }
        }

        // Send update to server event loop
        if peer_update_tx
            .send(PeerUpdate::Add {
                public_key,
                psk,
                allowed_ips,
            })
            .await
            .is_err()
        {
            return JsonRpcResponse::error(
                request.id,
                SERVER_NOT_RUNNING,
                "Server channel closed",
            );
        }

        let response = AddPeerResponse {
            added: true,
            public_key: params.public_key,
        };
        JsonRpcResponse::success(request.id, serde_json::to_value(response).unwrap())
    }

    /// Handle remove peer request (server mode - dynamic peer management)
    async fn handle_remove_peer(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        _status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        // Parse params
        let params: RemovePeerParams = match serde_json::from_value(request.params.clone()) {
            Ok(p) => p,
            Err(e) => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PARAMS,
                    format!("Invalid params: {}", e),
                );
            }
        };

        // Decode public key
        let public_key: [u8; 32] = match BASE64.decode(&params.public_key) {
            Ok(bytes) if bytes.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&bytes);
                arr
            }
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    INVALID_PUBLIC_KEY,
                    "Invalid public key: must be 32 bytes base64",
                );
            }
        };

        let s = state.lock().await;

        let (peer_update_tx, peers) = match &s.mode {
            Some(VpnMode::Server {
                peer_update_tx,
                peers,
                ..
            }) => (peer_update_tx.clone(), Arc::clone(peers)),
            _ => {
                return JsonRpcResponse::error(
                    request.id,
                    SERVER_NOT_RUNNING,
                    "Server not running",
                );
            }
        };
        drop(s);

        // Check peer exists and get connection status
        let was_connected = {
            let peers_guard = peers.lock().await;
            match peers_guard.get_peer(&public_key) {
                Some(peer) => peer.session.is_some(),
                None => {
                    return JsonRpcResponse::error(request.id, PEER_NOT_FOUND, "Peer not found");
                }
            }
        };

        // Send update to server event loop
        if peer_update_tx
            .send(PeerUpdate::Remove { public_key })
            .await
            .is_err()
        {
            return JsonRpcResponse::error(
                request.id,
                SERVER_NOT_RUNNING,
                "Server channel closed",
            );
        }

        let response = RemovePeerResponse {
            removed: true,
            public_key: params.public_key,
            was_connected,
        };
        JsonRpcResponse::success(request.id, serde_json::to_value(response).unwrap())
    }

    /// Send peer event notification to IPC clients
    fn send_peer_event_notification(event: &PeerEvent, status_tx: &broadcast::Sender<String>) {
        let notification = match event {
            PeerEvent::Connected {
                public_key,
                endpoint,
            } => JsonRpcNotification::new(
                "peer_connected",
                serde_json::json!({
                    "public_key": BASE64.encode(public_key),
                    "endpoint": endpoint.to_string(),
                }),
            ),
            PeerEvent::Disconnected { public_key, reason } => JsonRpcNotification::new(
                "peer_disconnected",
                serde_json::json!({
                    "public_key": BASE64.encode(public_key),
                    "reason": reason,
                }),
            ),
            PeerEvent::Added {
                public_key,
                allowed_ips,
            } => JsonRpcNotification::new(
                "peer_added",
                serde_json::json!({
                    "public_key": BASE64.encode(public_key),
                    "allowed_ips": allowed_ips.iter().map(|ip| ip.to_string()).collect::<Vec<_>>(),
                }),
            ),
            PeerEvent::Removed {
                public_key,
                was_connected,
            } => JsonRpcNotification::new(
                "peer_removed",
                serde_json::json!({
                    "public_key": BASE64.encode(public_key),
                    "was_connected": was_connected,
                }),
            ),
        };

        if let Ok(json) = serde_json::to_string(&notification) {
            let _ = status_tx.send(json);
        }
    }

    /// Cleanup on shutdown
    pub async fn cleanup(&self) -> Result<(), SecureGuardError> {
        let s = self.state.lock().await;

        // Send shutdown signal if VPN is running
        if let Some(ref shutdown_tx) = s.shutdown_tx {
            let _ = shutdown_tx.send(true);
        }

        drop(s);

        // Give background task time to clean up
        tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;

        // Remove socket file
        #[cfg(unix)]
        if self.socket_path.exists() {
            std::fs::remove_file(&self.socket_path).ok();
        }

        Ok(())
    }
}

/// Get current time as ISO string (simple implementation without chrono crate)
fn chrono_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}s since epoch", duration.as_secs())
}

#[cfg(windows)]
impl DaemonService {
    /// Run the daemon service on Windows (named pipe)
    pub async fn run(&self) -> Result<(), SecureGuardError> {
        use tokio::net::windows::named_pipe::ServerOptions;

        let pipe_name = self.socket_path.to_string_lossy();

        tracing::info!("Daemon listening on {}", pipe_name);

        // Create first pipe instance
        let mut server = ServerOptions::new()
            .first_pipe_instance(true)
            .create(&*pipe_name)
            .map_err(|e| {
                SecureGuardError::Config(ConfigError::ParseError {
                    line: 0,
                    message: format!("Failed to create named pipe {}: {}", pipe_name, e),
                })
            })?;

        loop {
            // Wait for a client to connect
            if let Err(e) = server.connect().await {
                tracing::error!("Failed to accept connection: {}", e);
                continue;
            }

            tracing::debug!("Client connected to named pipe");

            // Create a new pipe instance for the next client before handling this one
            let new_server = ServerOptions::new()
                .create(&*pipe_name)
                .map_err(|e| {
                    SecureGuardError::Config(ConfigError::ParseError {
                        line: 0,
                        message: format!("Failed to create new pipe instance: {}", e),
                    })
                })?;

            // Move the connected pipe to the handler, use new server for next iteration
            let connected_pipe = std::mem::replace(&mut server, new_server);

            let state = Arc::clone(&self.state);
            let status_rx = self.status_tx.subscribe();
            let status_tx = self.status_tx.clone();

            tokio::spawn(async move {
                if let Err(e) =
                    Self::handle_client_windows(connected_pipe, state, status_tx, status_rx).await
                {
                    tracing::error!("Client handler error: {}", e);
                }
            });
        }
    }

    /// Handle a single client connection on Windows
    async fn handle_client_windows(
        pipe: tokio::net::windows::named_pipe::NamedPipeServer,
        state: Arc<Mutex<DaemonState>>,
        status_tx: broadcast::Sender<String>,
        mut status_rx: broadcast::Receiver<String>,
    ) -> Result<(), SecureGuardError> {
        let (reader, mut writer) = tokio::io::split(pipe);
        let mut reader = BufReader::new(reader);
        let mut line = String::new();

        loop {
            tokio::select! {
                // Handle incoming requests
                result = reader.read_line(&mut line) => {
                    match result {
                        Ok(0) => {
                            // Client disconnected
                            tracing::debug!("Client disconnected");
                            break;
                        }
                        Ok(_) => {
                            let response = Self::process_request(&line, &state, &status_tx).await;
                            let response_json = serde_json::to_string(&response)
                                .unwrap_or_else(|_| r#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"Serialization error"},"id":null}"#.to_string());

                            if let Err(e) = writer.write_all(response_json.as_bytes()).await {
                                tracing::error!("Failed to write response: {}", e);
                                break;
                            }
                            if let Err(e) = writer.write_all(b"\n").await {
                                tracing::error!("Failed to write newline: {}", e);
                                break;
                            }
                            line.clear();
                        }
                        Err(e) => {
                            tracing::error!("Read error: {}", e);
                            break;
                        }
                    }
                }

                // Forward status notifications to client
                notification = status_rx.recv() => {
                    if let Ok(notification) = notification {
                        if let Err(e) = writer.write_all(notification.as_bytes()).await {
                            tracing::error!("Failed to write notification: {}", e);
                            break;
                        }
                        if let Err(e) = writer.write_all(b"\n").await {
                            tracing::error!("Failed to write newline: {}", e);
                            break;
                        }
                    }
                }
            }
        }

        Ok(())
    }
}
