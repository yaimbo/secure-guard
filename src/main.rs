//! MinnowVPN CLI - WireGuard VPN Client/Server
//!
//! A proof-of-concept WireGuard implementation that can operate as either
//! a client (initiator) or server (responder) using standard WireGuard
//! configuration files. Can also run as a daemon service for IPC control.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use tracing_subscriber::{fmt, EnvFilter};

use minnowvpn::error::{ConfigError, NetworkError, ProtocolError, TunnelError};
use minnowvpn::{DaemonService, MinnowVpnError, WireGuardClient, WireGuardConfig, WireGuardServer};

/// Operating mode for direct VPN connection
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Client,
    Server,
}

/// MinnowVPN - WireGuard VPN Client/Server
#[derive(Parser, Debug)]
#[command(name = "minnowvpn")]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Path to WireGuard configuration file (required for --client/--server modes)
    #[arg(short, long, required_unless_present = "daemon")]
    config: Option<PathBuf>,

    /// Enable verbose logging
    #[arg(short, long)]
    verbose: bool,

    /// Force server mode (listen for incoming connections)
    #[arg(long, conflicts_with_all = ["client", "daemon"])]
    server: bool,

    /// Force client mode (connect to peer endpoint)
    #[arg(long, conflicts_with_all = ["server", "daemon"])]
    client: bool,

    /// Run as a daemon service (IPC mode for Flutter UI)
    #[arg(long, conflicts_with_all = ["server", "client"])]
    daemon: bool,

    /// HTTP port for daemon REST API (default: 51820 for client, 51821 for server)
    #[arg(long, requires = "daemon")]
    http_port: Option<u16>,

    /// Path to write the auth token file (default: /var/run/minnowvpn/auth-token)
    #[arg(long, requires = "daemon")]
    token_path: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> ExitCode {
    let args = Args::parse();

    // Set up logging
    let filter = if args.verbose {
        EnvFilter::new("debug")
    } else {
        EnvFilter::new("info")
    };

    fmt()
        .with_env_filter(filter)
        .with_target(false)
        .init();

    // Run the client
    match run(args).await {
        Ok(_) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("Error: {}", user_message(&e));
            exit_code(&e)
        }
    }
}

async fn run(args: Args) -> Result<(), MinnowVpnError> {
    // Check if running in daemon mode
    if args.daemon {
        return run_daemon(args).await;
    }

    // Normal client/server mode requires a config file
    let config_path = args.config
        .as_ref()
        .expect("Config required for client/server mode")
        .to_string_lossy()
        .to_string();
    tracing::info!("Loading configuration from: {}", config_path);

    let config = WireGuardConfig::from_file(&config_path)?;

    // Determine operating mode
    let mode = determine_mode(&args, &config)?;

    match mode {
        Mode::Client => {
            tracing::info!("MinnowVPN WireGuard Client starting...");
            let mut client = WireGuardClient::new(config, None).await?;
            run_with_cleanup_client(&mut client).await
        }
        Mode::Server => {
            tracing::info!("MinnowVPN WireGuard Server starting...");
            let mut server = WireGuardServer::new(config).await?;
            run_with_cleanup_server(&mut server).await
        }
    }
}

/// Run in daemon mode (REST API service for Flutter UI)
async fn run_daemon(args: Args) -> Result<(), MinnowVpnError> {
    tracing::info!("MinnowVPN Daemon starting (REST API mode)...");

    let daemon = DaemonService::new();

    // Default port: 51820 for client mode
    let port = args.http_port.unwrap_or(51820);

    // Run with cleanup on Ctrl+C
    let ctrl_c = tokio::signal::ctrl_c();

    tokio::select! {
        result = daemon.run_http(port, args.token_path) => {
            result
        }
        _ = ctrl_c => {
            tracing::info!("\nReceived Ctrl+C, shutting down daemon...");
            daemon.cleanup().await?;
            Ok(())
        }
    }
}

