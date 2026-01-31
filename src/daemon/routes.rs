//! REST API route handlers for the daemon HTTP server
//!
//! Provides HTTP endpoints that map to the existing daemon functionality.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Json, Response,
    },
    routing::{delete, get, post, put},
    Router,
};
use serde::{Deserialize, Serialize};
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::{broadcast, Mutex};
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;

use super::ipc::*;
use super::{DaemonState, VpnMode};
use crate::protocol::session::PeerManager;
use crate::{WireGuardClient, WireGuardConfig, WireGuardServer};

/// Shared application state for route handlers
#[derive(Clone)]
pub struct AppState {
    pub daemon_state: Arc<Mutex<DaemonState>>,
    pub status_tx: broadcast::Sender<String>,
}

/// API error response
#[derive(Debug, Serialize)]
pub struct ApiError {
    pub code: i32,
    pub message: String,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self.code {
            code if code == NOT_CONNECTED => StatusCode::CONFLICT,
            code if code == ALREADY_CONNECTED || code == ALREADY_RUNNING => StatusCode::CONFLICT,
            code if code == INVALID_CONFIG || code == INVALID_PARAMS => StatusCode::BAD_REQUEST,
            code if code == PEER_NOT_FOUND => StatusCode::NOT_FOUND,
            code if code == PEER_ALREADY_EXISTS => StatusCode::CONFLICT,
            code if code == UPDATE_FAILED => StatusCode::INTERNAL_SERVER_ERROR,
            _ => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, Json(self)).into_response()
    }
}

/// Build the API router with all routes
pub fn build_router(state: AppState) -> Router {
    Router::new()
        // Client mode endpoints
        .route("/api/v1/connect", post(handle_connect))
        .route("/api/v1/disconnect", post(handle_disconnect))
        .route("/api/v1/status", get(handle_status))
        .route("/api/v1/config", put(handle_update_config))
        // Server mode lifecycle
        .route("/api/v1/server/start", post(handle_start_server))
        .route("/api/v1/server/stop", post(handle_stop_server))
        // Server mode peer management
        .route("/api/v1/server/peers", get(handle_list_peers))
        .route("/api/v1/server/peers", post(handle_add_peer))
        .route("/api/v1/server/peers/:pubkey", get(handle_peer_status))
        .route("/api/v1/server/peers/:pubkey", delete(handle_remove_peer))
        // SSE events stream
        .route("/api/v1/events", get(handle_events_sse))
        .with_state(state)
}

// ============================================================================
// Request/Response Types
// ============================================================================

#[derive(Debug, Deserialize)]
pub struct ConnectRequest {
    pub config: String,
}

#[derive(Debug, Serialize)]
pub struct ConnectResponse {
    pub connected: bool,
}

