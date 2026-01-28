//! WireGuard message wire formats
//!
//! Defines the packet structures for:
//! - Type 1: Handshake Initiation (148 bytes)
//! - Type 2: Handshake Response (92 bytes)
//! - Type 3: Cookie Reply (64 bytes)
//! - Type 4: Transport Data (variable)

use crate::error::ProtocolError;

/// WireGuard message types
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageType {
    HandshakeInitiation = 1,
    HandshakeResponse = 2,
    CookieReply = 3,
    TransportData = 4,
}

impl TryFrom<u8> for MessageType {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::HandshakeInitiation),
            2 => Ok(Self::HandshakeResponse),
            3 => Ok(Self::CookieReply),
            4 => Ok(Self::TransportData),
            _ => Err(ProtocolError::InvalidMessageType { msg_type: value }),
        }
    }
}

/// Handshake Initiation message (148 bytes)
///
/// ```text
/// type(1) | reserved(3) | sender_index(4) | ephemeral_public(32) |
/// encrypted_static(48) | encrypted_timestamp(28) | mac1(16) | mac2(16)
/// ```
#[derive(Debug, Clone)]
pub struct HandshakeInitiation {
    pub sender_index: u32,
    pub ephemeral_public: [u8; 32],
    pub encrypted_static: [u8; 48], // 32 bytes static + 16 bytes tag
    pub encrypted_timestamp: [u8; 28], // 12 bytes TAI64N + 16 bytes tag
    pub mac1: [u8; 16],
    pub mac2: [u8; 16],
}

impl HandshakeInitiation {
    /// Size of the handshake initiation message
    pub const SIZE: usize = 148;

    /// Create a new handshake initiation (MACs are zeroed, must be computed separately)
    pub fn new(
        sender_index: u32,
        ephemeral_public: [u8; 32],
        encrypted_static: [u8; 48],
        encrypted_timestamp: [u8; 28],
    ) -> Self {
        Self {
            sender_index,
            ephemeral_public,
            encrypted_static,
            encrypted_timestamp,
            mac1: [0u8; 16],
            mac2: [0u8; 16],
        }
    }

    /// Serialize to bytes
    pub fn to_bytes(&self) -> [u8; Self::SIZE] {
        let mut buf = [0u8; Self::SIZE];

        buf[0] = MessageType::HandshakeInitiation as u8;
        // buf[1..4] reserved (zeros)
        buf[4..8].copy_from_slice(&self.sender_index.to_le_bytes());
        buf[8..40].copy_from_slice(&self.ephemeral_public);
        buf[40..88].copy_from_slice(&self.encrypted_static);
        buf[88..116].copy_from_slice(&self.encrypted_timestamp);
        buf[116..132].copy_from_slice(&self.mac1);
        buf[132..148].copy_from_slice(&self.mac2);

        buf
    }

    /// Get bytes up to (but not including) mac1 for MAC1 computation
    pub fn bytes_for_mac1(&self) -> [u8; 116] {
        let full = self.to_bytes();
        let mut result = [0u8; 116];
        result.copy_from_slice(&full[..116]);
        result
    }

    /// Get bytes up to (but not including) mac2 for MAC2 computation
    pub fn bytes_for_mac2(&self) -> [u8; 132] {
        let full = self.to_bytes();
        let mut result = [0u8; 132];
        result.copy_from_slice(&full[..132]);
        result
    }

    /// Parse from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, ProtocolError> {
        if data.len() < Self::SIZE {
            return Err(ProtocolError::InvalidMessageLength {
                expected: Self::SIZE,
                got: data.len(),
            });
        }

        if data[0] != MessageType::HandshakeInitiation as u8 {
            return Err(ProtocolError::InvalidMessageType { msg_type: data[0] });
        }

        let sender_index = u32::from_le_bytes(data[4..8].try_into().unwrap());

        let mut ephemeral_public = [0u8; 32];
        ephemeral_public.copy_from_slice(&data[8..40]);

        let mut encrypted_static = [0u8; 48];
        encrypted_static.copy_from_slice(&data[40..88]);

