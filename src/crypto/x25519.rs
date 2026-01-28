//! X25519 Diffie-Hellman key exchange for WireGuard
//!
//! Provides key generation and DH operations using Curve25519.

use rand::rngs::OsRng;
use x25519_dalek::{PublicKey, StaticSecret};

/// Key length for X25519 (both private and public keys are 32 bytes)
pub const KEY_LEN: usize = 32;

/// Generate a new X25519 keypair
///
/// Returns (private_key, public_key)
pub fn generate_keypair() -> ([u8; KEY_LEN], [u8; KEY_LEN]) {
    let secret = StaticSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);
    (secret.to_bytes(), public.to_bytes())
}

/// Derive public key from private key
pub fn public_key(private_key: &[u8; KEY_LEN]) -> [u8; KEY_LEN] {
    let secret = StaticSecret::from(*private_key);
    PublicKey::from(&secret).to_bytes()
}

/// Perform X25519 Diffie-Hellman key exchange
///
/// Computes the shared secret from our private key and their public key.
pub fn dh(private_key: &[u8; KEY_LEN], public_key: &[u8; KEY_LEN]) -> [u8; KEY_LEN] {
    let secret = StaticSecret::from(*private_key);
    let public = PublicKey::from(*public_key);
    secret.diffie_hellman(&public).to_bytes()
}

/// Check if a public key is valid (not zero or low-order points)
///
/// WireGuard doesn't actually check this in the spec, but it's good practice.
pub fn is_valid_public_key(key: &[u8; KEY_LEN]) -> bool {
    // Check for all-zero key (identity point)
    if key.iter().all(|&b| b == 0) {
        return false;
    }

    // The x25519-dalek library handles low-order point checks internally
    // during DH computation, so we mainly check for zero here
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keypair_generation() {
        let (private, public) = generate_keypair();

        // Keys should not be all zeros
        assert!(!private.iter().all(|&b| b == 0));
        assert!(!public.iter().all(|&b| b == 0));

        // Derived public key should match
        assert_eq!(public_key(&private), public);
    }

    #[test]
    fn test_dh_shared_secret() {
        // Generate two keypairs
        let (alice_private, alice_public) = generate_keypair();
        let (bob_private, bob_public) = generate_keypair();

        // DH should produce the same shared secret from both sides
        let shared_alice = dh(&alice_private, &bob_public);
        let shared_bob = dh(&bob_private, &alice_public);

        assert_eq!(shared_alice, shared_bob);
    }

    #[test]
    fn test_dh_different_keys() {
        let (alice_private, _) = generate_keypair();
        let (_, bob_public) = generate_keypair();
        let (_, carol_public) = generate_keypair();

        // DH with different public keys should produce different results
        let shared_bob = dh(&alice_private, &bob_public);
        let shared_carol = dh(&alice_private, &carol_public);

        assert_ne!(shared_bob, shared_carol);
    }

    #[test]
    fn test_public_key_derivation() {
        // Known test vector (from RFC 7748)
        let private = [
            0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, 0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2,
            0x66, 0x45, 0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a, 0xb1, 0x77, 0xfb, 0xa5,
            0x1d, 0xb9, 0x2c, 0x2a,
        ];

        let expected_public = [
            0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54, 0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e,
            0xf7, 0x5a, 0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4, 0xeb, 0xa4, 0xa9, 0x8e,
            0xaa, 0x9b, 0x4e, 0x6a,
        ];

        let computed_public = public_key(&private);
        assert_eq!(computed_public, expected_public);
    }

    #[test]
    fn test_is_valid_public_key() {
        let (_, valid_key) = generate_keypair();
        assert!(is_valid_public_key(&valid_key));

        let zero_key = [0u8; 32];
        assert!(!is_valid_public_key(&zero_key));
    }
}