#[derive(Debug, Serialize)]
pub struct DisconnectResponse {
    pub disconnected: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateConfigRequest {
    pub config: String,
}

#[derive(Debug, Deserialize)]
pub struct StartServerRequest {
    pub config: String,
}

#[derive(Debug, Serialize)]
pub struct StartServerResponse {
    pub started: bool,
}

#[derive(Debug, Serialize)]
pub struct StopServerResponse {
    pub stopped: bool,
}

#[derive(Debug, Deserialize)]
pub struct AddPeerRequest {
    pub public_key: String,
    pub allowed_ips: Vec<String>,
    pub preshared_key: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AddPeerResponse {
    pub added: bool,
    pub public_key: String,
}

#[derive(Debug, Serialize)]
pub struct RemovePeerResponse {
    pub removed: bool,
    pub public_key: String,
    pub was_connected: bool,
}

#[derive(Debug, Deserialize)]
pub struct SseQueryParams {
    pub token: Option<String>,
}

// ============================================================================
// Client Mode Handlers
// ============================================================================

/// POST /api/v1/connect - Connect to VPN server
pub async fn handle_connect(
    State(state): State<AppState>,
    Json(request): Json<ConnectRequest>,
) -> Result<Json<ConnectResponse>, ApiError> {
    // Check if already running
    {
        let s = state.daemon_state.lock().await;
        if s.connection_state == ConnectionState::Connected
            || s.connection_state == ConnectionState::Connecting
        {
            return Err(ApiError {
                code: ALREADY_CONNECTED,
                message: "Already connected or connecting".to_string(),
            });
        }
    }

    // Update state to connecting
    {
        let mut s = state.daemon_state.lock().await;
        s.connection_state = ConnectionState::Connecting;
        s.error_message = None;
    }

    send_status_notification(&state).await;

    // Parse config
    let config = WireGuardConfig::from_string(&request.config).map_err(|e| {
        let error_msg = format!("Invalid config: {}", e);
        // Reset state on error
        let state_clone = state.clone();
        let error_msg_clone = error_msg.clone();
        tokio::spawn(async move {
            let mut s = state_clone.daemon_state.lock().await;
            s.connection_state = ConnectionState::Error;
            s.error_message = Some(error_msg_clone);
        });
        ApiError {
            code: INVALID_CONFIG,
            message: error_msg,
        }
    })?;

    // Extract endpoint and VPN IP
    let server_endpoint = config
        .peers
        .first()
        .and_then(|p| p.endpoint.as_ref())
        .map(|e| e.to_string())
        .unwrap_or_default();

    let vpn_ip = config
        .interface
        .address
        .first()
        .map(|a| a.to_string())
        .unwrap_or_default();

    // Get traffic stats
    let traffic_stats = {
        let s = state.daemon_state.lock().await;
        Arc::clone(&s.traffic_stats)
    };

    let config_for_storage = config.clone();

    // Create client
    match WireGuardClient::new(config, Some(traffic_stats)).await {
        Ok(client) => {
            let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

            {
                let mut s = state.daemon_state.lock().await;
                s.connection_state = ConnectionState::Connected;
                s.mode = Some(VpnMode::Client {
                    vpn_ip: vpn_ip.clone(),
                    server_endpoint: server_endpoint.clone(),
                    current_config: config_for_storage,
                    previous_config: None,
                });
                s.started_at = Some(chrono_now());
                s.traffic_stats.reset();
                s.shutdown_tx = Some(shutdown_tx);
            }

            send_status_notification(&state).await;

            // Spawn client task
            spawn_client_task(client, shutdown_rx, state.daemon_state.clone(), state.status_tx.clone());

            Ok(Json(ConnectResponse { connected: true }))
        }
        Err(e) => {
            let mut s = state.daemon_state.lock().await;
            s.connection_state = ConnectionState::Error;
            s.error_message = Some(format!("{}", e));
            drop(s);

            send_status_notification(&state).await;

            Err(ApiError {
                code: CONNECTION_FAILED,
                message: format!("Connection failed: {}", e),
            })
        }
    }
}

/// POST /api/v1/disconnect - Disconnect VPN
pub async fn handle_disconnect(
    State(state): State<AppState>,
) -> Result<Json<DisconnectResponse>, ApiError> {
    let mut s = state.daemon_state.lock().await;

    match &s.mode {
        Some(VpnMode::Client { .. }) => {}
        Some(VpnMode::Server { .. }) => {
            return Err(ApiError {
                code: NOT_CONNECTED,
                message: "Use /api/v1/server/stop to stop server mode".to_string(),
            });
        }
        None => {
            return Err(ApiError {
                code: NOT_CONNECTED,
                message: "Not connected".to_string(),
            });
        }
    }

    s.connection_state = ConnectionState::Disconnecting;

    if let Some(ref shutdown_tx) = s.shutdown_tx {
        let _ = shutdown_tx.send(true);
    }
    drop(s);

    send_status_notification(&state).await;
    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

    Ok(Json(DisconnectResponse { disconnected: true }))
}

/// GET /api/v1/status - Get current status
pub async fn handle_status(State(state): State<AppState>) -> Json<serde_json::Value> {
    let s = state.daemon_state.lock().await;

    match &s.mode {
        Some(VpnMode::Client { vpn_ip, server_endpoint, .. }) => {
            Json(serde_json::json!({
                "state": s.connection_state,
                "vpn_ip": vpn_ip,
                "server_endpoint": server_endpoint,
                "connected_at": s.started_at,
                "bytes_sent": s.traffic_stats.get_sent(),
                "bytes_received": s.traffic_stats.get_received(),
                "error_message": s.error_message,
            }))
        }
        Some(VpnMode::Server { listen_port, interface_address, peers, .. }) => {
            let peers = Arc::clone(peers);
            let listen_port = *listen_port;
            let interface_address = interface_address.clone();
            let state = s.connection_state.clone();
            let started_at = s.started_at.clone();
            let bytes_sent = s.traffic_stats.get_sent();
            let bytes_received = s.traffic_stats.get_received();
            let error_message = s.error_message.clone();
            drop(s); // Release daemon_state lock before acquiring peers lock

            let peers_guard = peers.lock().await;
            let peer_count = peers_guard.len();
            let connected_peer_count = peers_guard.connected_count();
            drop(peers_guard);

            Json(serde_json::json!({
                "state": state,
                "mode": "server",
                "listen_port": listen_port,
                "interface_address": interface_address,
                "peer_count": peer_count,
                "connected_peer_count": connected_peer_count,
                "started_at": started_at,
                "bytes_sent": bytes_sent,
                "bytes_received": bytes_received,
                "error_message": error_message,
            }))
        }
        None => {
            Json(serde_json::json!({
                "state": s.connection_state,
                "bytes_sent": 0,
                "bytes_received": 0,
                "error_message": s.error_message,
            }))
        }
    }
}

/// PUT /api/v1/config - Update config dynamically
///
/// This endpoint updates the VPN configuration while connected.
/// It validates the new config before disconnecting, then reconnects with the new config.
/// If reconnection fails, it attempts to rollback to the previous working config.
pub async fn handle_update_config(
    State(state): State<AppState>,
    Json(request): Json<UpdateConfigRequest>,
) -> Result<Json<UpdateConfigResponse>, ApiError> {
    // Step 1: Parse and validate new config BEFORE disconnecting
    let new_config = WireGuardConfig::from_string(&request.config).map_err(|e| ApiError {
        code: INVALID_CONFIG,
        message: format!("Invalid config: {}", e),
    })?;

    // Validate config has required fields for client mode
    if new_config.peers.is_empty() {
        return Err(ApiError {
            code: INVALID_CONFIG,
            message: "Config must have at least one peer".to_string(),
        });
    }

    let peer = &new_config.peers[0];
    if peer.endpoint.is_none() {
        return Err(ApiError {
            code: INVALID_CONFIG,
            message: "Peer must have an endpoint for client mode".to_string(),
        });
    }

    // Extract new connection info
    let new_vpn_ip = new_config
        .interface
        .address
        .first()
        .map(|a| a.addr().to_string())
        .unwrap_or_default();

    let new_endpoint = new_config
        .peers
        .first()
        .and_then(|p| p.endpoint.as_ref())
        .map(|e| e.to_string())
        .unwrap_or_default();

    // Step 2: Check current state and get current config for potential rollback
    let (current_config, was_connected) = {
        let s = state.daemon_state.lock().await;

        match &s.mode {
            Some(VpnMode::Client { current_config, .. }) => {
                let connected = s.connection_state == ConnectionState::Connected;
                (Some(current_config.clone()), connected)
            }
            Some(VpnMode::Server { .. }) => {
                return Err(ApiError {
                    code: INVALID_CONFIG,
                    message: "Cannot update config in server mode".to_string(),
                });
            }
            None => {
                return Err(ApiError {
                    code: NOT_CONNECTED,
                    message: "Not in client mode. Use /api/v1/connect to start a new connection.".to_string(),
                });
            }
        }
    };

    // Step 3: If connected, disconnect current session
    if was_connected {
        {
            let mut s = state.daemon_state.lock().await;
            s.connection_state = ConnectionState::Disconnecting;

            // Send shutdown signal to the background task
            if let Some(ref shutdown_tx) = s.shutdown_tx {
                let _ = shutdown_tx.send(true);
            }
        }

        // Give the background task time to clean up
        tokio::time::sleep(tokio::time::Duration::from_millis(200)).await;
    }

    // Step 4: Reconnect with new config
    let traffic_stats = {
        let s = state.daemon_state.lock().await;
        Arc::clone(&s.traffic_stats)
    };

    let config_for_storage = new_config.clone();

    match WireGuardClient::new(new_config, Some(traffic_stats)).await {
        Ok(client) => {
            // Create shutdown channel
            let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

            {
                let mut s = state.daemon_state.lock().await;
                s.connection_state = ConnectionState::Connected;
                s.mode = Some(VpnMode::Client {
                    vpn_ip: new_vpn_ip.clone(),
                    server_endpoint: new_endpoint.clone(),
                    current_config: config_for_storage,
                    previous_config: current_config, // Store old config for potential future rollback
                });
                s.started_at = Some(chrono_now());
                s.shutdown_tx = Some(shutdown_tx);
            }

            send_status_notification(&state).await;

            // Send config_updated notification
            let notification = serde_json::json!({
                "jsonrpc": "2.0",
                "method": "config_updated",
                "params": {
                    "vpn_ip": new_vpn_ip,
                    "server_endpoint": new_endpoint,
                    "reconnected": was_connected
                }
            });
            let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());

            // Start the client run loop in background
            spawn_client_task(client, shutdown_rx, state.daemon_state.clone(), state.status_tx.clone());

            Ok(Json(UpdateConfigResponse {
                updated: true,
                vpn_ip: Some(new_vpn_ip),
                server_endpoint: Some(new_endpoint),
            }))
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
                    let s = state.daemon_state.lock().await;
                    Arc::clone(&s.traffic_stats)
                };

                match WireGuardClient::new(prev_config.clone(), Some(rollback_traffic_stats)).await {
                    Ok(rollback_client) => {
                        tracing::info!("Rollback successful, reconnected with previous config");

                        let (rollback_shutdown_tx, rollback_shutdown_rx) = tokio::sync::watch::channel(false);

                        {
                            let mut s = state.daemon_state.lock().await;
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

                        send_status_notification(&state).await;

                        // Send rolled_back notification
                        let notification = serde_json::json!({
                            "jsonrpc": "2.0",
                            "method": "config_update_failed",
                            "params": {
                                "error": e.to_string(),
                                "rolled_back": true
                            }
                        });
                        let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());

                        // Spawn background task for rollback session
                        spawn_client_task(rollback_client, rollback_shutdown_rx, state.daemon_state.clone(), state.status_tx.clone());

                        return Err(ApiError {
                            code: UPDATE_FAILED,
                            message: format!("Config update failed but rolled back: {}", e),
                        });
                    }
                    Err(rollback_err) => {
                        tracing::error!("Rollback also failed: {}", rollback_err);

                        // Both failed - enter error state
                        let notification = serde_json::json!({
                            "jsonrpc": "2.0",
                            "method": "config_update_failed",
                            "params": {
                                "error": format!("Update failed: {}. Rollback also failed: {}", e, rollback_err),
                                "rolled_back": false
                            }
                        });
                        let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());

                        {
                            let mut s = state.daemon_state.lock().await;
                            s.connection_state = ConnectionState::Error;
                            s.error_message = Some(format!(
                                "Update failed: {}. Rollback failed: {}",
                                e, rollback_err
                            ));
                            s.mode = None;
                        }

                        send_status_notification(&state).await;

                        return Err(ApiError {
                            code: UPDATE_FAILED,
                            message: format!(
                                "Config update failed and rollback failed: {} / {}",
                                e, rollback_err
                            ),
                        });
                    }
                }
            } else {
                // No previous config to roll back to
                let notification = serde_json::json!({
                    "jsonrpc": "2.0",
                    "method": "config_update_failed",
                    "params": {
                        "error": e.to_string(),
                        "rolled_back": false
                    }
                });
                let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());

