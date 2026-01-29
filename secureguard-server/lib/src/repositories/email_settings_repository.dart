import 'dart:typed_data';

import '../database/database.dart';
import '../services/email_service.dart';

/// Email settings model for database storage
class EmailSettingsModel {
  final bool enabled;
  final String? smtpHost;
  final int smtpPort;
  final String? smtpUsername;
  final Uint8List? smtpPasswordEnc;
  final bool useSsl;
  final bool useStarttls;
  final String? fromEmail;
  final String fromName;
  final DateTime? lastTestAt;
  final bool? lastTestSuccess;
  final DateTime? updatedAt;

  EmailSettingsModel({
    required this.enabled,
    this.smtpHost,
    required this.smtpPort,
    this.smtpUsername,
    this.smtpPasswordEnc,
    required this.useSsl,
    required this.useStarttls,
    this.fromEmail,
    required this.fromName,
    this.lastTestAt,
    this.lastTestSuccess,
    this.updatedAt,
  });

  factory EmailSettingsModel.fromRow(Map<String, dynamic> row) {
    return EmailSettingsModel(
      enabled: row['enabled'] as bool? ?? false,
      smtpHost: row['smtp_host'] as String?,
      smtpPort: row['smtp_port'] as int? ?? 587,
      smtpUsername: row['smtp_username'] as String?,
      smtpPasswordEnc: row['smtp_password_enc'] as Uint8List?,
      useSsl: row['use_ssl'] as bool? ?? false,
      useStarttls: row['use_starttls'] as bool? ?? true,
      fromEmail: row['from_email'] as String?,
      fromName: row['from_name'] as String? ?? 'SecureGuard VPN',
      lastTestAt: row['last_test_at'] as DateTime?,
      lastTestSuccess: row['last_test_success'] as bool?,
      updatedAt: row['updated_at'] as DateTime?,
    );
  }

  /// Convert to JSON for API response (excludes encrypted password)
  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'smtp_host': smtpHost,
        'smtp_port': smtpPort,
        'smtp_username': smtpUsername,
        'has_password': smtpPasswordEnc != null && smtpPasswordEnc!.isNotEmpty,
        'use_ssl': useSsl,
        'use_starttls': useStarttls,
        'from_email': fromEmail,
        'from_name': fromName,
        'last_test_at': lastTestAt?.toIso8601String(),
        'last_test_success': lastTestSuccess,
        'updated_at': updatedAt?.toIso8601String(),
      };

  /// Convert to SmtpConfig (requires decrypted password)
  SmtpConfig toSmtpConfig({String? decryptedPassword}) {
    return SmtpConfig(
      enabled: enabled,
      host: smtpHost ?? '',
      port: smtpPort,
      username: smtpUsername,
      password: decryptedPassword,
      useSsl: useSsl,
      useStarttls: useStarttls,
      fromEmail: fromEmail ?? '',
      fromName: fromName,
    );
  }
}

/// Repository for email settings (singleton)
class EmailSettingsRepository {
  final Database db;

  EmailSettingsRepository(this.db);

  /// Get the email settings
  Future<EmailSettingsModel?> get() async {
    final result = await db.execute('SELECT * FROM email_settings WHERE id = 1');
    if (result.isEmpty) return null;
    return EmailSettingsModel.fromRow(result.first.toColumnMap());
  }

  /// Create or update email settings
  Future<EmailSettingsModel> upsert({
    required bool enabled,
    String? smtpHost,
    int smtpPort = 587,
    String? smtpUsername,
    Uint8List? smtpPasswordEnc,
    bool useSsl = false,
    bool useStarttls = true,
    String? fromEmail,
    String fromName = 'SecureGuard VPN',
  }) async {
    final result = await db.execute('''
      INSERT INTO email_settings (
        id, enabled, smtp_host, smtp_port, smtp_username, smtp_password_enc,
        use_ssl, use_starttls, from_email, from_name
      ) VALUES (
        1, @enabled, @smtp_host, @smtp_port, @smtp_username, @smtp_password_enc,
        @use_ssl, @use_starttls, @from_email, @from_name
      )
      ON CONFLICT (id) DO UPDATE SET
        enabled = EXCLUDED.enabled,
        smtp_host = EXCLUDED.smtp_host,
        smtp_port = EXCLUDED.smtp_port,
        smtp_username = EXCLUDED.smtp_username,
        smtp_password_enc = COALESCE(EXCLUDED.smtp_password_enc, email_settings.smtp_password_enc),
        use_ssl = EXCLUDED.use_ssl,
        use_starttls = EXCLUDED.use_starttls,
        from_email = EXCLUDED.from_email,
        from_name = EXCLUDED.from_name,
        updated_at = NOW()
      RETURNING *
    ''', {
      'enabled': enabled,
      'smtp_host': smtpHost,
      'smtp_port': smtpPort,
      'smtp_username': smtpUsername,
      'smtp_password_enc': smtpPasswordEnc,
      'use_ssl': useSsl,
      'use_starttls': useStarttls,
      'from_email': fromEmail,
      'from_name': fromName,
    });

    return EmailSettingsModel.fromRow(result.first.toColumnMap());
  }

  /// Update last test result
  Future<void> updateTestResult(bool success) async {
    await db.execute('''
      UPDATE email_settings
      SET last_test_at = NOW(), last_test_success = @success, updated_at = NOW()
      WHERE id = 1
    ''', {'success': success});
  }

  /// Check if email settings exist
  Future<bool> exists() async {
    final result = await db.execute(
      'SELECT COUNT(*) FROM email_settings WHERE id = 1',
    );
    return (result.first[0] as int) > 0;
  }

  /// Get encrypted password (for internal use only)
  Future<Uint8List?> getEncryptedPassword() async {
    final result = await db.execute(
      'SELECT smtp_password_enc FROM email_settings WHERE id = 1',
    );
    if (result.isEmpty) return null;
    return result.first[0] as Uint8List?;
  }
}
