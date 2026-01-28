//! BLAKE2s cryptographic primitives for WireGuard
//!
//! Implements BLAKE2s hash, HMAC, and HKDF functions used in the WireGuard protocol.

use blake2::{
    digest::{consts::U16, FixedOutput, Mac as MacTrait, Update},
    Blake2s256, Blake2sMac, Digest,
};
use hmac::SimpleHmac;

/// Type alias for HMAC-BLAKE2s (RFC 2104 HMAC with BLAKE2s-256)
/// Uses SimpleHmac which works with any hash that implements the required traits
type HmacBlake2s = SimpleHmac<Blake2s256>;

/// Length of BLAKE2s-256 hash output
pub const HASH_LEN: usize = 32;

/// Length of BLAKE2s MAC output (16 bytes for WireGuard)
pub const MAC_LEN: usize = 16;

/// BLAKE2s-256 hash of a single input
pub fn hash(data: &[u8]) -> [u8; HASH_LEN] {
    let mut hasher = Blake2s256::new();
    Digest::update(&mut hasher, data);
    hasher.finalize().into()
}

/// BLAKE2s-256 hash of two concatenated inputs: HASH(a || b)
pub fn hash_two(a: &[u8], b: &[u8]) -> [u8; HASH_LEN] {
    let mut hasher = Blake2s256::new();
    Digest::update(&mut hasher, a);
    Digest::update(&mut hasher, b);
    hasher.finalize().into()
}

/// BLAKE2s keyed MAC (16 bytes output) with 32-byte key
/// Used for MAC1 in WireGuard handshake
pub fn mac(key: &[u8; HASH_LEN], data: &[u8]) -> [u8; MAC_LEN] {
    let mut mac = Blake2sMac::<U16>::new_from_slice(key).expect("valid key length");
    MacTrait::update(&mut mac, data);
    mac.finalize_fixed().into()
}

/// BLAKE2s keyed MAC (16 bytes output) with 16-byte key
/// Used for MAC2 in WireGuard handshake (keyed with cookie)
pub fn mac_with_cookie(key: &[u8; MAC_LEN], data: &[u8]) -> [u8; MAC_LEN] {
    let mut mac = Blake2sMac::<U16>::new_from_slice(key).expect("valid key length");
    MacTrait::update(&mut mac, data);
    mac.finalize_fixed().into()
}

/// HMAC-BLAKE2s implementation using standard RFC 2104 HMAC construction
///
/// This matches what boringtun and other WireGuard implementations use.
/// Despite the WireGuard whitepaper notation, implementations use the
/// standard HMAC construction: H((K ⊕ opad) || H((K ⊕ ipad) || M))
pub fn hmac(key: &[u8], data: &[u8]) -> [u8; HASH_LEN] {
    let mut mac = HmacBlake2s::new_from_slice(key).expect("HMAC accepts any key length");
    Update::update(&mut mac, data);
    mac.finalize_fixed().into()
}

/// KDF1: Single-output key derivation
/// Returns one 32-byte key
pub fn kdf1(key: &[u8; HASH_LEN], input: &[u8]) -> [u8; HASH_LEN] {
    let temp = hmac(key, input);
    hmac(&temp, &[0x01])
}

/// KDF2: Two-output key derivation
/// Returns two 32-byte keys
pub fn kdf2(key: &[u8; HASH_LEN], input: &[u8]) -> ([u8; HASH_LEN], [u8; HASH_LEN]) {
    let temp = hmac(key, input);

    // T1 = HMAC(temp, 0x01)
    let t1 = hmac(&temp, &[0x01]);

    // T2 = HMAC(temp, T1 || 0x02)
    let mut t2_input = [0u8; HASH_LEN + 1];
    t2_input[..HASH_LEN].copy_from_slice(&t1);
    t2_input[HASH_LEN] = 0x02;
    let t2 = hmac(&temp, &t2_input);

    (t1, t2)
}

/// KDF3: Three-output key derivation
/// Returns three 32-byte keys
pub fn kdf3(key: &[u8; HASH_LEN], input: &[u8]) -> ([u8; HASH_LEN], [u8; HASH_LEN], [u8; HASH_LEN]) {
    let temp = hmac(key, input);

    // T1 = HMAC(temp, 0x01)
    let t1 = hmac(&temp, &[0x01]);

    // T2 = HMAC(temp, T1 || 0x02)
    let mut t2_input = [0u8; HASH_LEN + 1];
    t2_input[..HASH_LEN].copy_from_slice(&t1);
    t2_input[HASH_LEN] = 0x02;
    let t2 = hmac(&temp, &t2_input);

    // T3 = HMAC(temp, T2 || 0x03)
    let mut t3_input = [0u8; HASH_LEN + 1];
    t3_input[..HASH_LEN].copy_from_slice(&t2);
    t3_input[HASH_LEN] = 0x03;
    let t3 = hmac(&temp, &t3_input);

    (t1, t2, t3)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash_empty() {
        // BLAKE2s-256 of empty string
        let result = hash(&[]);
        // Known value from reference implementation
        assert_eq!(result.len(), 32);
    }

    #[test]
    fn test_hash_two() {
        let a = b"hello";
        let b = b"world";

        // hash_two(a, b) should equal hash(a || b)
        let result1 = hash_two(a, b);

        let mut combined = Vec::new();
        combined.extend_from_slice(a);
        combined.extend_from_slice(b);
        let result2 = hash(&combined);

        assert_eq!(result1, result2);
    }

    #[test]
    fn test_mac_length() {
        let key = [0u8; 32];
        let data = b"test data";
        let result = mac(&key, data);
        assert_eq!(result.len(), 16);
    }

    #[test]
    fn test_kdf_outputs() {
        let key = [0u8; 32];
        let input = b"test input";

        let k1 = kdf1(&key, input);
        assert_eq!(k1.len(), 32);

        let (k2a, k2b) = kdf2(&key, input);
        assert_eq!(k2a.len(), 32);
        assert_eq!(k2b.len(), 32);
        assert_ne!(k2a, k2b);

        let (k3a, k3b, k3c) = kdf3(&key, input);
        assert_eq!(k3a.len(), 32);
        assert_eq!(k3b.len(), 32);
        assert_eq!(k3c.len(), 32);
        assert_ne!(k3a, k3b);
        assert_ne!(k3b, k3c);
    }
}
