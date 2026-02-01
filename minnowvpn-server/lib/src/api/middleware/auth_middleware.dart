import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../../repositories/admin_repository.dart';
import '../../repositories/api_key_repository.dart';

/// Middleware for JWT and API key authentication
class AuthMiddleware {
  final String jwtSecret;
  final AdminRepository adminRepo;
  final ApiKeyRepository? apiKeyRepo;
  final _log = Logger('AuthMiddleware');

  AuthMiddleware(this.jwtSecret, this.adminRepo, {this.apiKeyRepo});

  /// Require admin authentication (supports JWT and API keys)
  Middleware requireAdmin() {
    return (Handler innerHandler) {
      return (Request request) async {
        final authHeader = request.headers['authorization'];

        if (authHeader == null) {
          return Response(401,
              body: jsonEncode({'error': 'Missing authorization header'}),
              headers: {'content-type': 'application/json'});
        }

        // Check for API key (starts with sg_live_)
        if (authHeader.startsWith('Bearer sg_live_') && apiKeyRepo != null) {
          final apiKey = authHeader.substring(7); // Remove "Bearer "
          return _handleApiKeyAuth(request, apiKey, innerHandler);
        }

        // Handle JWT Bearer token
        if (!authHeader.startsWith('Bearer ')) {
          return Response(401,
              body: jsonEncode({'error': 'Invalid authorization header format'}),
              headers: {'content-type': 'application/json'});
        }

        final token = authHeader.substring(7);

        try {
          final jwt = JWT.verify(token, SecretKey(jwtSecret));
          final payload = jwt.payload as Map<String, dynamic>;

          final adminId = payload['sub'] as String?;
          final role = payload['role'] as String?;

          if (adminId == null) {
            return Response(401,
                body: jsonEncode({'error': 'Invalid token payload'}),
                headers: {'content-type': 'application/json'});
          }

          // Add admin info to request context
          final updatedRequest = request.change(context: {
            'adminId': adminId,
            'adminRole': role ?? 'admin',
            'authType': 'jwt',
          });

          return await innerHandler(updatedRequest);
        } on JWTExpiredException {
          return Response(401,
              body: jsonEncode({'error': 'Token expired'}),
              headers: {'content-type': 'application/json'});
        } on JWTException catch (e) {
          return Response(401,
              body: jsonEncode({'error': 'Invalid token: ${e.message}'}),
              headers: {'content-type': 'application/json'});
        }
      };
    };
  }

  /// Handle API key authentication
  Future<Response> _handleApiKeyAuth(
    Request request,
    String apiKey,
    Handler innerHandler,
  ) async {
    try {
      final key = await apiKeyRepo!.getByKey(apiKey);

      if (key == null) {
        return Response(401,
            body: jsonEncode({'error': 'Invalid API key'}),
            headers: {'content-type': 'application/json'});
      }

      if (!key.isValid) {
        return Response(401,
            body: jsonEncode({'error': key.isExpired ? 'API key expired' : 'API key revoked'}),
            headers: {'content-type': 'application/json'});
      }

      // Update last used timestamp (non-blocking but logged on failure)
      apiKeyRepo!.updateLastUsed(key.id).catchError((e) {
        _log.warning('Failed to update API key last_used timestamp: $e');
      });

      // Add API key info to request context
      final updatedRequest = request.change(context: {
        'adminId': key.createdBy ?? 'api_key_${key.id}',
        'adminRole': key.permissions == 'admin' ? 'admin' : 'api_key',
        'authType': 'api_key',
        'apiKeyId': key.id,
        'apiKeyPermissions': key.permissions,
      });

      return await innerHandler(updatedRequest);
    } catch (e) {
      return Response(500,
          body: jsonEncode({'error': 'API key validation failed: $e'}),
          headers: {'content-type': 'application/json'});
    }
  }

  /// Require device authentication (for enrollment endpoints)
  Middleware requireDevice() {
    return (Handler innerHandler) {
      return (Request request) async {
        final authHeader = request.headers['authorization'];

        if (authHeader == null || !authHeader.startsWith('Bearer ')) {
          return Response(401,
              body: jsonEncode({'error': 'Missing or invalid authorization header'}),
              headers: {'content-type': 'application/json'});
        }

        final token = authHeader.substring(7);

        try {
          final jwt = JWT.verify(token, SecretKey(jwtSecret));
          final payload = jwt.payload as Map<String, dynamic>;

          final deviceId = payload['device_id'] as String?;

          if (deviceId == null) {
            return Response(401,
                body: jsonEncode({'error': 'Invalid device token'}),
                headers: {'content-type': 'application/json'});
          }

          // Add device info to request context
          final updatedRequest = request.change(context: {
            'deviceId': deviceId,
          });

          return await innerHandler(updatedRequest);
        } on JWTExpiredException {
          return Response(401,
              body: jsonEncode({'error': 'Device token expired'}),
              headers: {'content-type': 'application/json'});
        } on JWTException catch (e) {
          return Response(401,
              body: jsonEncode({'error': 'Invalid device token: ${e.message}'}),
              headers: {'content-type': 'application/json'});
        }
      };
    };
  }
}
