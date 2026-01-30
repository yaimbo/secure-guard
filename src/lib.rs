//! SecureGuard - WireGuard Protocol Implementation
//!
//! A proof-of-concept WireGuard VPN client/server implementation in Rust.
//!
//! # Features
//!
//! - Full WireGuard protocol support (Noise IKpsk2)
//! - Both client (initiator) and server (responder) modes
//! - Cross-platform TUN device support (macOS, Linux, Windows)
//! - Multi-peer support in server mode
//! - Automatic session rekey
//! - Keepalive support
//! - Cookie/DoS protection (MAC2)
//! - Connection retry with exponential backoff
//!
//! # Usage (Client)
//!
//! ```no_run
//! use secureguard_poc::{WireGuardClient, WireGuardConfig};
//!
//! #[tokio::main]
//! async fn main() -> anyhow::Result<()> {
//!     let config = WireGuardConfig::from_file("client.conf")?;
//!     let mut client = WireGuardClient::new(config, None).await?;
//!     client.run().await?;
//!     Ok(())
//! }
//! ```
//!
//! # Usage (Server)
//!
//! ```no_run
//! use secureguard_poc::{WireGuardServer, WireGuardConfig};
//!
//! #[tokio::main]
//! async fn main() -> anyhow::Result<()> {
//!     let config = WireGuardConfig::from_file("server.conf")?;
//!     let mut server = WireGuardServer::new(config).await?;
//!     server.run().await?;
//!     Ok(())
//! }
//! ```

pub mod client;
pub mod config;
pub mod crypto;
pub mod daemon;
pub mod error;
pub mod protocol;
pub mod server;
pub mod tunnel;

pub use client::WireGuardClient;
pub use config::WireGuardConfig;
pub use daemon::DaemonService;
pub use error::SecureGuardError;
pub use server::WireGuardServer;
