//! AEAD encryption for WireGuard
//!
//! Implements ChaCha20-Poly1305 for transport encryption and
//! XChaCha20-Poly1305 for cookie decryption.

use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    ChaCha20Poly1305, Key, Nonce, XChaCha20Poly1305, XNonce,
};

use crate::error::CryptoError;

/// Authentication tag length
pub const TAG_LEN: usize = 16;

/// ChaCha20-Poly1305 key length
pub const KEY_LEN: usize = 32;

/// ChaCha20-Poly1305 nonce length
pub const NONCE_LEN: usize = 12;

/// XChaCha20-Poly1305 nonce length
pub const XNONCE_LEN: usize = 24;

/// Encrypt plaintext using ChaCha20-Poly1305
///
/// WireGuard uses a 64-bit counter as the nonce, zero-padded to 96 bits.
/// The counter is placed in the last 8 bytes of the nonce (little-endian).
pub fn encrypt(
    key: &[u8; KEY_LEN],
    counter: u64,
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));

    // Build nonce: 4 zero bytes + 8 bytes counter (little-endian)
    let mut nonce_bytes = [0u8; NONCE_LEN];
    nonce_bytes[4..12].copy_from_slice(&counter.to_le_bytes());
    let nonce = Nonce::from_slice(&nonce_bytes);

    cipher
        .encrypt(
            nonce,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Encryption)
}

/// Decrypt ciphertext using ChaCha20-Poly1305
///
/// Returns None if authentication fails.
pub fn decrypt(
    key: &[u8; KEY_LEN],
    counter: u64,
    ciphertext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if ciphertext.len() < TAG_LEN {
        return Err(CryptoError::Decryption);
    }

    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));

    // Build nonce: 4 zero bytes + 8 bytes counter (little-endian)
    let mut nonce_bytes = [0u8; NONCE_LEN];
    nonce_bytes[4..12].copy_from_slice(&counter.to_le_bytes());
    let nonce = Nonce::from_slice(&nonce_bytes);

    cipher
        .decrypt(
            nonce,
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Decryption)
}

/// Encrypt using XChaCha20-Poly1305 (used for cookie encryption)
pub fn xencrypt(
    key: &[u8; KEY_LEN],
    nonce: &[u8; XNONCE_LEN],
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key));
    let xnonce = XNonce::from_slice(nonce);

    cipher
        .encrypt(
            xnonce,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Encryption)
}

/// Decrypt using XChaCha20-Poly1305 (used for cookie decryption)
pub fn xdecrypt(
    key: &[u8; KEY_LEN],
    nonce: &[u8; XNONCE_LEN],
    ciphertext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if ciphertext.len() < TAG_LEN {
        return Err(CryptoError::Decryption);
    }

    let cipher = XChaCha20Poly1305::new(Key::from_slice(key));
    let xnonce = XNonce::from_slice(nonce);

    cipher
        .decrypt(
            xnonce,
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Decryption)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = [0u8; 32];
        let plaintext = b"Hello, WireGuard!";
        let aad = b"additional data";
        let counter = 42u64;

        let ciphertext = encrypt(&key, counter, plaintext, aad).unwrap();
        assert_eq!(ciphertext.len(), plaintext.len() + TAG_LEN);

        let decrypted = decrypt(&key, counter, &ciphertext, aad).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_decrypt_wrong_key() {
        let key = [0u8; 32];
        let wrong_key = [1u8; 32];
        let plaintext = b"Hello, WireGuard!";
        let aad = b"additional data";
        let counter = 42u64;

        let ciphertext = encrypt(&key, counter, plaintext, aad).unwrap();
        let result = decrypt(&wrong_key, counter, &ciphertext, aad);
        assert!(result.is_err());
    }

    #[test]
    fn test_decrypt_wrong_counter() {
        let key = [0u8; 32];
        let plaintext = b"Hello, WireGuard!";
        let aad = b"additional data";

        let ciphertext = encrypt(&key, 42, plaintext, aad).unwrap();
        let result = decrypt(&key, 43, &ciphertext, aad);
        assert!(result.is_err());
    }

    #[test]
    fn test_decrypt_wrong_aad() {
        let key = [0u8; 32];
        let plaintext = b"Hello, WireGuard!";
        let counter = 42u64;

        let ciphertext = encrypt(&key, counter, plaintext, b"correct aad").unwrap();
        let result = decrypt(&key, counter, &ciphertext, b"wrong aad");
        assert!(result.is_err());
    }

    #[test]
    fn test_xchacha_roundtrip() {
        let key = [0u8; 32];
        let nonce = [0u8; 24];
        let plaintext = b"Cookie data";
        let aad = b"mac1";

        let ciphertext = xencrypt(&key, &nonce, plaintext, aad).unwrap();
        let decrypted = xdecrypt(&key, &nonce, &ciphertext, aad).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_empty_plaintext() {
        let key = [0u8; 32];
        let aad = b"";
        let counter = 0u64;

        // WireGuard handshake response encrypts empty data
        let ciphertext = encrypt(&key, counter, &[], aad).unwrap();
        assert_eq!(ciphertext.len(), TAG_LEN); // Just the tag

        let decrypted = decrypt(&key, counter, &ciphertext, aad).unwrap();
        assert!(decrypted.is_empty());
    }
}
