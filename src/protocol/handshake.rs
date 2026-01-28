//! WireGuard handshake implementation
//!
//! Implements the Noise IKpsk2 handshake pattern for key exchange.

use tai64::Tai64N;

use crate::crypto::{blake2s, noise, x25519};
use crate::error::{CryptoError, ProtocolError, SecureGuardError};
use crate::protocol::messages::{HandshakeInitiation, HandshakeResponse};

/// State for an in-progress handshake (initiator side)
pub struct InitiatorHandshake {
    /// Our static private key
    pub static_private: [u8; 32],
    /// Our static public key
    pub static_public: [u8; 32],
    /// Peer's static public key
    pub peer_static: [u8; 32],
    /// Pre-shared key (or zeros if not used)
    pub psk: [u8; 32],
    /// Our sender index
    pub sender_index: u32,
    /// Ephemeral private key (kept for processing response)
    pub ephemeral_private: [u8; 32],
    /// Noise handshake state
    pub noise_state: noise::HandshakeState,
    /// Last MAC1 we sent (needed for cookie processing)
    pub last_mac1: [u8; 16],
}

impl InitiatorHandshake {
    /// Create a new initiator handshake
    pub fn new(
        static_private: [u8; 32],
        peer_static: [u8; 32],
        psk: Option<[u8; 32]>,
        sender_index: u32,
    ) -> Self {
        let static_public = x25519::public_key(&static_private);
        Self {
            static_private,
            static_public,
            peer_static,
            psk: psk.unwrap_or([0u8; 32]),
            sender_index,
            ephemeral_private: [0u8; 32],
            noise_state: noise::HandshakeState::new_initiator(&peer_static),
            last_mac1: [0u8; 16],
        }
    }

    /// Create the handshake initiation message
    ///
    /// Returns the message and updates internal state for response processing.
    pub fn create_initiation(
        &mut self,
        cookie: Option<&[u8; 16]>,
    ) -> Result<HandshakeInitiation, SecureGuardError> {
        // Generate ephemeral keypair
        let (ephemeral_private, ephemeral_public) = x25519::generate_keypair();
        self.ephemeral_private = ephemeral_private;

        // e: Mix ephemeral into hash, then update chaining key
        self.noise_state.mix_hash(&ephemeral_public);
        self.noise_state.chaining_key = blake2s::kdf1(&self.noise_state.chaining_key, &ephemeral_public);

        // es: DH between our ephemeral and peer's static
        let shared_es = x25519::dh(&ephemeral_private, &self.peer_static);
        let key = self.noise_state.mix_key(&shared_es);

        // s: Encrypt our static public key
        let encrypted_static = self.noise_state.encrypt_and_hash(&key, &self.static_public)?;
        let encrypted_static: [u8; 48] = encrypted_static
            .try_into()
            .map_err(|_| CryptoError::Encryption)?;

        // ss: DH between our static and peer's static
        let shared_ss = x25519::dh(&self.static_private, &self.peer_static);
        let key = self.noise_state.mix_key(&shared_ss);

        // Encrypt timestamp (TAI64N)
        let timestamp = Tai64N::now();
        let encrypted_timestamp = self.noise_state.encrypt_and_hash(&key, &timestamp.to_bytes())?;
        let encrypted_timestamp: [u8; 28] = encrypted_timestamp
            .try_into()
            .map_err(|_| CryptoError::Encryption)?;

        // Build message
        let mut msg = HandshakeInitiation::new(
            self.sender_index,
            ephemeral_public,
            encrypted_static,
            encrypted_timestamp,
        );

        // Compute MAC1
        let mac1_key = noise::mac1_key(&self.peer_static);
        msg.mac1 = blake2s::mac(&mac1_key, &msg.bytes_for_mac1());
        self.last_mac1 = msg.mac1;

        // Compute MAC2 (using cookie if available, otherwise zeros)
        if let Some(cookie) = cookie {
            msg.mac2 = blake2s::mac_with_cookie(cookie, &msg.bytes_for_mac2());
        }

        Ok(msg)
    }

