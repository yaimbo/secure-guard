import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../database/database.dart';
import '../models/api_key.dart';

/// Repository for API key data access
class ApiKeyRepository {
  final Database db;
  final _random = Random.secure();

  ApiKeyRepository(this.db);

  /// Generate a new API key (returns the raw key - only shown once)
  String generateKey() {
    // Format: sg_live_<32 random chars>
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final keyPart = List.generate(32, (_) => chars[_random.nextInt(chars.length)]).join();
    return 'sg_live_$keyPart';
  }

  /// Hash a key for storage
  String hashKey(String key) {
    return sha256.convert(utf8.encode(key)).toString();
  }

  /// Get the prefix for display (first 12 chars + ...)
  String getKeyPrefix(String key) {
    if (key.length <= 12) return key;
    return '${key.substring(0, 12)}...';
  }

  /// Create a new API key
  Future<(ApiKey, String)> create({
    required String name,
    required String permissions,
    required String createdBy,
    DateTime? expiresAt,
  }) async {
    final rawKey = generateKey();
    final keyHash = hashKey(rawKey);
    final keyPrefix = getKeyPrefix(rawKey);

    final result = await db.execute('''
      INSERT INTO api_keys (name, key_hash, key_prefix, permissions, created_by, expires_at)
      VALUES (@name, @key_hash, @key_prefix, @permissions, @created_by, @expires_at)
      RETURNING *
    ''', {
      'name': name,
      'key_hash': keyHash,
      'key_prefix': keyPrefix,
      'permissions': permissions,
      'created_by': createdBy,
      'expires_at': expiresAt,
    });

    final apiKey = ApiKey.fromRow(result.first.toColumnMap());
    return (apiKey, rawKey); // Return both the model and raw key
  }

  /// Find an API key by its hash
  Future<ApiKey?> getByHash(String keyHash) async {
    final result = await db.execute(
      'SELECT * FROM api_keys WHERE key_hash = @hash AND is_active = true',
      {'hash': keyHash},
    );

    if (result.isEmpty) return null;
    return ApiKey.fromRow(result.first.toColumnMap());
  }

  /// Find an API key by raw key (hashes it first)
  Future<ApiKey?> getByKey(String rawKey) async {
    return getByHash(hashKey(rawKey));
  }

  /// Get API key by ID
  Future<ApiKey?> getById(String id) async {
    final result = await db.execute(
      'SELECT * FROM api_keys WHERE id = @id',
      {'id': id},
    );

    if (result.isEmpty) return null;
    return ApiKey.fromRow(result.first.toColumnMap());
  }

  /// List all API keys
  Future<List<ApiKey>> list() async {
    final result = await db.execute(
      'SELECT * FROM api_keys ORDER BY created_at DESC',
    );
    return result.map((row) => ApiKey.fromRow(row.toColumnMap())).toList();
  }

  /// List active API keys only
  Future<List<ApiKey>> listActive() async {
    final result = await db.execute(
      'SELECT * FROM api_keys WHERE is_active = true ORDER BY created_at DESC',
    );
    return result.map((row) => ApiKey.fromRow(row.toColumnMap())).toList();
  }

  /// Update last used timestamp
  Future<void> updateLastUsed(String id) async {
    await db.execute(
      'UPDATE api_keys SET last_used_at = NOW() WHERE id = @id',
      {'id': id},
    );
  }

  /// Revoke an API key
  Future<bool> revoke(String id) async {
    final result = await db.execute(
      'UPDATE api_keys SET is_active = false WHERE id = @id',
      {'id': id},
    );
    return result.affectedRows > 0;
  }

  /// Delete an API key permanently
  Future<bool> delete(String id) async {
    final result = await db.execute(
      'DELETE FROM api_keys WHERE id = @id',
      {'id': id},
    );
    return result.affectedRows > 0;
  }
}
