//! SecureGuard CLI - WireGuard VPN Client
//!
//! A proof-of-concept WireGuard client that connects using a standard
//! WireGuard configuration file.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use tracing_subscriber::{fmt, EnvFilter};

use secureguard_poc::error::{ConfigError, NetworkError, ProtocolError, TunnelError};
use secureguard_poc::{SecureGuardError, WireGuardClient, WireGuardConfig};

/// SecureGuard - WireGuard VPN Client
#[derive(Parser, Debug)]
#[command(name = "secureguard-poc")]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Path to WireGuard configuration file
    #[arg(short, long)]
    config: PathBuf,

    /// Enable verbose logging
    #[arg(short, long)]
    verbose: bool,
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

async fn run(args: Args) -> Result<(), SecureGuardError> {
    tracing::info!("SecureGuard WireGuard Client starting...");

    // Parse configuration
    let config_path = args.config.to_string_lossy().to_string();
    tracing::info!("Loading configuration from: {}", config_path);

    let config = WireGuardConfig::from_file(&config_path)?;

    // Create client
    let mut client = WireGuardClient::new(config).await?;

    // Run with signal handling for graceful shutdown
    run_with_cleanup(&mut client).await
}

/// Run the client with graceful shutdown on Ctrl+C
async fn run_with_cleanup(client: &mut WireGuardClient) -> Result<(), SecureGuardError> {
    let ctrl_c = tokio::signal::ctrl_c();

    tokio::select! {
        result = client.run() => {
            result
        }
        _ = ctrl_c => {
            tracing::info!("\nReceived Ctrl+C, shutting down...");
            client.cleanup().await?;
            Ok(())
        }
    }
}

/// Get user-friendly error message
fn user_message(error: &SecureGuardError) -> String {
    match error {
        SecureGuardError::Tunnel(TunnelError::InsufficientPrivileges { .. }) => {
            #[cfg(target_os = "linux")]
            return "Insufficient privileges. Run with sudo or grant CAP_NET_ADMIN:\n  \
                    sudo setcap cap_net_admin=eip ./secureguard-poc\n  \
                    Or run: sudo ./secureguard-poc -c config.conf".to_string();

            #[cfg(target_os = "macos")]
            return "Insufficient privileges. Run with sudo:\n  \
                    sudo ./secureguard-poc -c config.conf".to_string();

            #[cfg(target_os = "windows")]
            return "Insufficient privileges. Run as Administrator.".to_string();

            #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
            return format!("{}", error);
        }

        SecureGuardError::Config(ConfigError::FileNotFound { path }) => {
            format!("Configuration file not found: {}\n  \
                    Check the path and try again.", path)
        }

        SecureGuardError::Config(ConfigError::InvalidKey { field }) => {
            format!("Invalid {} in configuration.\n  \
                    Expected 32-byte base64-encoded key.", field)
        }

        SecureGuardError::Network(NetworkError::ConnectionRefused { endpoint }) => {
            format!("Connection refused by {}.\n  \
                    Check that the WireGuard server is running and accessible.", endpoint)
        }

        SecureGuardError::Protocol(ProtocolError::HandshakeTimeout { seconds }) => {
            format!("Handshake timed out after {}s.\n  \
                    Check network connectivity and firewall rules for UDP.", seconds)
        }

        SecureGuardError::Protocol(ProtocolError::MacVerificationFailed) => {
            "MAC verification failed.\n  \
             The peer's public key may be incorrect.".to_string()
        }

        _ => format!("{}", error),
    }
}

/// Get exit code for error
fn exit_code(error: &SecureGuardError) -> ExitCode {
    match error {
        SecureGuardError::Config(_) => ExitCode::from(1),
        SecureGuardError::Tunnel(TunnelError::InsufficientPrivileges { .. }) => {
            ExitCode::from(2)
        }
        SecureGuardError::Network(_) => ExitCode::from(3),
        SecureGuardError::Protocol(_) => ExitCode::from(4),
        SecureGuardError::Crypto(_) => ExitCode::from(5),
        _ => ExitCode::from(255),
    }
}