                {
                    let mut s = state.daemon_state.lock().await;
                    s.connection_state = ConnectionState::Error;
                    s.error_message = Some(format!("Config update failed: {}", e));
                    s.mode = None;
                }

                send_status_notification(&state).await;

                Err(ApiError {
                    code: UPDATE_FAILED,
                    message: format!("Config update failed (no rollback available): {}", e),
                })
            }
        }
    }
}

// ============================================================================
// Server Mode Handlers
// ============================================================================

/// POST /api/v1/server/start - Start VPN server
pub async fn handle_start_server(
    State(state): State<AppState>,
    Json(request): Json<StartServerRequest>,
) -> Result<Json<StartServerResponse>, ApiError> {
    // Check if already running
    {
        let s = state.daemon_state.lock().await;
        if s.connection_state == ConnectionState::Connected {
            return Err(ApiError {
                code: ALREADY_RUNNING,
                message: "Server or client already running".to_string(),
            });
        }
    }

    // Parse config
    let config = WireGuardConfig::from_string(&request.config).map_err(|e| ApiError {
        code: INVALID_CONFIG,
        message: format!("Invalid config: {}", e),
    })?;

    // Update state
    {
        let mut s = state.daemon_state.lock().await;
        s.connection_state = ConnectionState::Connecting;
        s.error_message = None;
    }

    send_status_notification(&state).await;

    let listen_port = config.interface.listen_port.unwrap_or(51820);
    let interface_address = config
        .interface
        .address
        .first()
        .map(|a| a.to_string())
        .unwrap_or_default();

    let traffic_stats = {
        let s = state.daemon_state.lock().await;
        Arc::clone(&s.traffic_stats)
    };

    // Create server with channels for dynamic peer management
    let (peer_update_tx, peer_update_rx) = tokio::sync::mpsc::channel(16);
    let (peer_event_tx, mut peer_event_rx) = tokio::sync::mpsc::channel(16);
    let peers = Arc::new(Mutex::new(PeerManager::new()));

    match WireGuardServer::new_with_channels(
        config.clone(),
        peers.clone(),
        peer_update_rx,
        peer_event_tx,
        traffic_stats,
    ).await {
        Ok(server) => {
            let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

            {
                let mut s = state.daemon_state.lock().await;
                s.connection_state = ConnectionState::Connected;
                s.mode = Some(VpnMode::Server {
                    listen_port,
                    interface_address: interface_address.clone(),
                    peer_update_tx,
                    peers: peers.clone(),
                });
                s.started_at = Some(chrono_now());
                s.traffic_stats.reset();
                s.shutdown_tx = Some(shutdown_tx);
            }

            send_status_notification(&state).await;

            // Spawn server task
            spawn_server_task(server, shutdown_rx, state.daemon_state.clone(), state.status_tx.clone());

            // Spawn peer event handler
            let status_tx = state.status_tx.clone();
            tokio::spawn(async move {
                while let Some(event) = peer_event_rx.recv().await {
                    let notification = match event {
                        crate::server::PeerEvent::Connected { public_key, endpoint } => {
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "method": "peer_connected",
                                "params": {
                                    "public_key": base64::engine::general_purpose::STANDARD.encode(public_key),
                                    "endpoint": endpoint.to_string(),
                                }
                            })
                        }
                        crate::server::PeerEvent::Disconnected { public_key, reason } => {
                            serde_json::json!({
                                "jsonrpc": "2.0",
                                "method": "peer_disconnected",
                                "params": {
                                    "public_key": base64::engine::general_purpose::STANDARD.encode(public_key),
                                    "reason": reason,
                                }
                            })
                        }
                        _ => continue,
                    };
                    let _ = status_tx.send(serde_json::to_string(&notification).unwrap());
                }
            });

            Ok(Json(StartServerResponse { started: true }))
        }
        Err(e) => {
            let mut s = state.daemon_state.lock().await;
            s.connection_state = ConnectionState::Error;
            s.error_message = Some(format!("{}", e));
            drop(s);

            send_status_notification(&state).await;

            Err(ApiError {
                code: CONNECTION_FAILED,
                message: format!("Failed to start server: {}", e),
            })
        }
    }
}

