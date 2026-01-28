/// Admin user model
class Admin {
  final String id;
  final String email;
  final String? passwordHash;
  final String role;
  final String? ssoProvider;
  final String? ssoSubject;
  final bool isActive;
  final DateTime? lastLoginAt;
  final DateTime createdAt;

  Admin({
    required this.id,
    required this.email,
    this.passwordHash,
    required this.role,
    this.ssoProvider,
    this.ssoSubject,
    required this.isActive,
    this.lastLoginAt,
    required this.createdAt,
  });

  factory Admin.fromRow(Map<String, dynamic> row) {
    return Admin(
      id: row['id'] as String,
      email: row['email'] as String,
      passwordHash: row['password_hash'] as String?,
      role: row['role'] as String,
      ssoProvider: row['sso_provider'] as String?,
      ssoSubject: row['sso_subject'] as String?,
      isActive: row['is_active'] as bool,
      lastLoginAt: row['last_login_at'] as DateTime?,
      createdAt: row['created_at'] as DateTime,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'role': role,
      'sso_provider': ssoProvider,
      'is_active': isActive,
      'last_login_at': lastLoginAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }
}
