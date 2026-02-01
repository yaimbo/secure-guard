import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import 'email_templates.dart';

/// Exception thrown when email is not configured
class EmailNotConfiguredException implements Exception {
  final String message;
  EmailNotConfiguredException([this.message = 'Email service is not configured']);

  @override
  String toString() => 'EmailNotConfiguredException: $message';
}

/// SMTP configuration model
class SmtpConfig {
  final bool enabled;
  final String host;
  final int port;
  final String? username;
  final String? password;
  final bool useSsl;
  final bool useStarttls;
  final String fromEmail;
  final String fromName;

  SmtpConfig({
    required this.enabled,
    required this.host,
    required this.port,
    this.username,
    this.password,
    required this.useSsl,
    required this.useStarttls,
    required this.fromEmail,
    required this.fromName,
  });

  factory SmtpConfig.fromJson(Map<String, dynamic> json) {
    return SmtpConfig(
      enabled: json['enabled'] as bool? ?? false,
      host: json['smtp_host'] as String? ?? '',
      port: json['smtp_port'] as int? ?? 587,
      username: json['smtp_username'] as String?,
      password: json['smtp_password'] as String?,
      useSsl: json['use_ssl'] as bool? ?? false,
      useStarttls: json['use_starttls'] as bool? ?? true,
      fromEmail: json['from_email'] as String? ?? '',
      fromName: json['from_name'] as String? ?? 'MinnowVPN',
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'smtp_host': host,
        'smtp_port': port,
        'smtp_username': username,
        // password is not included for security
        'use_ssl': useSsl,
        'use_starttls': useStarttls,
        'from_email': fromEmail,
        'from_name': fromName,
      };
}

/// Service for sending emails via SMTP
class EmailService {
  SmtpServer? _smtpServer;
  SmtpConfig? _config;
  final String? encryptionKey;

  EmailService({this.encryptionKey});

  /// Check if email service is configured and enabled
  bool get isConfigured => _config?.enabled ?? false;

  /// Configure the SMTP server
  Future<void> configure(SmtpConfig config) async {
    _config = config;

    if (!config.enabled || config.host.isEmpty) {
      _smtpServer = null;
      return;
    }

    _smtpServer = SmtpServer(
      config.host,
      port: config.port,
      ssl: config.useSsl,
      ignoreBadCertificate: false,
      username: config.username,
      password: config.password,
    );
  }

  /// Send an enrollment email to a user
  Future<void> sendEnrollmentEmail({
    required String toEmail,
    required String toName,
    required String enrollmentCode,
    required String deepLink,
    required String serverDomain,
    required String expiresIn,
  }) async {
    if (!isConfigured || _smtpServer == null || _config == null) {
      throw EmailNotConfiguredException();
    }

    final htmlBody = EmailTemplates.enrollmentHtml(
      name: toName,
      code: enrollmentCode,
      deepLink: deepLink,
      serverDomain: serverDomain,
      expiresIn: expiresIn,
    );

    final textBody = EmailTemplates.enrollmentText(
      name: toName,
      code: enrollmentCode,
      deepLink: deepLink,
      serverDomain: serverDomain,
      expiresIn: expiresIn,
    );

    final message = Message()
      ..from = Address(_config!.fromEmail, _config!.fromName)
      ..recipients.add(toEmail)
      ..subject = 'Your MinnowVPN Access'
      ..html = htmlBody
      ..text = textBody;

    await send(message, _smtpServer!);
  }

  /// Send a test email to verify SMTP configuration
  Future<void> sendTestEmail(String toEmail) async {
    if (!isConfigured || _smtpServer == null || _config == null) {
      throw EmailNotConfiguredException();
    }

    final message = Message()
      ..from = Address(_config!.fromEmail, _config!.fromName)
      ..recipients.add(toEmail)
      ..subject = 'MinnowVPN - Test Email'
      ..html = EmailTemplates.testEmailHtml()
      ..text = EmailTemplates.testEmailText();

    await send(message, _smtpServer!);
  }

  /// Encrypt a password for storage (returns base64 string)
  Future<String> encryptPassword(String password) async {
    if (encryptionKey == null || encryptionKey!.isEmpty) {
      // No encryption configured - store as base64-encoded UTF-8 bytes
      return base64Encode(utf8.encode(password));
    }

    final algorithm = AesGcm.with256bits();
    final secretKey = SecretKey(base64Decode(encryptionKey!));
    final nonce = algorithm.newNonce();

    final plaintext = utf8.encode(password);
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    // Combine nonce + ciphertext + mac and return as base64
    final combined = Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    return base64Encode(combined);
  }

  /// Decrypt a password from storage (accepts base64 string)
  Future<String> decryptPassword(String encryptedBase64) async {
    final encrypted = base64Decode(encryptedBase64);

    if (encryptionKey == null || encryptionKey!.isEmpty) {
      // No encryption configured - decode UTF-8 directly
      return utf8.decode(encrypted);
    }

    final algorithm = AesGcm.with256bits();
    final secretKey = SecretKey(base64Decode(encryptionKey!));

    // Extract nonce (12 bytes), ciphertext, and mac (16 bytes)
    final nonce = encrypted.sublist(0, 12);
    final cipherText = encrypted.sublist(12, encrypted.length - 16);
    final mac = Mac(encrypted.sublist(encrypted.length - 16));

    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final plaintext = await algorithm.decrypt(secretBox, secretKey: secretKey);

    return utf8.decode(plaintext);
  }
}
