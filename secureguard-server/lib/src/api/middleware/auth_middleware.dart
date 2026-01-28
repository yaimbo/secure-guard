import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';

import '../../repositories/admin_repository.dart';

/// Middleware for JWT authentication
class AuthMiddleware {
  final String jwtSecret;
  final AdminRepository adminRepo;

  AuthMiddleware(this.jwtSecret, this.adminRepo);

  /// Require admin authentication
  Middleware requireAdmin() {
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
