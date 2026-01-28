//! Verify TAI64N timestamp format

use tai64::Tai64N;

fn main() {
    println!("=== TAI64N Timestamp Verification ===\n");

    let now = Tai64N::now();
    let bytes = now.to_bytes();

    println!("Current TAI64N timestamp:");
    println!("  Raw bytes: {:02x?}", bytes);
    println!("  Hex: {}", hex::encode(&bytes));
    println!("  Length: {} bytes", bytes.len());

    // TAI64N structure:
    // - 8 bytes: seconds since epoch + 2^62 offset (big-endian)
    // - 4 bytes: nanoseconds (big-endian)

    let seconds_bytes: [u8; 8] = bytes[0..8].try_into().unwrap();
    let nanos_bytes: [u8; 4] = bytes[8..12].try_into().unwrap();

    let seconds = u64::from_be_bytes(seconds_bytes);
    let nanos = u32::from_be_bytes(nanos_bytes);

    println!("\nParsed:");
    println!("  Seconds (raw): 0x{:016x}", seconds);
    println!("  Seconds (minus 2^62): {}", seconds - (1u64 << 62));
    println!("  Nanoseconds: {}", nanos);

    // Verify we can round-trip
    let parsed = Tai64N::from_slice(&bytes).expect("valid timestamp");
    assert_eq!(parsed.to_bytes(), bytes);
    println!("\nRound-trip verification: OK");
}
