import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../repositories/admin_repository.dart';
import '../../repositories/api_key_repository.dart';
import '../../repositories/email_settings_repository.dart';
import '../../repositories/log_repository.dart';
import '../../repositories/server_config_repository.dart';
import '../../services/email_service.dart';
import '../../services/email_queue_service.dart';
import '../../services/key_service.dart';

/// Settings routes (admin only)
class SettingsRoutes {
  final AdminRepository adminRepo;
  final ApiKeyRepository apiKeyRepo;
  final EmailSettingsRepository emailSettingsRepo;
  final ServerConfigRepository serverConfigRepo;
  final EmailService emailService;
  final EmailQueueService emailQueueService;
  final KeyService keyService;
  final LogRepository logRepo;
  final _log = Logger('SettingsRoutes');

  SettingsRoutes({
    required this.adminRepo,
    required this.apiKeyRepo,
    required this.emailSettingsRepo,
    required this.serverConfigRepo,
    required this.emailService,
    required this.emailQueueService,
    required this.keyService,
    required this.logRepo,
  });

  Router get router {
    final router = Router();

    // VPN server settings
    router.get('/vpn', _getVpnSettings);
    router.put('/vpn', _updateVpnSettings);

    // Admin user management
    router.get('/admins', _listAdmins);
    router.post('/admins', _createAdmin);
    router.delete('/admins/<id>', _deleteAdmin);

    // API key management
    router.get('/api-keys', _listApiKeys);
    router.post('/api-keys', _createApiKey);
    router.delete('/api-keys/<id>', _revokeApiKey);

    // Email settings
    router.get('/email', _getEmailSettings);
    router.put('/email', _updateEmailSettings);
    router.post('/email/test', _testEmailSettings);

    // Email queue stats (admin monitoring)
    router.get('/email/queue/stats', _getEmailQueueStats);

    return router;
  }

  // ============================================================
  // API Key Management
  // ============================================================