/// Determine operating mode from args and config
fn determine_mode(args: &Args, config: &WireGuardConfig) -> Result<Mode, MinnowVpnError> {
    // Explicit flags take precedence
    if args.server {
        return Ok(Mode::Server);
    }
    if args.client {
        return Ok(Mode::Client);
    }

    // Auto-detect based on config
    let has_listen_port = config.interface.listen_port.is_some();
    let all_peers_no_endpoint = config.peers.iter().all(|p| p.endpoint.is_none());
    let any_peer_has_endpoint = config.peers.iter().any(|p| p.endpoint.is_some());

    if has_listen_port && all_peers_no_endpoint {
        // Server config: has ListenPort, peers don't have Endpoint
        tracing::info!("Auto-detected server mode (ListenPort set, no peer Endpoints)");
        Ok(Mode::Server)
    } else if any_peer_has_endpoint {
        // Client config: at least one peer has Endpoint
        tracing::info!("Auto-detected client mode (peer has Endpoint)");
        Ok(Mode::Client)
    } else {
        // Ambiguous - require explicit flag
        Err(MinnowVpnError::Config(ConfigError::ParseError {
            line: 0,
            message: "Cannot determine mode. Use --server or --client flag.".to_string(),
        }))
    }
}

/// Run the client with graceful shutdown on Ctrl+C or SIGTERM
async fn run_with_cleanup_client(client: &mut WireGuardClient) -> Result<(), MinnowVpnError> {
    let ctrl_c = tokio::signal::ctrl_c();

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler")
            .recv()
            .await
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<Option<()>>();

    tokio::select! {
        result = client.run() => {
            result
        }
        _ = ctrl_c => {
            tracing::info!("\nReceived Ctrl+C, shutting down...");
            client.cleanup().await?;
            Ok(())
        }
        _ = terminate => {
            tracing::info!("\nReceived SIGTERM, shutting down...");
            client.cleanup().await?;
            Ok(())
        }
    }
}

/// Run the server with graceful shutdown on Ctrl+C or SIGTERM
async fn run_with_cleanup_server(server: &mut WireGuardServer) -> Result<(), MinnowVpnError> {
    let ctrl_c = tokio::signal::ctrl_c();

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler")
            .recv()
            .await
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<Option<()>>();

    tokio::select! {
        result = server.run() => {
            result
        }
        _ = ctrl_c => {
            tracing::info!("\nReceived Ctrl+C, shutting down...");
            server.cleanup().await?;
            Ok(())
        }
        _ = terminate => {
            tracing::info!("\nReceived SIGTERM, shutting down...");
            server.cleanup().await?;
            Ok(())
        }
    }
}

/// Get user-friendly error message
fn user_message(error: &MinnowVpnError) -> String {
    match error {
        MinnowVpnError::Tunnel(TunnelError::InsufficientPrivileges { .. }) => {
            #[cfg(target_os = "linux")]
            return "Insufficient privileges. Run with sudo or grant CAP_NET_ADMIN:\n  \
                    sudo setcap cap_net_admin=eip ./minnowvpn\n  \
                    Or run: sudo ./minnowvpn -c config.conf".to_string();

            #[cfg(target_os = "macos")]
            return "Insufficient privileges. Run with sudo:\n  \
                    sudo ./minnowvpn -c config.conf".to_string();

            #[cfg(target_os = "windows")]
            return "Insufficient privileges. Run as Administrator.".to_string();

            #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
            return format!("{}", error);
        }

        MinnowVpnError::Config(ConfigError::FileNotFound { path }) => {
            format!("Configuration file not found: {}\n  \
                    Check the path and try again.", path)
        }

        MinnowVpnError::Config(ConfigError::InvalidKey { field }) => {
            format!("Invalid {} in configuration.\n  \
                    Expected 32-byte base64-encoded key.", field)
        }

        MinnowVpnError::Network(NetworkError::ConnectionRefused { endpoint }) => {
            format!("Connection refused by {}.\n  \
                    Check that the WireGuard server is running and accessible.", endpoint)
        }

        MinnowVpnError::Protocol(ProtocolError::HandshakeTimeout { seconds }) => {
            format!("Handshake timed out after {}s.\n  \
                    Check network connectivity and firewall rules for UDP.", seconds)
        }

        MinnowVpnError::Protocol(ProtocolError::MacVerificationFailed) => {
            "MAC verification failed.\n  \
             The peer's public key may be incorrect.".to_string()
        }

        _ => format!("{}", error),
    }
}

/// Get exit code for error
fn exit_code(error: &MinnowVpnError) -> ExitCode {
    match error {
        MinnowVpnError::Config(_) => ExitCode::from(1),
        MinnowVpnError::Tunnel(TunnelError::InsufficientPrivileges { .. }) => {
            ExitCode::from(2)
        }
        MinnowVpnError::Network(_) => ExitCode::from(3),
        MinnowVpnError::Protocol(_) => ExitCode::from(4),
        MinnowVpnError::Crypto(_) => ExitCode::from(5),
        _ => ExitCode::from(255),
    }
}
