//! Noise IKpsk2 protocol state machine for WireGuard
//!
//! Implements the Noise protocol pattern used by WireGuard for handshakes.
//! Pattern: Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s

use super::{aead, blake2s};
use crate::error::CryptoError;

/// Noise protocol construction string
pub const CONSTRUCTION: &[u8] = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";

/// WireGuard identifier string
pub const IDENTIFIER: &[u8] = b"WireGuard v1 zx2c4 Jason@zx2c4.com";

/// Label for MAC1 key derivation
pub const LABEL_MAC1: &[u8] = b"mac1----";

/// Label for cookie key derivation
pub const LABEL_COOKIE: &[u8] = b"cookie--";

/// Hash length (also chaining key length)
pub const HASH_LEN: usize = 32;

/// Noise protocol handshake state
#[derive(Clone)]
pub struct HandshakeState {
    /// Chaining key for key derivation
    pub chaining_key: [u8; HASH_LEN],
    /// Hash accumulator
    pub hash: [u8; HASH_LEN],
}

impl HandshakeState {
    /// Initialize the chaining key from the construction string
    pub fn initial_chain_key() -> [u8; HASH_LEN] {
        blake2s::hash(CONSTRUCTION)
    }

    /// Initialize the hash chain with the responder's static public key
    ///
    /// h = HASH(HASH(CONSTRUCTION) || IDENTIFIER)
    /// h = HASH(h || responder_static_public)
    pub fn initial_hash(responder_static: &[u8; 32]) -> [u8; HASH_LEN] {
        let ck = Self::initial_chain_key();
        let h1 = blake2s::hash_two(&ck, IDENTIFIER);
        blake2s::hash_two(&h1, responder_static)
    }

    /// Create a new handshake state for the initiator
    pub fn new_initiator(responder_static: &[u8; 32]) -> Self {
        Self {
            chaining_key: Self::initial_chain_key(),
            hash: Self::initial_hash(responder_static),
        }
    }

    /// Create a new handshake state for the responder
    ///
    /// The responder uses its own public key for the initial hash,
    /// since in the Noise IK pattern, both parties use the responder's
    /// static public key as the initial hash input.
    pub fn new_responder(our_static_public: &[u8; 32]) -> Self {
        Self {
            chaining_key: Self::initial_chain_key(),
            hash: Self::initial_hash(our_static_public),
        }
    }

    /// MixHash: h = HASH(h || data)
    pub fn mix_hash(&mut self, data: &[u8]) {
        self.hash = blake2s::hash_two(&self.hash, data);
    }

    /// MixKey: (ck, k) = KDF2(ck, input_key_material)
    ///
    /// Updates chaining_key and returns the derived key
    pub fn mix_key(&mut self, input: &[u8]) -> [u8; 32] {
        let (new_ck, key) = blake2s::kdf2(&self.chaining_key, input);
        self.chaining_key = new_ck;
        key
    }

    /// MixKeyAndHash: (ck, temp_h, k) = KDF3(ck, input_key_material)
    ///
    /// Used for PSK mixing. Updates chaining_key, mixes temp_h into hash,
    /// and returns the derived key.
    pub fn mix_key_and_hash(&mut self, psk: &[u8; 32]) -> [u8; 32] {
        let (new_ck, temp_h, key) = blake2s::kdf3(&self.chaining_key, psk);
        self.chaining_key = new_ck;
        self.mix_hash(&temp_h);
        key
    }

    /// EncryptAndHash: encrypts plaintext with key, mixes ciphertext into hash
    ///
    /// c = AEAD-Encrypt(k, nonce=0, plaintext, h)
    /// h = HASH(h || c)
    pub fn encrypt_and_hash(
        &mut self,
        key: &[u8; 32],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let ciphertext = aead::encrypt(key, 0, plaintext, &self.hash)?;
        self.mix_hash(&ciphertext);
        Ok(ciphertext)
    }

    /// DecryptAndHash: decrypts ciphertext with key, mixes ciphertext into hash
    ///
    /// p = AEAD-Decrypt(k, nonce=0, ciphertext, h)
    /// h = HASH(h || ciphertext)
    pub fn decrypt_and_hash(
        &mut self,
        key: &[u8; 32],
        ciphertext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let plaintext = aead::decrypt(key, 0, ciphertext, &self.hash)?;
        self.mix_hash(ciphertext);
        Ok(plaintext)
    }
}

/// Transport keys derived from a completed handshake
pub struct TransportKeys {
    /// Key for sending packets (initiator -> responder)
    pub sending_key: [u8; 32],
    /// Key for receiving packets (responder -> initiator)
    pub receiving_key: [u8; 32],
}