/// POST /api/v1/server/stop - Stop VPN server
pub async fn handle_stop_server(
    State(state): State<AppState>,
) -> Result<Json<StopServerResponse>, ApiError> {
    let mut s = state.daemon_state.lock().await;

    match &s.mode {
        Some(VpnMode::Server { .. }) => {}
        Some(VpnMode::Client { .. }) => {
            return Err(ApiError {
                code: SERVER_NOT_RUNNING,
                message: "Use /api/v1/disconnect for client mode".to_string(),
            });
        }
        None => {
            return Err(ApiError {
                code: SERVER_NOT_RUNNING,
                message: "Server not running".to_string(),
            });
        }
    }

    s.connection_state = ConnectionState::Disconnecting;

    if let Some(ref shutdown_tx) = s.shutdown_tx {
        let _ = shutdown_tx.send(true);
    }
    drop(s);

    send_status_notification(&state).await;
    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

    Ok(Json(StopServerResponse { stopped: true }))
}

/// GET /api/v1/server/peers - List all peers
pub async fn handle_list_peers(State(state): State<AppState>) -> Result<Json<ListPeersResponse>, ApiError> {
    let s = state.daemon_state.lock().await;

    let peers = match &s.mode {
        Some(VpnMode::Server { peers, .. }) => peers.clone(),
        _ => {
            return Err(ApiError {
                code: SERVER_NOT_RUNNING,
                message: "Server not running".to_string(),
            });
        }
    };
    drop(s);

    let peers_guard = peers.lock().await;
    let peer_list: Vec<PeerInfo> = peers_guard
        .iter()
        .map(|peer_state| PeerInfo {
            public_key: base64::engine::general_purpose::STANDARD.encode(peer_state.public_key),
            endpoint: peer_state.endpoint.map(|e: std::net::SocketAddr| e.to_string()),
            allowed_ips: peer_state.allowed_ips.iter().map(|ip: &ipnet::IpNet| ip.to_string()).collect(),
            has_session: peer_state.session.is_some(),
            last_handshake: peer_state.last_handshake.map(|_| chrono_now()),
            bytes_sent: peer_state.traffic_stats.get_sent(),
            bytes_received: peer_state.traffic_stats.get_received(),
        })
        .collect();

    Ok(Json(ListPeersResponse { peers: peer_list }))
}

