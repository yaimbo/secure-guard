import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Service for WireGuard key generation and management
class KeyService {
  final String? encryptionKey;

  KeyService({this.encryptionKey});

  /// Generate a new X25519 key pair
  /// Returns (privateKey, publicKey) as base64-encoded strings
  Future<(String, String)> generateKeyPair() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();

    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    final privateKeyBase64 = base64Encode(Uint8List.fromList(privateKeyBytes));
    final publicKeyBase64 = base64Encode(Uint8List.fromList(publicKey.bytes));

    return (privateKeyBase64, publicKeyBase64);
  }

  /// Generate a preshared key (32 random bytes)
  Future<String> generatePresharedKey() async {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (i) => random.nextInt(256));
    return base64Encode(Uint8List.fromList(bytes));
  }

  /// Derive public key from private key
  Future<String> derivePublicKey(String privateKeyBase64) async {
    final algorithm = X25519();
    final privateKeyBytes = base64Decode(privateKeyBase64);

    final keyPair = await algorithm.newKeyPairFromSeed(privateKeyBytes);
    final publicKey = await keyPair.extractPublicKey();

    return base64Encode(Uint8List.fromList(publicKey.bytes));
  }

  /// Encrypt a private key for storage at rest
  /// Uses AES-256-GCM with the configured encryption key
  Future<String> encryptPrivateKey(String privateKeyBase64) async {
    if (encryptionKey == null || encryptionKey!.isEmpty) {
      // No encryption configured - return as-is (development mode)
      return privateKeyBase64;
    }

    final algorithm = AesGcm.with256bits();
    final secretKey = SecretKey(base64Decode(encryptionKey!));
    final nonce = algorithm.newNonce();

    final plaintext = base64Decode(privateKeyBase64);
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // Combine nonce + ciphertext + mac for storage
    final combined = Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return base64Encode(combined);
  }

  /// Decrypt a private key from storage
  Future<String> decryptPrivateKey(String encryptedBase64) async {
    if (encryptionKey == null || encryptionKey!.isEmpty) {
      // No encryption configured - return as-is (development mode)
      return encryptedBase64;
    }

    final algorithm = AesGcm.with256bits();
    final secretKey = SecretKey(base64Decode(encryptionKey!));

    final combined = base64Decode(encryptedBase64);

    // Extract nonce (12 bytes), ciphertext, and mac (16 bytes)
    final nonce = combined.sublist(0, 12);
    final cipherText = combined.sublist(12, combined.length - 16);
    final mac = Mac(combined.sublist(combined.length - 16));

    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final plaintext = await algorithm.decrypt(secretBox, secretKey: secretKey);

    return base64Encode(Uint8List.fromList(plaintext));
  }

  /// Validate a WireGuard key (must be 32 bytes when decoded)
  bool validateKey(String keyBase64) {
    try {
      final bytes = base64Decode(keyBase64);
      return bytes.length == 32;
    } catch (e) {
      return false;
    }
  }
}