    /// Process the handshake response and derive transport keys
    pub fn process_response(
        &mut self,
        response: &HandshakeResponse,
    ) -> Result<HandshakeResult, SecureGuardError> {
        // Verify receiver_index matches our sender_index
        if response.receiver_index != self.sender_index {
            return Err(ProtocolError::InvalidSenderIndex {
                index: response.receiver_index,
            }
            .into());
        }

        // e: First mix responder's ephemeral into hash (matching boringtun order)
        // Hr := HASH(Hr || ephemeral)
        self.noise_state.mix_hash(&response.ephemeral_public);

        // Then update chaining key
        // Cr := KDF1(Cr, Epub_r)
        self.noise_state.chaining_key = blake2s::kdf1(&self.noise_state.chaining_key, &response.ephemeral_public);

        // ee: DH between ephemeral keys
        let shared_ee = x25519::dh(&self.ephemeral_private, &response.ephemeral_public);
        self.noise_state.mix_key(&shared_ee);

        // se: DH between our static and responder's ephemeral
        let shared_se = x25519::dh(&self.static_private, &response.ephemeral_public);
        let _key = self.noise_state.mix_key(&shared_se);

        // psk: Mix pre-shared key
        let key = self.noise_state.mix_key_and_hash(&self.psk);

        // Decrypt empty payload (verify authentication tag)
        self.noise_state
            .decrypt_and_hash(&key, &response.encrypted_nothing)?;

        // Derive transport keys
        let keys = noise::TransportKeys::derive_initiator(&self.noise_state.chaining_key);

        Ok(HandshakeResult {
            local_index: self.sender_index,
            remote_index: response.sender_index,
            sending_key: keys.sending_key,
            receiving_key: keys.receiving_key,
        })
    }
}

/// Result of a successful handshake
#[derive(Debug, Clone)]
pub struct HandshakeResult {
    /// Our local session index
    pub local_index: u32,
    /// Peer's session index
    pub remote_index: u32,
    /// Key for encrypting outgoing packets
    pub sending_key: [u8; 32],
    /// Key for decrypting incoming packets
    pub receiving_key: [u8; 32],
}

/// Verify MAC1 on a handshake response
///
/// We are the initiator, so MAC1 is computed with OUR public key
pub fn verify_response_mac1(
    response_bytes: &[u8],
    our_public_key: &[u8; 32],
) -> Result<(), SecureGuardError> {
    if response_bytes.len() < HandshakeResponse::SIZE {
        return Err(ProtocolError::InvalidMessageLength {
            expected: HandshakeResponse::SIZE,
            got: response_bytes.len(),
        }
        .into());
    }

    let mac1_key = noise::mac1_key(our_public_key);
    let mac1_data = HandshakeResponse::bytes_for_mac1(response_bytes);
    let expected_mac1 = blake2s::mac(&mac1_key, mac1_data);

    let actual_mac1 = &response_bytes[60..76];
    if actual_mac1 != expected_mac1 {
        return Err(ProtocolError::MacVerificationFailed.into());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_initiation() {
        let (static_private, _) = x25519::generate_keypair();
        let (_, peer_public) = x25519::generate_keypair();

        let mut handshake = InitiatorHandshake::new(static_private, peer_public, None, 12345);

        let init = handshake.create_initiation(None).unwrap();

        assert_eq!(init.sender_index, 12345);
        assert!(!init.ephemeral_public.iter().all(|&b| b == 0));
        assert!(!init.encrypted_static.iter().all(|&b| b == 0));
        assert!(!init.mac1.iter().all(|&b| b == 0));
        assert!(init.mac2.iter().all(|&b| b == 0)); // No cookie, so zeros
    }

    #[test]
    fn test_initiation_with_cookie() {
        let (static_private, _) = x25519::generate_keypair();
        let (_, peer_public) = x25519::generate_keypair();

        let mut handshake = InitiatorHandshake::new(static_private, peer_public, None, 12345);

        let cookie = [42u8; 16];
        let init = handshake.create_initiation(Some(&cookie)).unwrap();

        // MAC2 should not be all zeros when cookie is provided
        assert!(!init.mac2.iter().all(|&b| b == 0));
    }

    #[test]
    fn test_initiation_serialization() {
        let (static_private, _) = x25519::generate_keypair();
        let (_, peer_public) = x25519::generate_keypair();

        let mut handshake = InitiatorHandshake::new(static_private, peer_public, None, 12345);
        let init = handshake.create_initiation(None).unwrap();

        let bytes = init.to_bytes();
        assert_eq!(bytes.len(), HandshakeInitiation::SIZE);
        assert_eq!(bytes[0], 1); // Message type

        let parsed = HandshakeInitiation::from_bytes(&bytes).unwrap();
        assert_eq!(parsed.sender_index, init.sender_index);
        assert_eq!(parsed.ephemeral_public, init.ephemeral_public);
    }
}