/// GET /api/v1/server/peers/:pubkey - Get specific peer status
pub async fn handle_peer_status(
    State(state): State<AppState>,
    Path(pubkey): Path<String>,
) -> Result<Json<PeerInfo>, ApiError> {
    let s = state.daemon_state.lock().await;

    let peers = match &s.mode {
        Some(VpnMode::Server { peers, .. }) => peers.clone(),
        _ => {
            return Err(ApiError {
                code: SERVER_NOT_RUNNING,
                message: "Server not running".to_string(),
            });
        }
    };
    drop(s);

    // Decode public key
    let pubkey_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD
        .decode(&pubkey)
        .map_err(|_| ApiError {
            code: INVALID_PUBLIC_KEY,
            message: "Invalid public key format".to_string(),
        })?
        .try_into()
        .map_err(|_| ApiError {
            code: INVALID_PUBLIC_KEY,
            message: "Public key must be 32 bytes".to_string(),
        })?;

    let peers_guard = peers.lock().await;
    let peer_state = peers_guard.get_peer(&pubkey_bytes).ok_or(ApiError {
        code: PEER_NOT_FOUND,
        message: "Peer not found".to_string(),
    })?;

    Ok(Json(PeerInfo {
        public_key: pubkey,
        endpoint: peer_state.endpoint.map(|e| e.to_string()),
        allowed_ips: peer_state.allowed_ips.iter().map(|ip| ip.to_string()).collect(),
        has_session: peer_state.session.is_some(),
        last_handshake: peer_state.last_handshake.map(|_| chrono_now()),
        bytes_sent: peer_state.traffic_stats.get_sent(),
        bytes_received: peer_state.traffic_stats.get_received(),
    }))
}

