//! WireGuard protocol implementation
//!
//! This module contains the core protocol components:
//! - Message wire formats
//! - Handshake logic (Noise IKpsk2)
//! - Cookie/DoS protection
//! - Transport encryption
//! - Session management

pub mod cookie;
pub mod handshake;
pub mod messages;
pub mod session;
pub mod transport;

pub use cookie::CookieState;
pub use handshake::{HandshakeResult, InitiatorHandshake};
pub use messages::{
    CookieReply, HandshakeInitiation, HandshakeResponse, MessageType, TransportHeader,
};
pub use session::{Session, SessionManager};
pub use transport::{ReplayWindow, TransportState};
