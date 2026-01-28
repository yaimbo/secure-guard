//! Transport layer encryption for WireGuard
//!
//! Handles encryption and decryption of IP packets using ChaCha20-Poly1305.

use crate::crypto::aead;
use crate::error::{CryptoError, ProtocolError, SecureGuardError};
use crate::protocol::messages::TransportHeader;

/// Maximum counter value before requiring rekey
/// WireGuard spec: REJECT_AFTER_MESSAGES = 2^64 - 2^13 - 1
pub const REJECT_AFTER_MESSAGES: u64 = u64::MAX - 8192;

/// Encrypt an IP packet for transport
///
/// # Arguments
/// * `key` - 32-byte sending key
/// * `counter` - Packet counter (incremented for each packet)
/// * `receiver_index` - Peer's session index
/// * `plaintext` - IP packet to encrypt
///
/// # Returns
/// Complete transport message ready to send
pub fn encrypt_packet(
    key: &[u8; 32],
    counter: u64,
    receiver_index: u32,
    plaintext: &[u8],
) -> Result<Vec<u8>, SecureGuardError> {
    if counter >= REJECT_AFTER_MESSAGES {
        return Err(ProtocolError::SessionExpired.into());
    }

    // Encrypt with ChaCha20-Poly1305
    // No additional authenticated data (AAD) for transport packets
    let ciphertext = aead::encrypt(key, counter, plaintext, &[])?;

    // Build complete transport message
    Ok(TransportHeader::build_message(
        receiver_index,
        counter,
        &ciphertext,
    ))
}

/// Decrypt a transport packet
///
/// # Arguments
/// * `key` - 32-byte receiving key
/// * `packet` - Complete transport message (header + encrypted payload)
///
/// # Returns
/// Tuple of (counter, decrypted IP packet)
pub fn decrypt_packet(
    key: &[u8; 32],
    packet: &[u8],
) -> Result<(u64, Vec<u8>), SecureGuardError> {
    if packet.len() < TransportHeader::MIN_SIZE {
        return Err(ProtocolError::InvalidMessageLength {
            expected: TransportHeader::MIN_SIZE,
            got: packet.len(),
        }
        .into());
    }

    let header = TransportHeader::from_bytes(packet)?;
    let ciphertext = TransportHeader::payload(packet);

    if ciphertext.len() < 16 {
        return Err(CryptoError::Decryption.into());
    }

    // Decrypt with ChaCha20-Poly1305
    let plaintext = aead::decrypt(key, header.counter, ciphertext, &[])?;

    Ok((header.counter, plaintext))
}

/// Anti-replay window for tracking received packet counters
///
/// Uses a sliding window bitmap to efficiently track which counters
/// have been seen, preventing replay attacks.
#[derive(Debug, Clone)]
pub struct ReplayWindow {
    /// Highest counter value seen
    highest: u64,
    /// Bitmap for tracking recent counters
    /// Bit N represents (highest - N) for N in 0..WINDOW_SIZE
    bitmap: u128,
}

/// Size of the anti-replay window in packets
const WINDOW_SIZE: u64 = 128;

impl Default for ReplayWindow {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplayWindow {
    /// Create a new replay window
    pub fn new() -> Self {
        Self {
            highest: 0,
            bitmap: 0,
        }
    }

    /// Check if a counter is valid (not a replay) and update window
    ///
    /// Returns true if the counter is valid (first time seen and within window)
    pub fn check_and_update(&mut self, counter: u64) -> bool {
        // Counter 0 is special - always accept the first packet
        if self.highest == 0 && self.bitmap == 0 {
            self.highest = counter;
            self.bitmap = 1;
            return true;
        }

        if counter > self.highest {
            // New highest - shift window
            let shift = counter - self.highest;
            if shift >= WINDOW_SIZE {
                // Counter is way ahead, reset window
                self.bitmap = 1;
            } else {
                // Shift bitmap and mark new counter
                self.bitmap = (self.bitmap << shift) | 1;
            }
            self.highest = counter;
            true
        } else {
            // Counter is at or behind highest
            let diff = self.highest - counter;

            if diff >= WINDOW_SIZE {
                // Too old, outside window
                false
            } else {
                // Check if already seen
                let bit = 1u128 << diff;
                if self.bitmap & bit != 0 {
                    // Already seen - replay!
                    false
                } else {
                    // Mark as seen
                    self.bitmap |= bit;
                    true
                }
            }
        }
    }

    /// Check if a counter would be valid without updating the window
    pub fn would_accept(&self, counter: u64) -> bool {
        if self.highest == 0 && self.bitmap == 0 {
            return true;
        }

        if counter > self.highest {
            true
        } else {
            let diff = self.highest - counter;
            if diff >= WINDOW_SIZE {
                false
            } else {
                let bit = 1u128 << diff;
                self.bitmap & bit == 0
            }
        }
    }
}

/// Transport state for a session
#[derive(Debug, Clone)]
pub struct TransportState {
    /// Key for encrypting outgoing packets
    pub sending_key: [u8; 32],
    /// Key for decrypting incoming packets
    pub receiving_key: [u8; 32],
    /// Counter for outgoing packets
    pub sending_counter: u64,
    /// Anti-replay window for incoming packets
    pub replay_window: ReplayWindow,
}

impl TransportState {
    /// Create a new transport state from handshake result
    pub fn new(sending_key: [u8; 32], receiving_key: [u8; 32]) -> Self {
        Self {
            sending_key,
            receiving_key,
            sending_counter: 0,
            replay_window: ReplayWindow::new(),
        }
    }