/// POST /api/v1/server/peers - Add a new peer
pub async fn handle_add_peer(
    State(state): State<AppState>,
    Json(request): Json<AddPeerRequest>,
) -> Result<Json<AddPeerResponse>, ApiError> {
    let s = state.daemon_state.lock().await;

    let peer_update_tx = match &s.mode {
        Some(VpnMode::Server { peer_update_tx, .. }) => peer_update_tx.clone(),
        _ => {
            return Err(ApiError {
                code: SERVER_NOT_RUNNING,
                message: "Server not running".to_string(),
            });
        }
    };
    drop(s);

    // Decode public key
    let pubkey_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD
        .decode(&request.public_key)
        .map_err(|_| ApiError {
            code: INVALID_PUBLIC_KEY,
            message: "Invalid public key format".to_string(),
        })?
        .try_into()
        .map_err(|_| ApiError {
            code: INVALID_PUBLIC_KEY,
            message: "Public key must be 32 bytes".to_string(),
        })?;

    // Parse allowed IPs
    let allowed_ips: Vec<ipnet::IpNet> = request
        .allowed_ips
        .iter()
        .map(|ip| ip.parse())
        .collect::<Result<_, _>>()
        .map_err(|e| ApiError {
            code: INVALID_ALLOWED_IPS,
            message: format!("Invalid allowed IP: {}", e),
        })?;

    // Decode optional PSK
    let psk = if let Some(ref psk_str) = request.preshared_key {
        let psk_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD
            .decode(psk_str)
            .map_err(|_| ApiError {
                code: INVALID_PARAMS,
                message: "Invalid preshared key format".to_string(),
            })?
            .try_into()
            .map_err(|_| ApiError {
                code: INVALID_PARAMS,
                message: "Preshared key must be 32 bytes".to_string(),
            })?;
        Some(psk_bytes)
    } else {
        None
    };

    // Send peer update
    peer_update_tx
        .send(crate::server::PeerUpdate::Add {
            public_key: pubkey_bytes,
            psk,
            allowed_ips,
        })
        .await
        .map_err(|_| ApiError {
            code: INTERNAL_ERROR,
            message: "Failed to send peer update".to_string(),
        })?;

    // Send notification
    let notification = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "peer_added",
        "params": {
            "public_key": request.public_key,
            "allowed_ips": request.allowed_ips,
        }
    });
    let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());

    Ok(Json(AddPeerResponse {
        added: true,
        public_key: request.public_key,
    }))
}

