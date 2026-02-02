//! Verify initial chain key and hash match boringtun

use minnowvpn::crypto::{blake2s, noise};

fn main() {
    println!("=== Verifying Initial Constants ===\n");
    
    // Boringtun's constants
    let boringtun_chain_key: [u8; 32] = [
        96, 226, 109, 174, 243, 39, 239, 192, 46, 195, 53, 226, 160, 37, 210, 208, 
        22, 235, 66, 6, 248, 114, 119, 245, 45, 56, 209, 152, 139, 120, 205, 54,
    ];
    
    let boringtun_chain_hash: [u8; 32] = [
        34, 17, 179, 97, 8, 26, 197, 102, 105, 18, 67, 219, 69, 138, 213, 50, 
        45, 156, 108, 102, 34, 147, 232, 183, 14, 225, 156, 101, 186, 7, 158, 243,
    ];
    
    // Our computed values
    let our_chain_key = noise::HandshakeState::initial_chain_key();
    
    println!("INITIAL_CHAIN_KEY = HASH(CONSTRUCTION):");
    println!("  Boringtun: {:02x?}", &boringtun_chain_key[..8]);
    println!("  Ours:      {:02x?}", &our_chain_key[..8]);
    println!("  Match: {}\n", our_chain_key == boringtun_chain_key);
    
    // Compute HASH(chain_key || IDENTIFIER) 
    let our_chain_hash = blake2s::hash_two(&our_chain_key, noise::IDENTIFIER);
    
    println!("INITIAL_CHAIN_HASH = HASH(chain_key || IDENTIFIER):");
    println!("  Boringtun: {:02x?}", &boringtun_chain_hash[..8]);
    println!("  Ours:      {:02x?}", &our_chain_hash[..8]);
    println!("  Match: {}\n", our_chain_hash == boringtun_chain_hash);
    
    // With peer static
    let peer_public_hex = "6209018ca5c447961aac3f124ecbcc154470ff99e108b205389e6e296aeb316e";
    let peer_public: [u8; 32] = hex::decode(peer_public_hex).unwrap().try_into().unwrap();
    
    let final_hash = blake2s::hash_two(&our_chain_hash, &peer_public);
    println!("Final hash = HASH(chain_hash || peer_static):");
    println!("  {:02x?}", &final_hash[..8]);
}
