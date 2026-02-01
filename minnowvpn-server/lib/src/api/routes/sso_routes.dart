import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../repositories/admin_repository.dart';
import '../../repositories/client_repository.dart';
import '../../repositories/log_repository.dart';
import '../../services/sso/sso_manager.dart';
import '../../services/sso/sso_provider.dart';

/// SSO authentication routes
class SSORoutes {
  final SSOManager ssoManager;
  final AdminRepository adminRepo;
  final ClientRepository clientRepo;
  final LogRepository logRepo;
  final String jwtSecret;

  SSORoutes({
    required this.ssoManager,
    required this.adminRepo,
    required this.clientRepo,
    required this.logRepo,
    required this.jwtSecret,
  });

  /// Public routes (no auth required)
  Router get router {
    final router = Router();

    // List available SSO providers
    router.get('/providers', _listProviders);

    // Authorization code flow
    router.get('/<provider>/authorize', _startAuthorization);
    router.get('/<provider>/callback', _handleCallback);

    // Device code flow (for desktop/CLI apps)
    router.post('/<provider>/device', _startDeviceFlow);
    router.post('/<provider>/device/poll', _pollDeviceFlow);

    return router;
  }

  /// Admin routes for SSO configuration
  Router get adminRouter {
    final router = Router();

    router.get('/configs', _listConfigs);
    router.post('/configs', _saveConfig);
    router.delete('/configs/<provider>', _deleteConfig);

    return router;
  }