/// DELETE /api/v1/server/peers/:pubkey - Remove a peer
pub async fn handle_remove_peer(
    State(state): State<AppState>,
    Path(pubkey): Path<String>,
) -> Result<Json<RemovePeerResponse>, ApiError> {
    let s = state.daemon_state.lock().await;

    let (peer_update_tx, peers) = match &s.mode {
        Some(VpnMode::Server { peer_update_tx, peers, .. }) => (peer_update_tx.clone(), peers.clone()),
        _ => {
            return Err(ApiError {
                code: SERVER_NOT_RUNNING,
                message: "Server not running".to_string(),
            });
        }
    };
    drop(s);

    // Decode public key
    let pubkey_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD
        .decode(&pubkey)
        .map_err(|_| ApiError {
            code: INVALID_PUBLIC_KEY,
            message: "Invalid public key format".to_string(),
        })?
        .try_into()
        .map_err(|_| ApiError {
            code: INVALID_PUBLIC_KEY,
            message: "Public key must be 32 bytes".to_string(),
        })?;

    // Check if peer exists and was connected
    let was_connected = {
        let peers_guard = peers.lock().await;
        peers_guard
            .get_peer(&pubkey_bytes)
            .map(|p| p.session.is_some())
            .unwrap_or(false)
    };

    // Send remove update
    peer_update_tx
        .send(crate::server::PeerUpdate::Remove {
            public_key: pubkey_bytes,
        })
        .await
        .map_err(|_| ApiError {
            code: INTERNAL_ERROR,
            message: "Failed to send peer update".to_string(),
        })?;

    // Send notification
    let notification = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "peer_removed",
        "params": {
            "public_key": pubkey,
            "was_connected": was_connected,
        }
    });
    let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());

    Ok(Json(RemovePeerResponse {
        removed: true,
        public_key: pubkey,
        was_connected,
    }))
}

// ============================================================================
// Server-Sent Events
// ============================================================================

