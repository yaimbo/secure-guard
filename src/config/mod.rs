//! Configuration parsing for WireGuard
//!
//! This module handles parsing of standard WireGuard `.conf` configuration files.

mod parser;

pub use parser::{InterfaceConfig, PeerConfig, WireGuardConfig};