    /// Encrypt a packet and increment counter
    pub fn encrypt(&mut self, receiver_index: u32, plaintext: &[u8]) -> Result<Vec<u8>, SecureGuardError> {
        let counter = self.sending_counter;
        self.sending_counter += 1;
        encrypt_packet(&self.sending_key, counter, receiver_index, plaintext)
    }

    /// Decrypt a packet and check for replay
    pub fn decrypt(&mut self, packet: &[u8]) -> Result<Vec<u8>, SecureGuardError> {
        let (counter, plaintext) = decrypt_packet(&self.receiving_key, packet)?;

        if !self.replay_window.check_and_update(counter) {
            return Err(ProtocolError::ReplayDetected { counter }.into());
        }

        Ok(plaintext)
    }

    /// Check if this transport state needs rekeying based on counter
    pub fn needs_rekey_by_counter(&self) -> bool {
        // Rekey well before hitting the limit
        self.sending_counter >= REJECT_AFTER_MESSAGES - 1000
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = [42u8; 32];
        let plaintext = b"Hello, WireGuard!";

        let encrypted = encrypt_packet(&key, 0, 12345, plaintext).unwrap();

        // Verify header
        assert_eq!(encrypted[0], 4); // Message type
        let receiver_index = u32::from_le_bytes(encrypted[4..8].try_into().unwrap());
        assert_eq!(receiver_index, 12345);

        // Decrypt
        let (counter, decrypted) = decrypt_packet(&key, &encrypted).unwrap();
        assert_eq!(counter, 0);
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_counter_increments() {
        let key = [42u8; 32];

        let msg1 = encrypt_packet(&key, 0, 1, b"first").unwrap();
        let msg2 = encrypt_packet(&key, 1, 1, b"second").unwrap();
        let msg3 = encrypt_packet(&key, 2, 1, b"third").unwrap();

        let (c1, _) = decrypt_packet(&key, &msg1).unwrap();
        let (c2, _) = decrypt_packet(&key, &msg2).unwrap();
        let (c3, _) = decrypt_packet(&key, &msg3).unwrap();

        assert_eq!(c1, 0);
        assert_eq!(c2, 1);
        assert_eq!(c3, 2);
    }

    #[test]
    fn test_replay_window_basic() {
        let mut window = ReplayWindow::new();

        // First packet should always be accepted
        assert!(window.check_and_update(0));

        // Same counter should be rejected (replay)
        assert!(!window.check_and_update(0));

        // Higher counter should be accepted
        assert!(window.check_and_update(1));
        assert!(window.check_and_update(5));
        assert!(window.check_and_update(10));

        // Previous counters in window should still be rejected
        assert!(!window.check_and_update(5));
        assert!(!window.check_and_update(10));
    }

    #[test]
    fn test_replay_window_out_of_order() {
        let mut window = ReplayWindow::new();

        // Accept packets out of order
        assert!(window.check_and_update(5));
        assert!(window.check_and_update(3));
        assert!(window.check_and_update(7));
        assert!(window.check_and_update(4));

        // All should now be rejected
        assert!(!window.check_and_update(3));
        assert!(!window.check_and_update(4));
        assert!(!window.check_and_update(5));
        assert!(!window.check_and_update(7));

        // 6 was never seen, should be accepted
        assert!(window.check_and_update(6));
    }

    #[test]
    fn test_replay_window_outside_window() {
        let mut window = ReplayWindow::new();

        // Start at counter 200
        assert!(window.check_and_update(200));

        // Counter way in the past should be rejected
        assert!(!window.check_and_update(0));
        assert!(!window.check_and_update(50));

        // Counter just inside window should be accepted
        assert!(window.check_and_update(200 - WINDOW_SIZE + 1));
    }

    #[test]
    fn test_transport_state() {
        let mut state = TransportState::new([1u8; 32], [2u8; 32]);

        // Encrypt some packets
        let msg1 = state.encrypt(100, b"packet 1").unwrap();
        let msg2 = state.encrypt(100, b"packet 2").unwrap();

        assert_eq!(state.sending_counter, 2);

        // Create receiving state with swapped keys
        let mut recv_state = TransportState::new([2u8; 32], [1u8; 32]);

        // Decrypt in order
        let plain1 = recv_state.decrypt(&msg1).unwrap();
        let plain2 = recv_state.decrypt(&msg2).unwrap();

        assert_eq!(plain1, b"packet 1");
        assert_eq!(plain2, b"packet 2");

        // Replay should be rejected
        assert!(recv_state.decrypt(&msg1).is_err());
    }
}