impl TransportKeys {
    /// Derive transport keys from the final chaining key
    ///
    /// For initiator: (sending_key, receiving_key) = KDF2(ck, "")
    /// For responder: keys are swapped
    pub fn derive_initiator(chaining_key: &[u8; 32]) -> Self {
        let (t_send, t_recv) = blake2s::kdf2(chaining_key, &[]);
        Self {
            sending_key: t_send,
            receiving_key: t_recv,
        }
    }

    /// Derive transport keys for responder (keys are swapped)
    pub fn derive_responder(chaining_key: &[u8; 32]) -> Self {
        let (t_recv, t_send) = blake2s::kdf2(chaining_key, &[]);
        Self {
            sending_key: t_send,
            receiving_key: t_recv,
        }
    }
}

/// Compute the MAC1 key from a peer's public key
///
/// mac1_key = HASH(LABEL_MAC1 || peer_public_key)
pub fn mac1_key(peer_public: &[u8; 32]) -> [u8; 32] {
    blake2s::hash_two(LABEL_MAC1, peer_public)
}

/// Compute MAC1 over a message
///
/// mac1 = MAC(mac1_key, message)
pub fn compute_mac1(peer_public: &[u8; 32], message: &[u8]) -> [u8; 16] {
    let key = mac1_key(peer_public);
    blake2s::mac(&key, message)
}

/// Compute the cookie encryption key from a peer's public key
///
/// cookie_key = HASH(LABEL_COOKIE || peer_public_key)
pub fn cookie_key(peer_public: &[u8; 32]) -> [u8; 32] {
    blake2s::hash_two(LABEL_COOKIE, peer_public)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_initial_chain_key() {
        let ck = HandshakeState::initial_chain_key();
        // Should be deterministic
        assert_eq!(ck, HandshakeState::initial_chain_key());
        // Should not be all zeros
        assert!(!ck.iter().all(|&b| b == 0));
    }

    #[test]
    fn test_initial_hash() {
        let peer_public = [0u8; 32];
        let h = HandshakeState::initial_hash(&peer_public);
        // Should be deterministic
        assert_eq!(h, HandshakeState::initial_hash(&peer_public));

        // Different peer public keys should produce different hashes
        let other_public = [1u8; 32];
        assert_ne!(h, HandshakeState::initial_hash(&other_public));
    }

    #[test]
    fn test_mix_hash() {
        let peer_public = [0u8; 32];
        let mut state = HandshakeState::new_initiator(&peer_public);
        let original_hash = state.hash;

        state.mix_hash(b"test data");
        assert_ne!(state.hash, original_hash);
    }

    #[test]
    fn test_mix_key() {
        let peer_public = [0u8; 32];
        let mut state = HandshakeState::new_initiator(&peer_public);
        let original_ck = state.chaining_key;

        let key = state.mix_key(b"input key material");
        assert_ne!(state.chaining_key, original_ck);
        assert_ne!(key, [0u8; 32]);
    }

    #[test]
    fn test_encrypt_decrypt_and_hash() {
        let peer_public = [0u8; 32];
        let mut state1 = HandshakeState::new_initiator(&peer_public);
        let mut state2 = state1.clone();

        let key = [42u8; 32];
        let plaintext = b"secret message";

        let ciphertext = state1.encrypt_and_hash(&key, plaintext).unwrap();
        let decrypted = state2.decrypt_and_hash(&key, &ciphertext).unwrap();

        assert_eq!(decrypted, plaintext);
        // Both states should have the same hash after the operation
        assert_eq!(state1.hash, state2.hash);
    }

    #[test]
    fn test_transport_keys() {
        let ck = [0u8; 32];

        let initiator_keys = TransportKeys::derive_initiator(&ck);
        let responder_keys = TransportKeys::derive_responder(&ck);

        // Initiator's sending key should be responder's receiving key
        assert_eq!(initiator_keys.sending_key, responder_keys.receiving_key);
        // Initiator's receiving key should be responder's sending key
        assert_eq!(initiator_keys.receiving_key, responder_keys.sending_key);
    }

    #[test]
    fn test_mac1_computation() {
        let peer_public = [0u8; 32];
        let message = b"test message";

        let mac = compute_mac1(&peer_public, message);
        assert_eq!(mac.len(), 16);

        // Should be deterministic
        assert_eq!(mac, compute_mac1(&peer_public, message));

        // Different messages should produce different MACs
        let other_mac = compute_mac1(&peer_public, b"other message");
        assert_ne!(mac, other_mac);
    }

    #[test]
    fn test_responder_initiator_same_initial_state() {
        let responder_public = [42u8; 32];

        // Both initiator and responder should start with the same hash
        // when given the same responder public key
        let initiator_state = HandshakeState::new_initiator(&responder_public);
        let responder_state = HandshakeState::new_responder(&responder_public);

        assert_eq!(initiator_state.chaining_key, responder_state.chaining_key);
        assert_eq!(initiator_state.hash, responder_state.hash);
    }
}
