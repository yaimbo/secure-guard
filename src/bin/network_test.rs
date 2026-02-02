//! Network test: send handshake and dump raw bytes

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use minnowvpn::config::WireGuardConfig;
use minnowvpn::protocol::handshake::InitiatorHandshake;
use std::net::UdpSocket;
use std::time::Duration;

fn main() {
    let config = WireGuardConfig::from_file("docs/clients/vpn.fronthouse.ai.conf")
        .expect("Failed to load config");

    let private_key = config.interface.private_key;
    let peer = &config.peers[0];
    let peer_public = peer.public_key;
    let endpoint = peer.endpoint.expect("Peer must have endpoint");

    println!("=== Network Test ===\n");
    println!("Our public key: {}", BASE64.encode(&minnowvpn::crypto::x25519::public_key(&private_key)));
    println!("Peer public key: {}", BASE64.encode(&peer_public));
    println!("Endpoint: {}", endpoint);

    // Create handshake
    let mut handshake = InitiatorHandshake::new(private_key, peer_public, None, 0xDEADBEEF);
    let init = handshake.create_initiation(None).expect("create initiation");
    let bytes = init.to_bytes();

    println!("\n=== Packet to send ({} bytes) ===", bytes.len());
    
    // Print in a format that can be compared with tcpdump
    for (i, chunk) in bytes.chunks(16).enumerate() {
        print!("{:04x}  ", i * 16);
        for b in chunk {
            print!("{:02x} ", b);
        }
        println!();
    }

    // Verify packet structure
    println!("\n=== Packet structure ===");
    println!("Type: {} (expected: 1)", bytes[0]);
    println!("Reserved: {:02x?} (expected: zeros)", &bytes[1..4]);
    println!("Sender index: 0x{:08x}", u32::from_le_bytes(bytes[4..8].try_into().unwrap()));
    
    // Send packet
    println!("\n=== Sending to {} ===", endpoint);
    let socket = UdpSocket::bind("0.0.0.0:0").expect("bind socket");
    let local_addr = socket.local_addr().expect("local addr");
    println!("Bound to: {}", local_addr);
    
    socket.set_read_timeout(Some(Duration::from_secs(5))).expect("set timeout");
    
    let sent = socket.send_to(&bytes, endpoint).expect("send packet");
    println!("Sent {} bytes to {}", sent, endpoint);

    // Wait for response
    println!("\n=== Waiting for response (5s) ===");
    let mut buf = [0u8; 256];
    match socket.recv_from(&mut buf) {
        Ok((len, from)) => {
            println!("Received {} bytes from {}", len, from);
            println!("Response type: {}", buf[0]);
            
            // Dump response
            println!("\nResponse bytes:");
            for (i, chunk) in buf[..len].chunks(16).enumerate() {
                print!("{:04x}  ", i * 16);
                for b in chunk {
                    print!("{:02x} ", b);
                }
                println!();
            }
        }
        Err(e) => {
            println!("No response: {}", e);
            println!("\nThis could mean:");
            println!("1. Our public key isn't registered on the server");
            println!("2. MAC1 verification failed on server");
            println!("3. Decryption failed on server");
            println!("4. Firewall blocking response");
        }
    }
}
