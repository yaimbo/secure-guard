//! SecureGuard - WireGuard Protocol Implementation
//!
//! A proof-of-concept WireGuard VPN client implementation in Rust.
//!
//! # Features
//!
//! - Full WireGuard protocol support (Noise IKpsk2)
//! - Cross-platform TUN device support (macOS, Linux, Windows)
//! - Automatic session rekey
//! - Keepalive support
//! - Cookie/DoS protection (MAC2)
//! - Connection retry with exponential backoff
//!
//! # Usage
//!
//! ```no_run
//! use secureguard_poc::{WireGuardClient, WireGuardConfig};
//!
//! #[tokio::main]
//! async fn main() -> anyhow::Result<()> {
//!     let config = WireGuardConfig::from_file("wireguard.conf")?;
//!     let mut client = WireGuardClient::new(config).await?;
//!     client.run().await?;
//!     Ok(())
//! }
//! ```

pub mod client;
pub mod config;
pub mod crypto;
pub mod error;
pub mod protocol;
pub mod tunnel;

pub use client::WireGuardClient;
pub use config::WireGuardConfig;
pub use error::SecureGuardError;
