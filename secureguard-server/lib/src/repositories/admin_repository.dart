import '../database/database.dart';
import '../models/admin.dart';

/// Repository for admin user data access
class AdminRepository {
  final Database db;

  AdminRepository(this.db);

  /// Get admin by ID
  Future<Admin?> getById(String id) async {
    final result = await db.execute(
      'SELECT * FROM admins WHERE id = @id',
      {'id': id},
    );

    if (result.isEmpty) return null;
    return Admin.fromRow(result.first.toColumnMap());
  }

  /// Get admin by email
  Future<Admin?> getByEmail(String email) async {
    final result = await db.execute(
      'SELECT * FROM admins WHERE email = @email',
      {'email': email.toLowerCase()},
    );

    if (result.isEmpty) return null;
    return Admin.fromRow(result.first.toColumnMap());
  }

  /// Get admin by SSO subject
  Future<Admin?> getBySsoSubject(String provider, String subject) async {
    final result = await db.execute(
      'SELECT * FROM admins WHERE sso_provider = @provider AND sso_subject = @subject',
      {'provider': provider, 'subject': subject},
    );

    if (result.isEmpty) return null;
    return Admin.fromRow(result.first.toColumnMap());
  }

  /// Create a new admin
  Future<Admin> create({
    required String email,
    String? passwordHash,
    String role = 'admin',
    String? ssoProvider,
    String? ssoSubject,
  }) async {
    final result = await db.execute('''
      INSERT INTO admins (email, password_hash, role, sso_provider, sso_subject)
      VALUES (@email, @password_hash, @role, @sso_provider, @sso_subject)
      RETURNING *
    ''', {
      'email': email.toLowerCase(),
      'password_hash': passwordHash,
      'role': role,
      'sso_provider': ssoProvider,
      'sso_subject': ssoSubject,
    });

    return Admin.fromRow(result.first.toColumnMap());
  }

  /// Update admin password
  Future<Admin?> updatePassword(String id, String passwordHash) async {
    final result = await db.execute('''
      UPDATE admins SET password_hash = @hash WHERE id = @id RETURNING *
    ''', {'id': id, 'hash': passwordHash});

    if (result.isEmpty) return null;
    return Admin.fromRow(result.first.toColumnMap());
  }

  /// Update last login timestamp
  Future<void> updateLastLogin(String id) async {
    await db.execute('''
      UPDATE admins SET last_login_at = NOW() WHERE id = @id
    ''', {'id': id});
  }

  /// Set admin active status
  Future<Admin?> setActive(String id, bool isActive) async {
    final result = await db.execute('''
      UPDATE admins SET is_active = @active WHERE id = @id RETURNING *
    ''', {'id': id, 'active': isActive});

    if (result.isEmpty) return null;
    return Admin.fromRow(result.first.toColumnMap());
  }

  /// List all admins
  Future<List<Admin>> list() async {
    final result = await db.execute(
      'SELECT * FROM admins ORDER BY created_at DESC',
    );
    return result.map((row) => Admin.fromRow(row.toColumnMap())).toList();
  }

  /// Delete an admin
  Future<bool> delete(String id) async {
    final result = await db.execute(
      'DELETE FROM admins WHERE id = @id',
      {'id': id},
    );
    return result.affectedRows > 0;
  }

  /// Check if any admin exists (for initial setup)
  Future<bool> hasAnyAdmin() async {
    final result = await db.execute('SELECT EXISTS(SELECT 1 FROM admins)');
    return result.first[0] as bool;
  }
}
