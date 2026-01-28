//! Cookie handling for WireGuard DoS protection
//!
//! When a server is under load, it responds with a Cookie Reply message
//! instead of processing the handshake. The client must include the
//! decrypted cookie in MAC2 of subsequent handshake attempts.

use std::time::Instant;

use crate::crypto::{aead, noise};
use crate::error::{CryptoError, SecureGuardError};
use crate::protocol::messages::CookieReply;

/// Cookie validity duration (120 seconds per WireGuard spec)
const COOKIE_VALIDITY_SECS: u64 = 120;

/// State for tracking received cookies
#[derive(Debug, Clone)]
pub struct CookieState {
    /// Decrypted cookie value (16 bytes)
    cookie: Option<[u8; 16]>,
    /// When the cookie was received
    received_at: Option<Instant>,
}

impl Default for CookieState {
    fn default() -> Self {
        Self::new()
    }
}

impl CookieState {
    /// Create a new empty cookie state
    pub fn new() -> Self {
        Self {
            cookie: None,
            received_at: None,
        }
    }

    /// Check if we have a valid (non-expired) cookie
    pub fn has_valid_cookie(&self) -> bool {
        match (self.cookie, self.received_at) {
            (Some(_), Some(received)) => {
                received.elapsed().as_secs() < COOKIE_VALIDITY_SECS
            }
            _ => false,
        }
    }

    /// Get the current cookie if valid
    pub fn get_cookie(&self) -> Option<&[u8; 16]> {
        if self.has_valid_cookie() {
            self.cookie.as_ref()
        } else {
            None
        }
    }

    /// Process a Cookie Reply message and store the decrypted cookie
    ///
    /// # Arguments
    /// * `reply` - The Cookie Reply message
    /// * `our_last_mac1` - The MAC1 from our last handshake initiation
    /// * `peer_public` - The peer's static public key
    pub fn process_cookie_reply(
        &mut self,
        reply: &CookieReply,
        our_last_mac1: &[u8; 16],
        peer_public: &[u8; 32],
    ) -> Result<(), SecureGuardError> {
        // Derive the cookie decryption key
        // cookie_key = HASH(LABEL_COOKIE || peer_public)
        let key = noise::cookie_key(peer_public);

        // Decrypt the cookie
        // cookie = XAEAD-Decrypt(key, nonce, encrypted_cookie, mac1)
        let decrypted = aead::xdecrypt(&key, &reply.nonce, &reply.encrypted_cookie, our_last_mac1)
            .map_err(|_| CryptoError::Decryption)?;

        if decrypted.len() != 16 {
            return Err(CryptoError::Decryption.into());
        }

        let mut cookie = [0u8; 16];
        cookie.copy_from_slice(&decrypted);

        self.cookie = Some(cookie);
        self.received_at = Some(Instant::now());

        tracing::debug!("Stored new cookie (valid for {}s)", COOKIE_VALIDITY_SECS);

        Ok(())
    }

    /// Clear the stored cookie
    pub fn clear(&mut self) {
        self.cookie = None;
        self.received_at = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cookie_state_empty() {
        let state = CookieState::new();
        assert!(!state.has_valid_cookie());
        assert!(state.get_cookie().is_none());
    }

    #[test]
    fn test_cookie_validity() {
        let mut state = CookieState::new();

        // Manually set a cookie for testing
        state.cookie = Some([42u8; 16]);
        state.received_at = Some(Instant::now());

        assert!(state.has_valid_cookie());
        assert_eq!(state.get_cookie(), Some(&[42u8; 16]));
    }

    #[test]
    fn test_cookie_clear() {
        let mut state = CookieState::new();
        state.cookie = Some([42u8; 16]);
        state.received_at = Some(Instant::now());

        state.clear();

        assert!(!state.has_valid_cookie());
        assert!(state.get_cookie().is_none());
    }
}
