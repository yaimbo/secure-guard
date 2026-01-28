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

/// State for processing a handshake (responder side)
pub struct ResponderHandshake {
    /// Our static private key (server's key)
    pub static_private: [u8; 32],
    /// Our static public key (server's key)
    pub static_public: [u8; 32],
    /// Our sender index (newly generated for this handshake)
    pub sender_index: u32,
    /// Noise handshake state
    pub noise_state: noise::HandshakeState,
    /// Initiator's ephemeral public key (from initiation)
    pub initiator_ephemeral: [u8; 32],
    /// Initiator's static public key (decrypted from initiation)
    pub initiator_static: [u8; 32],
    /// Initiator's sender index (becomes our receiver_index)
    pub initiator_index: u32,
    /// Last MAC1 we sent (needed for cookie processing)
    pub last_mac1: [u8; 16],
}

impl ResponderHandshake {
    /// Create a new responder handshake state
    pub fn new(static_private: [u8; 32], sender_index: u32) -> Self {
        let static_public = x25519::public_key(&static_private);
        Self {
            static_private,
            static_public,
            sender_index,
            noise_state: noise::HandshakeState::new_responder(&static_public),
            initiator_ephemeral: [0u8; 32],
            initiator_static: [0u8; 32],
            initiator_index: 0,
            last_mac1: [0u8; 16],
        }
    }

    /// Process an incoming handshake initiation (Type 1)
    ///
    /// This decrypts and validates the initiation, extracting the peer's
    /// static public key which can be used to look up the peer.
    ///
    /// Returns the initiator's static public key on success.
    pub fn process_initiation(
        &mut self,
        initiation: &HandshakeInitiation,
    ) -> Result<[u8; 32], SecureGuardError> {
        // Store initiator's values
        self.initiator_ephemeral = initiation.ephemeral_public;
        self.initiator_index = initiation.sender_index;

        // e: Mix initiator's ephemeral into hash, then update chaining key
        // This mirrors what the initiator did
        self.noise_state.mix_hash(&initiation.ephemeral_public);
        self.noise_state.chaining_key =
            blake2s::kdf1(&self.noise_state.chaining_key, &initiation.ephemeral_public);

        // es: DH between our static and initiator's ephemeral
        // (Initiator did: DH(ephemeral_private, our_static_public))
        let shared_es = x25519::dh(&self.static_private, &initiation.ephemeral_public);
        let key = self.noise_state.mix_key(&shared_es);

        // s: Decrypt initiator's static public key
        let static_bytes = self
            .noise_state
            .decrypt_and_hash(&key, &initiation.encrypted_static)?;
        self.initiator_static = static_bytes
            .try_into()
            .map_err(|_| CryptoError::Decryption)?;

        // ss: DH between our static and initiator's static
        let shared_ss = x25519::dh(&self.static_private, &self.initiator_static);
        let key = self.noise_state.mix_key(&shared_ss);

        // Decrypt timestamp (we don't validate it here, caller should)
        let _timestamp = self
            .noise_state
            .decrypt_and_hash(&key, &initiation.encrypted_timestamp)?;

        Ok(self.initiator_static)
    }

    /// Create the handshake response (Type 2)
    ///
    /// This generates the response message and derives the transport keys.
    /// The PSK is looked up by the caller based on the peer's public key.
    pub fn create_response(
        &mut self,
        psk: Option<[u8; 32]>,
        cookie: Option<&[u8; 16]>,
    ) -> Result<(HandshakeResponse, HandshakeResult), SecureGuardError> {
        let psk = psk.unwrap_or([0u8; 32]);

        // Generate ephemeral keypair
        let (ephemeral_private, ephemeral_public) = x25519::generate_keypair();

        // e: Mix our ephemeral into hash, then update chaining key
        self.noise_state.mix_hash(&ephemeral_public);
        self.noise_state.chaining_key =
            blake2s::kdf1(&self.noise_state.chaining_key, &ephemeral_public);

        // ee: DH between ephemeral keys
        let shared_ee = x25519::dh(&ephemeral_private, &self.initiator_ephemeral);
        self.noise_state.mix_key(&shared_ee);

        // se: DH between our ephemeral and initiator's static
        let shared_se = x25519::dh(&ephemeral_private, &self.initiator_static);
        let _key = self.noise_state.mix_key(&shared_se);

        // psk: Mix pre-shared key
        let key = self.noise_state.mix_key_and_hash(&psk);

        // Encrypt empty payload (just authentication tag)
        let encrypted_nothing = self.noise_state.encrypt_and_hash(&key, &[])?;
        let encrypted_nothing: [u8; 16] = encrypted_nothing
            .try_into()
            .map_err(|_| CryptoError::Encryption)?;

        // Build response message
        let mut response = HandshakeResponse::new(
            self.sender_index,
            self.initiator_index,
            ephemeral_public,
            encrypted_nothing,
        );

        // Compute MAC1 (using initiator's static public key)
        let mac1_key = noise::mac1_key(&self.initiator_static);
        response.mac1 = blake2s::mac(&mac1_key, &response.bytes_for_mac1_owned());
        self.last_mac1 = response.mac1;

        // Compute MAC2 (using cookie if available, otherwise zeros)
        if let Some(cookie) = cookie {
            response.mac2 = blake2s::mac_with_cookie(cookie, &response.bytes_for_mac2_owned());
        }

        // Derive transport keys (responder swaps send/receive)
        let keys = noise::TransportKeys::derive_responder(&self.noise_state.chaining_key);

        Ok((
            response,
            HandshakeResult {
                local_index: self.sender_index,
                remote_index: self.initiator_index,
                sending_key: keys.sending_key,
                receiving_key: keys.receiving_key,
            },
        ))
    }
}

