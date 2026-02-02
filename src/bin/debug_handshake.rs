//! Debug tool to inspect handshake packet generation and send to server
//!
//! This can run without sudo since it doesn't create TUN devices.

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use minnowvpn::config::WireGuardConfig;
use minnowvpn::protocol::handshake::InitiatorHandshake;
use std::net::UdpSocket;
use std::time::Duration;

fn main() {
    // Initialize tracing for debug output
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .with_target(false)
        .init();

    // Load config from file
    let config = WireGuardConfig::from_file("docs/clients/vpn.fronthouse.ai.conf")
        .expect("Failed to load config");

    let private_key = config.interface.private_key;
    let peer = &config.peers[0];
    let peer_public = peer.public_key;
    let endpoint = peer.endpoint.expect("Peer must have endpoint");

    println!("Private key: {}", hex::encode(&private_key));
    println!("Peer public key: {}", hex::encode(&peer_public));

    // Derive our public key
    let our_public = minnowvpn::crypto::x25519::public_key(&private_key);
    println!("Our public key: {}", hex::encode(&our_public));
    println!("Our public key (base64): {}", BASE64.encode(&our_public));
    println!("Endpoint: {}", endpoint);

    // Create handshake
    let mut handshake = InitiatorHandshake::new(private_key, peer_public, None, 0x12345678);

    println!("\n--- Creating handshake initiation ---\n");
    let init = handshake.create_initiation(None).expect("create initiation");

    let bytes = init.to_bytes();
    println!("\n--- Full packet ({} bytes) ---", bytes.len());
    println!("{}", hex::encode(&bytes));

    println!("\n--- Packet breakdown ---");
    println!("Type: {:02x}", bytes[0]);
    println!("Reserved: {:02x?}", &bytes[1..4]);
    println!("Sender index: {:02x?} (LE: {})", &bytes[4..8], u32::from_le_bytes(bytes[4..8].try_into().unwrap()));
    println!("Ephemeral public: {}", hex::encode(&bytes[8..40]));
    println!("Encrypted static: {}", hex::encode(&bytes[40..88]));
    println!("Encrypted timestamp: {}", hex::encode(&bytes[88..116]));
    println!("MAC1: {}", hex::encode(&bytes[116..132]));
    println!("MAC2: {}", hex::encode(&bytes[132..148]));

    // Now send to server
    println!("\n--- Sending to server {} ---", endpoint);
    let socket = UdpSocket::bind("0.0.0.0:0").expect("bind socket");
    socket.set_read_timeout(Some(Duration::from_secs(5))).expect("set timeout");

    socket.send_to(&bytes, endpoint).expect("send packet");
    println!("Sent {} bytes", bytes.len());

    // Wait for response
    println!("\n--- Waiting for response (5s timeout) ---");
    let mut buf = [0u8; 256];
    match socket.recv_from(&mut buf) {
        Ok((len, from)) => {
            println!("Received {} bytes from {}", len, from);
            println!("Response type: {}", buf[0]);
            println!("Response hex: {}", hex::encode(&buf[..len]));

            if buf[0] == 2 {
                println!("\n*** HANDSHAKE RESPONSE RECEIVED! ***");
                println!("Sender index: {:02x?}", &buf[4..8]);
                println!("Receiver index: {:02x?}", &buf[8..12]);
                println!("Ephemeral public: {}", hex::encode(&buf[12..44]));
            } else if buf[0] == 3 {
                println!("\n*** COOKIE REPLY RECEIVED ***");
            } else {
                println!("\nUnexpected message type: {}", buf[0]);
            }
        }
        Err(e) => {
            println!("No response: {} (handshake timeout)", e);
        }
    }
}
