//! Session state management for WireGuard
//!
//! Tracks active sessions and handles rekey timing.

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use crate::protocol::transport::TransportState;

/// Initiate rekey after this many seconds
pub const REKEY_AFTER_TIME: Duration = Duration::from_secs(120);

/// Reject packets from sessions older than this
pub const REJECT_AFTER_TIME: Duration = Duration::from_secs(180);

/// Rekey timeout - abandon handshake after this long
pub const REKEY_TIMEOUT: Duration = Duration::from_secs(5);

/// Keepalive timeout - send keepalive if no packet sent within this time
pub const KEEPALIVE_TIMEOUT: Duration = Duration::from_secs(10);

/// Session state for an established WireGuard connection
#[derive(Debug)]
pub struct Session {
    /// Our local session index
    pub local_index: u32,
    /// Peer's session index
    pub remote_index: u32,
    /// Transport encryption state
    pub transport: TransportState,
    /// When the session was established
    pub created_at: Instant,
    /// Last time we sent a packet
    pub last_sent: Instant,
    /// Last time we received a packet
    pub last_received: Instant,
    /// Peer's endpoint address
    pub endpoint: SocketAddr,
}

impl Session {
    /// Create a new session
    pub fn new(
        local_index: u32,
        remote_index: u32,
        sending_key: [u8; 32],
        receiving_key: [u8; 32],
        endpoint: SocketAddr,
    ) -> Self {
        let now = Instant::now();
        Self {
            local_index,
            remote_index,
            transport: TransportState::new(sending_key, receiving_key),
            created_at: now,
            last_sent: now,
            last_received: now,
            endpoint,
        }
    }

    /// Get session age
    pub fn age(&self) -> Duration {
        self.created_at.elapsed()
    }

    /// Check if this session should initiate a rekey
    pub fn needs_rekey(&self) -> bool {
        self.age() >= REKEY_AFTER_TIME || self.transport.needs_rekey_by_counter()
    }

    /// Check if this session is expired and should be rejected
    pub fn is_expired(&self) -> bool {
        self.age() >= REJECT_AFTER_TIME
    }

    /// Check if we should send a keepalive (no packet sent recently)
    pub fn needs_keepalive(&self, keepalive_interval: Duration) -> bool {
        self.last_sent.elapsed() >= keepalive_interval
    }

    /// Mark that we sent a packet
    pub fn mark_sent(&mut self) {
        self.last_sent = Instant::now();
    }

    /// Mark that we received a packet
    pub fn mark_received(&mut self) {
        self.last_received = Instant::now();
    }

    /// Time since last received packet
    pub fn time_since_last_received(&self) -> Duration {
        self.last_received.elapsed()
    }
}

/// State of a pending handshake
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeState {
    /// No handshake in progress
    None,
    /// Waiting for handshake response
    WaitingForResponse,
    /// Handshake complete, session established
    Complete,
}

