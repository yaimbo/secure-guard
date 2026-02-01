/// API key model
class ApiKey {
  final String id;
  final String name;
  final String keyHash;
  final String keyPrefix;
  final String permissions; // read, write, admin
  final String? createdBy;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final bool isActive;

  ApiKey({
    required this.id,
    required this.name,
    required this.keyHash,
    required this.keyPrefix,
    required this.permissions,
    this.createdBy,
    required this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
    required this.isActive,
  });

  factory ApiKey.fromRow(Map<String, dynamic> row) {
    return ApiKey(
      id: row['id'] as String,
      name: row['name'] as String,
      keyHash: row['key_hash'] as String,
      keyPrefix: row['key_prefix'] as String,
      permissions: row['permissions'] as String? ?? 'read',
      createdBy: row['created_by'] as String?,
      createdAt: row['created_at'] as DateTime,
      lastUsedAt: row['last_used_at'] as DateTime?,
      expiresAt: row['expires_at'] as DateTime?,
      isActive: row['is_active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'key_prefix': keyPrefix,
        'permissions': permissions,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        'last_used_at': lastUsedAt?.toIso8601String(),
        'expires_at': expiresAt?.toIso8601String(),
        'is_active': isActive,
      };

  /// Check if the key is expired
  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  /// Check if the key is valid (active and not expired)
  bool get isValid => isActive && !isExpired;
}
