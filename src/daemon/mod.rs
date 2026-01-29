//! Daemon mode for SecureGuard VPN service
//!
//! Runs as a background service, accepting commands via Unix socket (macOS/Linux)
//! or named pipe (Windows). The Flutter UI client communicates with this daemon
//! to control the VPN connection.

pub mod ipc;

use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{broadcast, watch, Mutex};

use crate::error::ConfigError;
use crate::{SecureGuardError, WireGuardClient, WireGuardConfig};

use ipc::*;

/// Default socket path for Unix systems
#[cfg(unix)]
pub const DEFAULT_SOCKET_PATH: &str = "/var/run/secureguard.sock";

/// Default pipe name for Windows
#[cfg(windows)]
pub const DEFAULT_PIPE_NAME: &str = r"\\.\pipe\secureguard";

/// Daemon service that manages VPN connections via IPC
pub struct DaemonService {
    socket_path: PathBuf,
    state: Arc<Mutex<DaemonState>>,
    status_tx: broadcast::Sender<String>,
}

struct DaemonState {
    connection_state: ConnectionState,
    client: Option<WireGuardClient>,
    vpn_ip: Option<String>,
    server_endpoint: Option<String>,
    connected_at: Option<String>,
    bytes_sent: u64,
    bytes_received: u64,
    error_message: Option<String>,
    /// Shutdown signal sender - send true to stop the VPN
    shutdown_tx: Option<watch::Sender<bool>>,
}

impl Default for DaemonState {
    fn default() -> Self {
        Self {
            connection_state: ConnectionState::Disconnected,
            client: None,
            vpn_ip: None,
            server_endpoint: None,
            connected_at: None,
            bytes_sent: 0,
            bytes_received: 0,
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
            "connect" => Self::handle_connect(request, state, status_tx).await,
            "disconnect" => Self::handle_disconnect(request, state, status_tx).await,
            "status" => Self::handle_status(request, state).await,
            _ => JsonRpcResponse::error(
                request.id,
                METHOD_NOT_FOUND,
                format!("Method not found: {}", request.method),
            ),
        }
    }

    /// Handle connect request
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

        // Check if already connected
        {
            let s = state.lock().await;
            if s.connection_state == ConnectionState::Connected
                || s.connection_state == ConnectionState::Connecting
            {
                return JsonRpcResponse::error(
                    request.id,
                    ALREADY_CONNECTED,
                    "Already connected or connecting",
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
            .map(|e| e.to_string());

        // Extract VPN IP for status
        let vpn_ip = config.interface.address.first().map(|a| a.to_string());

        // Create and start client
        match WireGuardClient::new(config).await {
            Ok(client) => {
                // Create shutdown channel
                let (shutdown_tx, shutdown_rx) = watch::channel(false);

                let mut s = state.lock().await;
                s.client = Some(client);
                s.connection_state = ConnectionState::Connected;
                s.vpn_ip = vpn_ip;
                s.server_endpoint = server_endpoint;
                s.connected_at = Some(chrono_now());
                s.bytes_sent = 0;
                s.bytes_received = 0;
                s.shutdown_tx = Some(shutdown_tx);
                drop(s);

                let _ = Self::send_status_notification(state, status_tx).await;

                // Start the client run loop in background
                // The client.run() method handles the VPN tunnel event loop
                // We spawn it so the IPC can respond immediately
                let state_clone = Arc::clone(state);
                let status_tx_clone = status_tx.clone();
                tokio::spawn(async move {
                    // Take the client out of state to run it
                    let client_opt = {
                        let mut s = state_clone.lock().await;
                        s.client.take()
                    };

                    if let Some(mut client) = client_opt {
                        // Run client with shutdown monitoring
                        // Use tokio::select! to monitor both the VPN and shutdown signal
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
                        s.vpn_ip = None;
                        s.server_endpoint = None;
                        s.connected_at = None;
                        s.shutdown_tx = None;
                        drop(s);

                        // Send status notification
                        let _ = Self::send_status_notification(&state_clone, &status_tx_clone).await;

                        // Cleanup
                        if let Err(e) = client.cleanup().await {
                            tracing::error!("Cleanup error: {}", e);
                        }
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

    /// Handle disconnect request
    async fn handle_disconnect(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> JsonRpcResponse {
        let mut s = state.lock().await;

        if s.connection_state == ConnectionState::Disconnected {
            return JsonRpcResponse::error(request.id, NOT_CONNECTED, "Not connected");
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

        // The background task will update state to Disconnected when it finishes
        // But we can respond immediately since we've signaled the shutdown
        JsonRpcResponse::success(request.id, serde_json::json!({"disconnected": true}))
    }

    /// Handle status request
    async fn handle_status(
        request: JsonRpcRequest,
        state: &Arc<Mutex<DaemonState>>,
    ) -> JsonRpcResponse {
        let s = state.lock().await;

        let status = StatusResponse {
            state: s.connection_state,
            vpn_ip: s.vpn_ip.clone(),
            server_endpoint: s.server_endpoint.clone(),
            connected_at: s.connected_at.clone(),
            bytes_sent: s.bytes_sent,
            bytes_received: s.bytes_received,
            last_handshake: None,
            error_message: s.error_message.clone(),
        };

        JsonRpcResponse::success(request.id, serde_json::to_value(status).unwrap())
    }

    /// Send status notification to all connected clients
    async fn send_status_notification(
        state: &Arc<Mutex<DaemonState>>,
        status_tx: &broadcast::Sender<String>,
    ) -> Result<(), ()> {
        let s = state.lock().await;

        let params = StatusChangedParams {
            state: s.connection_state,
            vpn_ip: s.vpn_ip.clone(),
            server_endpoint: s.server_endpoint.clone(),
            connected_at: s.connected_at.clone(),
            bytes_sent: s.bytes_sent,
            bytes_received: s.bytes_received,
        };

        let notification = JsonRpcNotification::new(
            "status_changed",
            serde_json::to_value(params).unwrap_or_default(),
        );

        let json = serde_json::to_string(&notification).map_err(|_| ())?;
        status_tx.send(json).map_err(|_| ())?;

        Ok(())
    }

    /// Cleanup on shutdown
    pub async fn cleanup(&self) -> Result<(), SecureGuardError> {
        let mut s = self.state.lock().await;

        // Send shutdown signal if VPN is running
        if let Some(ref shutdown_tx) = s.shutdown_tx {
            let _ = shutdown_tx.send(true);
        }

        // Clean up any client that wasn't moved to background task
        if let Some(ref mut client) = s.client {
            client.cleanup().await?;
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
        // Windows named pipe implementation would go here
        // For now, return an error as Windows support is not yet implemented
        Err(SecureGuardError::Config(ConfigError::ParseError {
            line: 0,
            message: "Windows daemon mode not yet implemented".to_string(),
        }))
    }
}