  /// List all API keys (without revealing the actual keys)
  Future<Response> _listApiKeys(Request request) async {
    try {
      final keys = await apiKeyRepo.list();

      return Response.ok(
        jsonEncode({
          'data': keys.map((key) => key.toJson()).toList(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, stackTrace) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to list API keys: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Create a new API key
  Future<Response> _createApiKey(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final actorId = request.context['adminId'] as String;

      final name = data['name'] as String?;
      final permissions = data['permissions'] as String? ?? 'read';

      if (name == null || name.isEmpty) {
        return Response(400,
            body: jsonEncode({'error': 'Name is required'}),
            headers: {'content-type': 'application/json'});
      }

      if (!['read', 'write', 'admin'].contains(permissions)) {
        return Response(400,
            body: jsonEncode({'error': 'Invalid permissions. Must be read, write, or admin'}),
            headers: {'content-type': 'application/json'});
      }

      final (apiKey, rawKey) = await apiKeyRepo.create(
        name: name,
        permissions: permissions,
        createdBy: actorId,
      );

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: actorId,
        eventType: 'API_KEY_CREATED',
        resourceType: 'api_key',
        resourceId: apiKey.id,
        resourceName: name,
        details: {'permissions': permissions},
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      // Return the raw key - this is the only time it's visible
      return Response.ok(
        jsonEncode({
          ...apiKey.toJson(),
          'key': rawKey, // Only returned on creation
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, stackTrace) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to create API key: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Revoke an API key
  Future<Response> _revokeApiKey(Request request, String id) async {
    try {
      final actorId = request.context['adminId'] as String;

      // Get key to check existence and for audit log
      final key = await apiKeyRepo.getById(id);
      if (key == null) {
        return Response(404,
            body: jsonEncode({'error': 'API key not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Revoke the key
      await apiKeyRepo.revoke(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: actorId,
        eventType: 'API_KEY_REVOKED',
        resourceType: 'api_key',
        resourceId: id,
        resourceName: key.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(204);
    } catch (e, stackTrace) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to revoke API key: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  // ============================================================
  // Admin User Management
  // ============================================================

  /// List all admin users
  Future<Response> _listAdmins(Request request) async {
    try {
      final admins = await adminRepo.list();

      return Response.ok(
        jsonEncode({
          'data': admins.map((admin) => {
            'id': admin.id,
            'email': admin.email,
            'role': admin.role,
            'is_active': admin.isActive,
            'last_login_at': admin.lastLoginAt?.toIso8601String(),
            'created_at': admin.createdAt.toIso8601String(),
            'sso_provider': admin.ssoProvider,
          }).toList(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, stackTrace) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to list admins: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Create a new admin user
  Future<Response> _createAdmin(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final actorId = request.context['adminId'] as String;

      final email = data['email'] as String?;
      final password = data['password'] as String?;
      final role = data['role'] as String? ?? 'admin';

      if (email == null || email.isEmpty) {
        return Response(400,
            body: jsonEncode({'error': 'Email is required'}),
            headers: {'content-type': 'application/json'});
      }

      if (password == null || password.length < 8) {
        return Response(400,
            body: jsonEncode({'error': 'Password must be at least 8 characters'}),
            headers: {'content-type': 'application/json'});
      }

      // Check if email already exists
      final existing = await adminRepo.getByEmail(email);
      if (existing != null) {
        return Response(409,
            body: jsonEncode({'error': 'Email already in use'}),
            headers: {'content-type': 'application/json'});
      }

      // Hash password
      final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());

      // Create admin
      final admin = await adminRepo.create(
        email: email,
        passwordHash: passwordHash,
        role: role,
      );

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: actorId,
        eventType: 'ADMIN_CREATED',
        resourceType: 'admin',
        resourceId: admin.id,
        resourceName: email,
        details: {'role': role},
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode({
          'id': admin.id,
          'email': admin.email,
          'role': admin.role,
          'is_active': admin.isActive,
          'created_at': admin.createdAt.toIso8601String(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, stackTrace) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to create admin: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Delete an admin user
  Future<Response> _deleteAdmin(Request request, String id) async {
    try {
      final actorId = request.context['adminId'] as String;

      // Prevent self-deletion
      if (actorId == id) {
        return Response(400,
            body: jsonEncode({'error': 'Cannot delete your own account'}),
            headers: {'content-type': 'application/json'});
      }

      // Get admin to check existence and for audit log
      final admin = await adminRepo.getById(id);
      if (admin == null) {
        return Response(404,
            body: jsonEncode({'error': 'Admin not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Delete admin
      await adminRepo.delete(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: actorId,
        eventType: 'ADMIN_DELETED',
        resourceType: 'admin',
        resourceId: id,
        resourceName: admin.email,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(204);
    } catch (e, stackTrace) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to delete admin: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  // ============================================================
  // VPN Server Settings
  // ============================================================

  /// Get current VPN server configuration
  Future<Response> _getVpnSettings(Request request) async {
    try {
      final config = await serverConfigRepo.get();

      if (config == null) {
        return Response.ok(
          jsonEncode({
            'configured': false,
            'endpoint': 'localhost:51820',
            'listen_port': 51820,
            'ip_subnet': '10.0.0.0/24',
            'dns_servers': ['8.8.8.8', '8.8.4.4'],
            'mtu': 1420,
            'public_key': null,
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      return Response.ok(
        jsonEncode({
          'configured': true,
          ...config.toJson(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, stackTrace) {
      _log.severe('Failed to get VPN settings', e, stackTrace);
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get VPN settings: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Create or update VPN server configuration
  Future<Response> _updateVpnSettings(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final adminId = request.context['adminId'] as String;

      final endpoint = data['endpoint'] as String?;
      final listenPort = data['listen_port'] as int? ?? 51820;
      final ipSubnet = data['ip_subnet'] as String? ?? '10.0.0.0/24';
      final dnsServers = (data['dns_servers'] as List<dynamic>?)?.cast<String>();
      final mtu = data['mtu'] as int? ?? 1420;

      if (endpoint == null || endpoint.isEmpty) {
        return Response(400,
            body: jsonEncode({'error': 'endpoint is required (e.g., vpn.example.com:51820)'}),
            headers: {'content-type': 'application/json'});
      }

      // Check if we need to generate new keys or keep existing ones
      final existingConfig = await serverConfigRepo.get();
      String privateKeyEnc;
      String publicKey;

      if (existingConfig != null && data['regenerate_keys'] != true) {
        // Keep existing keys
        privateKeyEnc = existingConfig.privateKeyEnc;
        publicKey = existingConfig.publicKey;
      } else {
        // Generate new server keys
        final (privateKey, pubKey) = await keyService.generateKeyPair();
        privateKeyEnc = await keyService.encryptPrivateKey(privateKey);
        publicKey = pubKey;
      }

      final config = await serverConfigRepo.upsert(
        privateKeyEnc: privateKeyEnc,
        publicKey: publicKey,
        endpoint: endpoint,
        listenPort: listenPort,
        ipSubnet: ipSubnet,
        dnsServers: dnsServers,
        mtu: mtu,
      );

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'VPN_SETTINGS_UPDATED',
        resourceType: 'settings',
        resourceId: 'vpn',
        details: {
          'endpoint': endpoint,
          'ip_subnet': ipSubnet,
          'keys_regenerated': existingConfig == null || data['regenerate_keys'] == true,
        },
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode({
          'configured': true,
          ...config.toJson(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e, stackTrace) {
      _log.severe('Failed to update VPN settings', e, stackTrace);
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update VPN settings: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  // ============================================================
  // Email Settings
  // ============================================================

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
    } catch (e, stackTrace) {
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
    } catch (e, stackTrace) {
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
      } catch (e, stackTrace) {
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
    } catch (e, stackTrace) {
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
    } catch (e, stackTrace) {
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