  /// List available SSO providers
  Future<Response> _listProviders(Request request) async {
    final providers = ssoManager.enabledProviders.map((p) => {
          'id': p.providerId,
          'name': p.displayName,
          'enabled': p.isEnabled,
        }).toList();

    return Response.ok(
      jsonEncode({'providers': providers}),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Start authorization code flow
  /// GET /api/v1/auth/sso/:provider/authorize?redirect_uri=...
  Future<Response> _startAuthorization(Request request, String provider) async {
    try {
      final redirectUri = request.url.queryParameters['redirect_uri'];
      if (redirectUri == null) {
        return Response(400,
            body: jsonEncode({'error': 'redirect_uri is required'}),
            headers: {'content-type': 'application/json'});
      }

      final authUrl = await ssoManager.startAuthorizationFlow(
        providerId: provider,
        redirectUri: redirectUri,
      );

      return Response.ok(
        jsonEncode({'authorization_url': authUrl.toString()}),
        headers: {'content-type': 'application/json'},
      );
    } on SSOException catch (e) {
      return Response(400,
          body: jsonEncode({'error': e.message}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to start authorization: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Handle OAuth callback
  /// GET /api/v1/auth/sso/:provider/callback?code=...&state=...
  Future<Response> _handleCallback(Request request, String provider) async {
    try {
      final code = request.url.queryParameters['code'];
      final state = request.url.queryParameters['state'];
      final error = request.url.queryParameters['error'];

      if (error != null) {
        final errorDesc = request.url.queryParameters['error_description'];
        return Response(400,
            body: jsonEncode({
              'error': error,
              'error_description': errorDesc,
            }),
            headers: {'content-type': 'application/json'});
      }

      if (code == null || state == null) {
        return Response(400,
            body: jsonEncode({'error': 'Missing code or state parameter'}),
            headers: {'content-type': 'application/json'});
      }

      // Handle the callback
      final result = await ssoManager.handleCallback(
        state: state,
        code: code,
      );

      // Find or create admin user based on SSO identity
      final tokens = await _handleSSOLogin(
        result: result,
        request: request,
      );

      return Response.ok(
        jsonEncode(tokens),
        headers: {'content-type': 'application/json'},
      );
    } on SSOException catch (e) {
      return Response(400,
          body: jsonEncode({'error': e.message}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Callback failed: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Start device code flow
  /// POST /api/v1/auth/sso/:provider/device
  Future<Response> _startDeviceFlow(Request request, String provider) async {
    try {
      final deviceAuth = await ssoManager.startDeviceFlow(provider);

      return Response.ok(
        jsonEncode({
          'device_code': deviceAuth.deviceCode,
          'user_code': deviceAuth.userCode,
          'verification_uri': deviceAuth.verificationUri,
          'verification_uri_complete': deviceAuth.verificationUriComplete,
          'expires_in': deviceAuth.expiresIn,
          'interval': deviceAuth.interval,
        }),
        headers: {'content-type': 'application/json'},
      );
    } on SSOException catch (e) {
      return Response(400,
          body: jsonEncode({'error': e.message}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to start device flow: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Poll for device code flow completion
  /// POST /api/v1/auth/sso/:provider/device/poll
  Future<Response> _pollDeviceFlow(Request request, String provider) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final deviceCode = data['device_code'] as String?;

      if (deviceCode == null) {
        return Response(400,
            body: jsonEncode({'error': 'device_code is required'}),
            headers: {'content-type': 'application/json'});
      }

      final result = await ssoManager.pollDeviceFlow(
        providerId: provider,
        deviceCode: deviceCode,
      );

      // Handle login and generate tokens
      final tokens = await _handleSSOLogin(
        result: result,
        request: request,
      );

      return Response.ok(
        jsonEncode(tokens),
        headers: {'content-type': 'application/json'},
      );
    } on AuthorizationPendingException {
      return Response(400,
          body: jsonEncode({
            'error': 'authorization_pending',
            'error_description': 'The user has not yet completed authorization',
          }),
          headers: {'content-type': 'application/json'});
    } on SlowDownException {
      return Response(400,
          body: jsonEncode({
            'error': 'slow_down',
            'error_description': 'Polling too frequently',
          }),
          headers: {'content-type': 'application/json'});
    } on ExpiredDeviceCodeException {
      return Response(400,
          body: jsonEncode({
            'error': 'expired_token',
            'error_description': 'The device code has expired',
          }),
          headers: {'content-type': 'application/json'});
    } on SSOException catch (e) {
      return Response(400,
          body: jsonEncode({'error': e.message}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Poll failed: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Handle SSO login - find or create user and generate JWT tokens
  Future<Map<String, dynamic>> _handleSSOLogin({
    required SSOAuthResult result,
    required Request request,
  }) async {
    final userInfo = result.userInfo;
    final email = userInfo.email;

    if (email == null) {
      throw SSOException('Email not provided by SSO provider');
    }

    // Find existing admin by SSO identity or email
    var admin = await adminRepo.getBySsoSubject(
      result.providerId,
      userInfo.subject,
    );

    if (admin == null) {
      // Try to find by email
      admin = await adminRepo.getByEmail(email);

      if (admin != null) {
        // Link existing account to SSO
        await adminRepo.linkSSO(
          admin.id,
          result.providerId,
          userInfo.subject,
        );
      }
    }

    if (admin == null) {
      // Create new admin from SSO
      admin = await adminRepo.createFromSSO(
        email: email,
        ssoProvider: result.providerId,
        ssoSubject: userInfo.subject,
        name: userInfo.name,
      );

      await logRepo.auditLog(
        actorType: 'system',
        eventType: 'SSO_USER_CREATED',
        severity: 'INFO',
        resourceType: 'admin',
        resourceId: admin.id,
        resourceName: email,
        details: {
          'provider': result.providerId,
          'subject': userInfo.subject,
        },
        ipAddress:
            request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );
    }

    if (!admin.isActive) {
      throw SSOException('Account is disabled');
    }

    // Update last login
    await adminRepo.updateLastLogin(admin.id);

    // Generate JWT tokens
    final accessToken = _generateAccessToken(admin.id, admin.email, admin.role);
    final refreshToken = _generateRefreshToken(admin.id);

    // Log successful SSO login
    await logRepo.auditLog(
      actorType: 'admin',
      actorId: admin.id,
      actorName: admin.email,
      eventType: 'SSO_LOGIN_SUCCESS',
      severity: 'INFO',
      details: {'provider': result.providerId},
      ipAddress:
          request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      userAgent: request.headers['user-agent'],
    );

    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'token_type': 'Bearer',
      'expires_in': 900,
      'user': {
        'id': admin.id,
        'email': admin.email,
        'role': admin.role,
        'name': userInfo.name,
      },
    };
  }

  /// List SSO configurations (admin only)
  Future<Response> _listConfigs(Request request) async {
    try {
      final configs = await ssoManager.getConfigs();

      // Remove client secrets from response
      final sanitized = configs.map((c) {
        final json = c.toJson();
        json.remove('client_secret');
        return json;
      }).toList();

      return Response.ok(
        jsonEncode({'configs': sanitized}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to list configs: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Save SSO configuration (admin only)
  Future<Response> _saveConfig(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final config = SSOConfig.fromJson(data);
      await ssoManager.saveConfig(config);

      await logRepo.auditLog(
        actorType: 'admin',
        actorId: request.context['adminId'] as String?,
        eventType: 'SSO_CONFIG_SAVED',
        severity: 'ALERT',
        resourceType: 'sso_config',
        resourceName: config.providerId,
        ipAddress:
            request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode({'message': 'SSO configuration saved'}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to save config: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Delete SSO configuration (admin only)
  Future<Response> _deleteConfig(Request request, String provider) async {
    try {
      await ssoManager.deleteConfig(provider);

      await logRepo.auditLog(
        actorType: 'admin',
        actorId: request.context['adminId'] as String?,
        eventType: 'SSO_CONFIG_DELETED',
        severity: 'ALERT',
        resourceType: 'sso_config',
        resourceName: provider,
        ipAddress:
            request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(204);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to delete config: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  String _generateAccessToken(String adminId, String email, String role) {
    final jwt = JWT({
      'sub': adminId,
      'email': email,
      'role': role,
      'type': 'access',
    });

    return jwt.sign(
      SecretKey(jwtSecret),
      expiresIn: const Duration(minutes: 15),
    );
  }

  String _generateRefreshToken(String adminId) {
    final jwt = JWT({
      'sub': adminId,
      'type': 'refresh',
    });

    return jwt.sign(
      SecretKey(jwtSecret),
      expiresIn: const Duration(days: 7),
    );
  }
}
