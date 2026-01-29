import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../repositories/email_settings_repository.dart';
import '../../repositories/log_repository.dart';
import '../../services/email_service.dart';
import '../../services/email_queue_service.dart';

/// Settings routes (admin only)
class SettingsRoutes {
  final EmailSettingsRepository emailSettingsRepo;
  final EmailService emailService;
  final EmailQueueService emailQueueService;
  final LogRepository logRepo;

  SettingsRoutes({
    required this.emailSettingsRepo,
    required this.emailService,
    required this.emailQueueService,
    required this.logRepo,
  });

  Router get router {
    final router = Router();

    // Email settings
    router.get('/email', _getEmailSettings);
    router.put('/email', _updateEmailSettings);
    router.post('/email/test', _testEmailSettings);

    // Email queue stats (admin monitoring)
    router.get('/email/queue/stats', _getEmailQueueStats);

    return router;
  }

  /// Get current email settings (without password)
  Future<Response> _getEmailSettings(Request request) async {
    try {
      final settings = await emailSettingsRepo.get();

      if (settings == null) {
        // Return default settings if none configured
        return Response.ok(
          jsonEncode({
            'enabled': false,
            'smtp_host': null,
            'smtp_port': 587,
            'smtp_username': null,
            'has_password': false,
            'use_ssl': false,
            'use_starttls': true,
            'from_email': null,
            'from_name': 'SecureGuard VPN',
            'last_test_at': null,
            'last_test_success': null,
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get email settings: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Update email settings
  Future<Response> _updateEmailSettings(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final adminId = request.context['adminId'] as String;

      // Encrypt password if provided
      final password = data['smtp_password'] as String?;
      final passwordEnc = password != null && password.isNotEmpty
          ? await emailService.encryptPassword(password)
          : null;

      final settings = await emailSettingsRepo.upsert(
        enabled: data['enabled'] as bool? ?? false,
        smtpHost: data['smtp_host'] as String?,
        smtpPort: data['smtp_port'] as int? ?? 587,
        smtpUsername: data['smtp_username'] as String?,
        smtpPasswordEnc: passwordEnc,
        useSsl: data['use_ssl'] as bool? ?? false,
        useStarttls: data['use_starttls'] as bool? ?? true,
        fromEmail: data['from_email'] as String?,
        fromName: data['from_name'] as String? ?? 'SecureGuard VPN',
      );

      // Reconfigure the email service with new settings
      await _reconfigureEmailService(settings);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'EMAIL_SETTINGS_UPDATED',
        resourceType: 'settings',
        resourceId: 'email',
        details: {
          'enabled': settings.enabled,
          'smtp_host': settings.smtpHost,
        },
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update email settings: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Test email settings by sending a test email
  Future<Response> _testEmailSettings(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final adminId = request.context['adminId'] as String;
      final testRecipient = data['test_recipient'] as String?;

      if (testRecipient == null || testRecipient.isEmpty) {
        return Response(400,
            body: jsonEncode({'error': 'test_recipient is required'}),
            headers: {'content-type': 'application/json'});
      }

      // Check if email is configured
      if (!emailService.isConfigured) {
        await emailSettingsRepo.updateTestResult(false);
        return Response(400,
            body: jsonEncode({
              'error': 'email_not_configured',
              'message': 'Email service is not configured. Please save settings first.',
            }),
            headers: {'content-type': 'application/json'});
      }

      try {
        // Send test email
        await emailService.sendTestEmail(testRecipient);

        // Update test result
        await emailSettingsRepo.updateTestResult(true);

        // Audit log
        await logRepo.auditLog(
          actorType: 'admin',
          actorId: adminId,
          eventType: 'EMAIL_TEST_SUCCESS',
          resourceType: 'settings',
          resourceId: 'email',
          details: {'test_recipient': testRecipient},
          ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
        );

        return Response.ok(
          jsonEncode({
            'success': true,
            'message': 'Test email sent successfully',
          }),
          headers: {'content-type': 'application/json'},
        );
      } on EmailNotConfiguredException {
        await emailSettingsRepo.updateTestResult(false);
        return Response(400,
            body: jsonEncode({
              'success': false,
              'error': 'email_not_configured',
              'message': 'Email service is not configured',
            }),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        await emailSettingsRepo.updateTestResult(false);

        // Audit log
        await logRepo.auditLog(
          actorType: 'admin',
          actorId: adminId,
          eventType: 'EMAIL_TEST_FAILED',
          resourceType: 'settings',
          resourceId: 'email',
          details: {'test_recipient': testRecipient, 'error': e.toString()},
          ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
        );

        return Response(400,
            body: jsonEncode({
              'success': false,
              'error': 'send_failed',
              'message': 'Failed to send test email: $e',
            }),
            headers: {'content-type': 'application/json'});
      }
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to test email settings: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Get email queue statistics
  Future<Response> _getEmailQueueStats(Request request) async {
    try {
      final stats = await emailQueueService.getStats();

      return Response.ok(
        jsonEncode(stats),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get queue stats: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Reconfigure email service after settings update
  Future<void> _reconfigureEmailService(EmailSettingsModel settings) async {
    // Get the encrypted password from DB and decrypt it
    String? password;
    if (settings.smtpPasswordEnc != null && settings.smtpPasswordEnc!.isNotEmpty) {
      password = await emailService.decryptPassword(settings.smtpPasswordEnc!);
    }

    final config = settings.toSmtpConfig(decryptedPassword: password);
    await emailService.configure(config);
  }
}
