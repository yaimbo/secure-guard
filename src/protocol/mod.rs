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
pub use handshake::{
    verify_initiation_mac1, HandshakeResult, InitiatorHandshake, ResponderHandshake,
};
pub use messages::{
    CookieReply, HandshakeInitiation, HandshakeResponse, MessageType, TransportHeader,
};
pub use session::{PeerManager, PeerState, Session, SessionManager};
pub use transport::{ReplayWindow, TransportState};