/// GET /api/v1/events - SSE stream for real-time notifications
pub async fn handle_events_sse(
    State(state): State<AppState>,
) -> Sse<impl tokio_stream::Stream<Item = Result<Event, Infallible>>> {
    let rx = state.status_tx.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(|result| {
        result.ok().map(|msg| {
            Ok(Event::default().data(msg))
        })
    });

    Sse::new(stream).keep_alive(KeepAlive::default())
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Get current timestamp in ISO 8601 format
fn chrono_now() -> String {
    use std::time::SystemTime;
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    format!("{}", now)
}

/// Send status notification to all connected clients
async fn send_status_notification(state: &AppState) {
    let s = state.daemon_state.lock().await;

    let notification = match &s.mode {
        Some(VpnMode::Client { vpn_ip, server_endpoint, .. }) => {
            serde_json::json!({
                "jsonrpc": "2.0",
                "method": "status_changed",
                "params": {
                    "state": s.connection_state,
                    "vpn_ip": vpn_ip,
                    "server_endpoint": server_endpoint,
                    "connected_at": s.started_at,
                    "bytes_sent": s.traffic_stats.get_sent(),
                    "bytes_received": s.traffic_stats.get_received(),
                }
            })
        }
        Some(VpnMode::Server { listen_port, interface_address, peers, .. }) => {
            let peers = Arc::clone(peers);
            let listen_port = *listen_port;
            let interface_address = interface_address.clone();
            let state = s.connection_state.clone();
            let started_at = s.started_at.clone();
            let bytes_sent = s.traffic_stats.get_sent();
            let bytes_received = s.traffic_stats.get_received();
            drop(s); // Release daemon_state lock before acquiring peers lock

            let peers_guard = peers.lock().await;
            let peer_count = peers_guard.len();
            let connected_peer_count = peers_guard.connected_count();

            serde_json::json!({
                "jsonrpc": "2.0",
                "method": "server_status_changed",
                "params": {
                    "state": state,
                    "listen_port": listen_port,
                    "interface_address": interface_address,
                    "peer_count": peer_count,
                    "connected_peer_count": connected_peer_count,
                    "started_at": started_at,
                    "bytes_sent": bytes_sent,
                    "bytes_received": bytes_received,
                }
            })
        }
        None => {
            serde_json::json!({
                "jsonrpc": "2.0",
                "method": "status_changed",
                "params": {
                    "state": s.connection_state,
                    "bytes_sent": 0,
                    "bytes_received": 0,
                }
            })
        }
    };

    let _ = state.status_tx.send(serde_json::to_string(&notification).unwrap());
}

/// Spawn client VPN task
fn spawn_client_task(
    client: WireGuardClient,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
    state: Arc<Mutex<DaemonState>>,
    status_tx: broadcast::Sender<String>,
) {
    tokio::spawn(async move {
        let mut client = client;
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
                tracing::info!("Client shutdown signal received");
                Ok(())
            }
        };

        // Update state on completion
        {
            let mut s = state.lock().await;
            match result {
                Ok(_) => {
                    tracing::info!("VPN client disconnected");
                    s.connection_state = ConnectionState::Disconnected;
                }
                Err(ref e) => {
                    tracing::error!("VPN client error: {}", e);
                    s.connection_state = ConnectionState::Error;
                    s.error_message = Some(format!("{}", e));
                }
            }
            s.mode = None;
            s.started_at = None;
            s.shutdown_tx = None;
        }

        // Send final status notification
        let notification = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "status_changed",
            "params": {
                "state": "disconnected",
                "bytes_sent": 0,
                "bytes_received": 0,
            }
        });
        let _ = status_tx.send(serde_json::to_string(&notification).unwrap());

        // Cleanup
        if let Err(e) = client.cleanup().await {
            tracing::error!("Client cleanup error: {}", e);
        }
    });
}

/// Spawn server VPN task
fn spawn_server_task(
    server: WireGuardServer,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
    state: Arc<Mutex<DaemonState>>,
    status_tx: broadcast::Sender<String>,
) {
    tokio::spawn(async move {
        let mut server = server;
        let mut shutdown_rx = shutdown_rx;

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

        // Update state on completion
        {
            let mut s = state.lock().await;
            match result {
                Ok(_) => {
                    tracing::info!("VPN server stopped");
                    s.connection_state = ConnectionState::Disconnected;
                }
                Err(ref e) => {
                    tracing::error!("VPN server error: {}", e);
                    s.connection_state = ConnectionState::Error;
                    s.error_message = Some(format!("{}", e));
                }
            }
            s.mode = None;
            s.started_at = None;
            s.shutdown_tx = None;
        }

        // Send final status notification
        let notification = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "server_status_changed",
            "params": {
                "state": "disconnected",
                "peer_count": 0,
                "connected_peer_count": 0,
                "bytes_sent": 0,
                "bytes_received": 0,
            }
        });
        let _ = status_tx.send(serde_json::to_string(&notification).unwrap());

        // Cleanup
        if let Err(e) = server.cleanup().await {
            tracing::error!("Server cleanup error: {}", e);
        }
    });
}

use base64::Engine;