        let mut encrypted_timestamp = [0u8; 28];
        encrypted_timestamp.copy_from_slice(&data[88..116]);

        let mut mac1 = [0u8; 16];
        mac1.copy_from_slice(&data[116..132]);

        let mut mac2 = [0u8; 16];
        mac2.copy_from_slice(&data[132..148]);

        Ok(Self {
            sender_index,
            ephemeral_public,
            encrypted_static,
            encrypted_timestamp,
            mac1,
            mac2,
        })
    }
}

/// Handshake Response message (92 bytes)
///
/// ```text
/// type(1) | reserved(3) | sender_index(4) | receiver_index(4) |
/// ephemeral_public(32) | encrypted_nothing(16) | mac1(16) | mac2(16)
/// ```
#[derive(Debug, Clone)]
pub struct HandshakeResponse {
    pub sender_index: u32,
    pub receiver_index: u32,
    pub ephemeral_public: [u8; 32],
    pub encrypted_nothing: [u8; 16], // Just the auth tag
    pub mac1: [u8; 16],
    pub mac2: [u8; 16],
}

impl HandshakeResponse {
    /// Size of the handshake response message
    pub const SIZE: usize = 92;

    /// Parse from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, ProtocolError> {
        if data.len() < Self::SIZE {
            return Err(ProtocolError::InvalidMessageLength {
                expected: Self::SIZE,
                got: data.len(),
            });
        }

        if data[0] != MessageType::HandshakeResponse as u8 {
            return Err(ProtocolError::InvalidMessageType { msg_type: data[0] });
        }

        let sender_index = u32::from_le_bytes(data[4..8].try_into().unwrap());
        let receiver_index = u32::from_le_bytes(data[8..12].try_into().unwrap());

        let mut ephemeral_public = [0u8; 32];
        ephemeral_public.copy_from_slice(&data[12..44]);

        let mut encrypted_nothing = [0u8; 16];
        encrypted_nothing.copy_from_slice(&data[44..60]);

        let mut mac1 = [0u8; 16];
        mac1.copy_from_slice(&data[60..76]);

        let mut mac2 = [0u8; 16];
        mac2.copy_from_slice(&data[76..92]);

        Ok(Self {
            sender_index,
            receiver_index,
            ephemeral_public,
            encrypted_nothing,
            mac1,
            mac2,
        })
    }

    /// Get bytes up to (but not including) mac1 for MAC1 verification
    pub fn bytes_for_mac1(data: &[u8]) -> &[u8] {
        &data[..60]
    }
}

/// Cookie Reply message (64 bytes)
///
/// ```text
/// type(1) | reserved(3) | receiver_index(4) | nonce(24) | encrypted_cookie(32)
/// ```
#[derive(Debug, Clone)]
pub struct CookieReply {
    pub receiver_index: u32,
    pub nonce: [u8; 24],
    pub encrypted_cookie: [u8; 32], // 16 bytes cookie + 16 bytes tag
}

impl CookieReply {
    /// Size of the cookie reply message
    pub const SIZE: usize = 64;

    /// Parse from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, ProtocolError> {
        if data.len() < Self::SIZE {
            return Err(ProtocolError::InvalidMessageLength {
                expected: Self::SIZE,
                got: data.len(),
            });
        }

        if data[0] != MessageType::CookieReply as u8 {
            return Err(ProtocolError::InvalidMessageType { msg_type: data[0] });
        }

        let receiver_index = u32::from_le_bytes(data[4..8].try_into().unwrap());

        let mut nonce = [0u8; 24];
        nonce.copy_from_slice(&data[8..32]);

        let mut encrypted_cookie = [0u8; 32];
        encrypted_cookie.copy_from_slice(&data[32..64]);

        Ok(Self {
            receiver_index,
            nonce,
            encrypted_cookie,
        })
    }
}

/// Transport Data message header (16 bytes, followed by encrypted payload)
///
/// ```text
/// type(1) | reserved(3) | receiver_index(4) | counter(8) | encrypted_packet(n+16)
/// ```
#[derive(Debug, Clone)]
pub struct TransportHeader {
    pub receiver_index: u32,
    pub counter: u64,
}

