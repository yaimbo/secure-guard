//! Debug config loading

use secureguard_poc::config::WireGuardConfig;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};

fn main() {
    println!("=== Config Loading Debug ===\n");
    
    let config = WireGuardConfig::from_file("docs/clients/vpn.fronthouse.ai.conf")
        .expect("Failed to load config");
    
    println!("Interface:");
    println!("  Private key: {}", BASE64.encode(&config.interface.private_key));
    println!("  Private key hex: {}", hex::encode(&config.interface.private_key));
    println!("  Address: {:?}", config.interface.address);
    println!("  DNS: {:?}", config.interface.dns);
    
    println!("\nPeer:");
    println!("  Public key: {}", BASE64.encode(&config.peers[0].public_key));
    println!("  Public key hex: {}", hex::encode(&config.peers[0].public_key));
    if let Some(endpoint) = config.peers[0].endpoint {
        println!("  Endpoint: {}", endpoint);
    }
    println!("  Persistent keepalive: {:?}", config.peers[0].persistent_keepalive);
    
    // Verify by computing our public key
    let our_public = secureguard_poc::crypto::x25519::public_key(&config.interface.private_key);
    println!("\nDerived public key: {}", BASE64.encode(&our_public));
    println!("Derived public key hex: {}", hex::encode(&our_public));
}
