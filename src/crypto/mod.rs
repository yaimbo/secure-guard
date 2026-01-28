//! Cryptographic primitives for WireGuard
//!
//! This module provides all cryptographic operations needed for the WireGuard protocol:
//! - BLAKE2s hashing, HMAC, and key derivation (blake2s)
//! - ChaCha20-Poly1305 AEAD encryption (aead)
//! - X25519 Diffie-Hellman key exchange (x25519)
//! - Noise IKpsk2 protocol state machine (noise)

pub mod aead;
pub mod blake2s;
pub mod noise;
pub mod x25519;