impl TransportHeader {
    /// Size of the transport header (not including encrypted payload)
    pub const SIZE: usize = 16;

    /// Minimum size of a transport message (header + at least auth tag)
    pub const MIN_SIZE: usize = Self::SIZE + 16;

    /// Build a transport message with encrypted payload
    pub fn build_message(receiver_index: u32, counter: u64, encrypted_payload: &[u8]) -> Vec<u8> {
        let mut buf = Vec::with_capacity(Self::SIZE + encrypted_payload.len());

        buf.push(MessageType::TransportData as u8);
        buf.extend_from_slice(&[0, 0, 0]); // reserved
        buf.extend_from_slice(&receiver_index.to_le_bytes());
        buf.extend_from_slice(&counter.to_le_bytes());
        buf.extend_from_slice(encrypted_payload);

        buf
    }

    /// Parse header from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, ProtocolError> {
        if data.len() < Self::SIZE {
            return Err(ProtocolError::InvalidMessageLength {
                expected: Self::SIZE,
                got: data.len(),
            });
        }

        if data[0] != MessageType::TransportData as u8 {
            return Err(ProtocolError::InvalidMessageType { msg_type: data[0] });
        }

        let receiver_index = u32::from_le_bytes(data[4..8].try_into().unwrap());
        let counter = u64::from_le_bytes(data[8..16].try_into().unwrap());

        Ok(Self {
            receiver_index,
            counter,
        })
    }

    /// Get the encrypted payload from a transport message
    pub fn payload(data: &[u8]) -> &[u8] {
        &data[Self::SIZE..]
    }
}

/// Get the message type from a packet
pub fn get_message_type(data: &[u8]) -> Result<MessageType, ProtocolError> {
    if data.is_empty() {
        return Err(ProtocolError::InvalidMessageLength {
            expected: 1,
            got: 0,
        });
    }
    MessageType::try_from(data[0])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_handshake_initiation_roundtrip() {
        let init = HandshakeInitiation {
            sender_index: 0x12345678,
            ephemeral_public: [1u8; 32],
            encrypted_static: [2u8; 48],
            encrypted_timestamp: [3u8; 28],
            mac1: [4u8; 16],
            mac2: [5u8; 16],
        };

        let bytes = init.to_bytes();
        assert_eq!(bytes.len(), HandshakeInitiation::SIZE);
        assert_eq!(bytes[0], 1); // Type

        let parsed = HandshakeInitiation::from_bytes(&bytes).unwrap();
        assert_eq!(parsed.sender_index, init.sender_index);
        assert_eq!(parsed.ephemeral_public, init.ephemeral_public);
        assert_eq!(parsed.mac1, init.mac1);
    }

    #[test]
    fn test_handshake_response_parse() {
        let mut data = [0u8; HandshakeResponse::SIZE];
        data[0] = 2; // Type
        data[4..8].copy_from_slice(&0x11223344u32.to_le_bytes()); // sender_index
        data[8..12].copy_from_slice(&0x55667788u32.to_le_bytes()); // receiver_index

        let parsed = HandshakeResponse::from_bytes(&data).unwrap();
        assert_eq!(parsed.sender_index, 0x11223344);
        assert_eq!(parsed.receiver_index, 0x55667788);
    }

    #[test]
    fn test_transport_build() {
        let payload = vec![0xAA; 100];
        let msg = TransportHeader::build_message(42, 1234, &payload);

        assert_eq!(msg[0], 4); // Type
        assert_eq!(msg.len(), TransportHeader::SIZE + payload.len());

        let header = TransportHeader::from_bytes(&msg).unwrap();
        assert_eq!(header.receiver_index, 42);
        assert_eq!(header.counter, 1234);

        let extracted_payload = TransportHeader::payload(&msg);
        assert_eq!(extracted_payload, &payload[..]);
    }

    #[test]
    fn test_invalid_message_type() {
        let data = [99u8; 100]; // Invalid type
        let result = get_message_type(&data);
        assert!(result.is_err());
    }
}
