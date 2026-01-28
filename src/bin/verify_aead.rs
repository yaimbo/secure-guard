//! Verify AEAD encryption format

use secureguard_poc::crypto::aead;

fn main() {
    println!("=== AEAD Format Verification ===\n");
    
    let key = [0x42u8; 32];
    let plaintext = [0x01u8; 32]; // 32 bytes like static public key
    let aad = [0x00u8; 32]; // Some AAD like the hash
    
    let ciphertext = aead::encrypt(&key, 0, &plaintext, &aad).expect("encrypt");
    
    println!("Plaintext length: {} bytes", plaintext.len());
    println!("Ciphertext length: {} bytes", ciphertext.len());
    println!("Expected: {} bytes (plaintext + 16 byte tag)", plaintext.len() + 16);
    
    // The tag should be at the end
    println!("\nCiphertext (first 16 bytes): {}", hex::encode(&ciphertext[..16]));
    println!("Ciphertext (next 16 bytes):  {}", hex::encode(&ciphertext[16..32]));
    println!("Tag (last 16 bytes):         {}", hex::encode(&ciphertext[32..48]));
    
    // Verify we can decrypt
    let decrypted = aead::decrypt(&key, 0, &ciphertext, &aad).expect("decrypt");
    println!("\nDecrypted matches original: {}", decrypted == plaintext);
    
    // Now test with nonce=0 (which is what handshake uses)
    println!("\n=== Nonce format ===");
    println!("For counter=0, nonce should be 12 zero bytes");
    println!("WireGuard nonce format: [0,0,0,0, counter_le_bytes[8]]");
    
    // Test empty plaintext (like encrypted_nothing in response)
    let empty_ct = aead::encrypt(&key, 0, &[], &aad).expect("encrypt empty");
    println!("\nEmpty plaintext encryption: {} bytes (should be 16 = tag only)", empty_ct.len());
}