/// Verify MAC1 on a handshake initiation
///
/// We are the responder, so MAC1 is computed with OUR public key
pub fn verify_initiation_mac1(
    initiation_bytes: &[u8],
    our_public_key: &[u8; 32],
) -> Result<(), SecureGuardError> {
    if initiation_bytes.len() < HandshakeInitiation::SIZE {
        return Err(ProtocolError::InvalidMessageLength {
            expected: HandshakeInitiation::SIZE,
            got: initiation_bytes.len(),
        }
        .into());
    }

    let mac1_key = noise::mac1_key(our_public_key);
    let mac1_data = &initiation_bytes[..116]; // Everything before MAC1
    let expected_mac1 = blake2s::mac(&mac1_key, mac1_data);

    let actual_mac1 = &initiation_bytes[116..132];
    if actual_mac1 != expected_mac1 {
        return Err(ProtocolError::MacVerificationFailed.into());
    }

    Ok(())
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

    #[test]
    fn test_initiator_responder_handshake() {
        // Generate keypairs for both sides
        let (initiator_static_private, initiator_static_public) = x25519::generate_keypair();
        let (responder_static_private, responder_static_public) = x25519::generate_keypair();

        // Initiator creates handshake initiation
        let mut initiator =
            InitiatorHandshake::new(initiator_static_private, responder_static_public, None, 1001);
        let initiation = initiator.create_initiation(None).unwrap();

        // Verify MAC1 on initiation
        verify_initiation_mac1(&initiation.to_bytes(), &responder_static_public).unwrap();

        // Responder processes initiation
        let mut responder = ResponderHandshake::new(responder_static_private, 2002);
        let peer_public = responder.process_initiation(&initiation).unwrap();

        // Responder should have decrypted initiator's public key
        assert_eq!(peer_public, initiator_static_public);

        // Responder creates response
        let (response, responder_result) = responder.create_response(None, None).unwrap();

        // Verify MAC1 on response
        verify_response_mac1(&response.to_bytes(), &initiator_static_public).unwrap();

        // Initiator processes response
        let initiator_result = initiator.process_response(&response).unwrap();

        // Both sides should have derived the same keys (but swapped)
        assert_eq!(
            initiator_result.sending_key, responder_result.receiving_key,
            "Initiator's sending key should be responder's receiving key"
        );
        assert_eq!(
            initiator_result.receiving_key, responder_result.sending_key,
            "Initiator's receiving key should be responder's sending key"
        );

        // Indices should match
        assert_eq!(initiator_result.local_index, 1001);
        assert_eq!(initiator_result.remote_index, 2002);
        assert_eq!(responder_result.local_index, 2002);
        assert_eq!(responder_result.remote_index, 1001);
    }

    #[test]
    fn test_handshake_with_psk() {
        let (initiator_static_private, initiator_static_public) = x25519::generate_keypair();
        let (responder_static_private, responder_static_public) = x25519::generate_keypair();
        let psk = [42u8; 32];

        // Initiator with PSK
        let mut initiator = InitiatorHandshake::new(
            initiator_static_private,
            responder_static_public,
            Some(psk),
            1001,
        );
        let initiation = initiator.create_initiation(None).unwrap();

        // Responder processes and responds with same PSK
        let mut responder = ResponderHandshake::new(responder_static_private, 2002);
        let peer_public = responder.process_initiation(&initiation).unwrap();
        assert_eq!(peer_public, initiator_static_public);

        let (response, responder_result) = responder.create_response(Some(psk), None).unwrap();

        // Initiator processes response
        let initiator_result = initiator.process_response(&response).unwrap();

        // Keys should still match
        assert_eq!(initiator_result.sending_key, responder_result.receiving_key);
        assert_eq!(initiator_result.receiving_key, responder_result.sending_key);
    }
}