/// Session manager for tracking active and pending sessions
#[derive(Debug)]
pub struct SessionManager {
    /// Current active session (if any)
    current_session: Option<Session>,
    /// Previous session (kept briefly during rekey)
    previous_session: Option<Session>,
    /// State of pending handshake
    handshake_state: HandshakeState,
    /// When the current handshake was initiated
    handshake_started: Option<Instant>,
    /// Sender index for pending handshake
    pending_sender_index: Option<u32>,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionManager {
    /// Create a new session manager
    pub fn new() -> Self {
        Self {
            current_session: None,
            previous_session: None,
            handshake_state: HandshakeState::None,
            handshake_started: None,
            pending_sender_index: None,
        }
    }

    /// Check if we have an active session
    pub fn has_session(&self) -> bool {
        self.current_session.is_some()
    }

    /// Get the current session (if valid)
    pub fn current(&self) -> Option<&Session> {
        self.current_session.as_ref().filter(|s| !s.is_expired())
    }

    /// Get mutable reference to current session
    pub fn current_mut(&mut self) -> Option<&mut Session> {
        if self.current_session.as_ref().map_or(false, |s| !s.is_expired()) {
            self.current_session.as_mut()
        } else {
            None
        }
    }

    /// Start a handshake
    pub fn start_handshake(&mut self, sender_index: u32) {
        self.handshake_state = HandshakeState::WaitingForResponse;
        self.handshake_started = Some(Instant::now());
        self.pending_sender_index = Some(sender_index);
    }

    /// Check if handshake has timed out
    pub fn handshake_timed_out(&self) -> bool {
        match (self.handshake_state, self.handshake_started) {
            (HandshakeState::WaitingForResponse, Some(started)) => {
                started.elapsed() >= REKEY_TIMEOUT
            }
            _ => false,
        }
    }

    /// Cancel pending handshake
    pub fn cancel_handshake(&mut self) {
        self.handshake_state = HandshakeState::None;
        self.handshake_started = None;
        self.pending_sender_index = None;
    }

    /// Get pending sender index
    pub fn pending_sender_index(&self) -> Option<u32> {
        self.pending_sender_index
    }

    /// Get handshake state
    pub fn handshake_state(&self) -> HandshakeState {
        self.handshake_state
    }

    /// Establish a new session from handshake result
    pub fn establish_session(&mut self, session: Session) {
        // Move current to previous (for brief overlap during rekey)
        if let Some(current) = self.current_session.take() {
            self.previous_session = Some(current);
        }

        self.current_session = Some(session);
        self.handshake_state = HandshakeState::Complete;
        self.handshake_started = None;
        self.pending_sender_index = None;

        tracing::info!("Session established");
    }

    /// Clear the previous session (after rekey transition)
    pub fn clear_previous(&mut self) {
        self.previous_session = None;
    }

    /// Find session by receiver index (for incoming packets)
    pub fn find_by_index(&mut self, index: u32) -> Option<&mut Session> {
        if let Some(ref mut session) = self.current_session {
            if session.local_index == index && !session.is_expired() {
                return Some(session);
            }
        }

        if let Some(ref mut session) = self.previous_session {
            if session.local_index == index && !session.is_expired() {
                return Some(session);
            }
        }

        None
    }

    /// Check if any session needs rekey
    pub fn needs_rekey(&self) -> bool {
        match &self.current_session {
            Some(session) => session.needs_rekey() && self.handshake_state == HandshakeState::None,
            None => false,
        }
    }

    /// Check if we should send keepalive
    pub fn needs_keepalive(&self, interval: Duration) -> bool {
        match &self.current_session {
            Some(session) => session.needs_keepalive(interval) && !session.is_expired(),
            None => false,
        }
    }

    /// Get peer endpoint
    pub fn endpoint(&self) -> Option<SocketAddr> {
        self.current_session.as_ref().map(|s| s.endpoint)
    }

    /// Update endpoint (for roaming)
    pub fn update_endpoint(&mut self, endpoint: SocketAddr) {
        if let Some(ref mut session) = self.current_session {
            session.endpoint = endpoint;
        }
    }

    /// Clear all sessions
    pub fn clear(&mut self) {
        self.current_session = None;
        self.previous_session = None;
        self.handshake_state = HandshakeState::None;
        self.handshake_started = None;
        self.pending_sender_index = None;
    }
}

/// Generate a random sender index
pub fn generate_sender_index() -> u32 {
    use rand::Rng;
    rand::thread_rng().gen()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr};

    fn test_endpoint() -> SocketAddr {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4)), 51820)
    }

    #[test]
    fn test_session_creation() {
        let session = Session::new(
            100,
            200,
            [1u8; 32],
            [2u8; 32],
            test_endpoint(),
        );

        assert_eq!(session.local_index, 100);
        assert_eq!(session.remote_index, 200);
        assert!(!session.is_expired());
        assert!(!session.needs_rekey());
    }

    #[test]
    fn test_session_manager_basic() {
        let mut manager = SessionManager::new();

        assert!(!manager.has_session());
        assert!(manager.current().is_none());

        // Establish a session
        let session = Session::new(100, 200, [1u8; 32], [2u8; 32], test_endpoint());
        manager.establish_session(session);

        assert!(manager.has_session());
        assert!(manager.current().is_some());
        assert_eq!(manager.current().unwrap().local_index, 100);
    }

    #[test]
    fn test_session_manager_rekey() {
        let mut manager = SessionManager::new();

        // Establish first session
        let session1 = Session::new(100, 200, [1u8; 32], [2u8; 32], test_endpoint());
        manager.establish_session(session1);

        // Establish second session (rekey)
        let session2 = Session::new(101, 201, [3u8; 32], [4u8; 32], test_endpoint());
        manager.establish_session(session2);

        // New session should be current
        assert_eq!(manager.current().unwrap().local_index, 101);

        // Both sessions should be findable by index
        assert!(manager.find_by_index(100).is_some()); // previous
        assert!(manager.find_by_index(101).is_some()); // current

        // Clear previous
        manager.clear_previous();
        assert!(manager.find_by_index(100).is_none());
    }

    #[test]
    fn test_handshake_state() {
        let mut manager = SessionManager::new();

        assert_eq!(manager.handshake_state(), HandshakeState::None);

        manager.start_handshake(12345);
        assert_eq!(manager.handshake_state(), HandshakeState::WaitingForResponse);
        assert_eq!(manager.pending_sender_index(), Some(12345));

        manager.cancel_handshake();
        assert_eq!(manager.handshake_state(), HandshakeState::None);
    }

    #[test]
    fn test_generate_sender_index() {
        let idx1 = generate_sender_index();
        let idx2 = generate_sender_index();

        // Should be different (with overwhelming probability)
        assert_ne!(idx1, idx2);
    }
}
