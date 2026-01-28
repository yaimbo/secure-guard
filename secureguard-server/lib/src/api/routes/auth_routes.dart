import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../repositories/admin_repository.dart';
import '../../repositories/log_repository.dart';

/// Authentication routes
class AuthRoutes {
  final AdminRepository adminRepo;
  final LogRepository logRepo;
  final String jwtSecret;

  AuthRoutes(this.adminRepo, this.jwtSecret, this.logRepo);

  Router get router {
    final router = Router();

    router.post('/login', _login);
    router.post('/logout', _logout);
    router.post('/refresh', _refresh);

    return router;
  }

  Future<Response> _login(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final email = data['email'] as String?;
      final password = data['password'] as String?;

      if (email == null || password == null) {
        return Response(400,
            body: jsonEncode({'error': 'Email and password required'}),
            headers: {'content-type': 'application/json'});
      }

      // Find admin by email
      final admin = await adminRepo.getByEmail(email);
      if (admin == null) {
        await logRepo.auditLog(
          actorType: 'system',
          eventType: 'LOGIN_FAILED',
          details: {'email': email, 'reason': 'User not found'},
          ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
        );
        return Response(401,
            body: jsonEncode({'error': 'Invalid credentials'}),
            headers: {'content-type': 'application/json'});
      }

      // Verify password
      if (!BCrypt.checkpw(password, admin.passwordHash ?? '')) {
        await logRepo.auditLog(
          actorType: 'system',
          eventType: 'LOGIN_FAILED',
          details: {'email': email, 'reason': 'Invalid password'},
          ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
        );
        return Response(401,
            body: jsonEncode({'error': 'Invalid credentials'}),
            headers: {'content-type': 'application/json'});
      }

      if (!admin.isActive) {
        return Response(403,
            body: jsonEncode({'error': 'Account disabled'}),
            headers: {'content-type': 'application/json'});
      }

      // Generate tokens
      final accessToken = _generateAccessToken(admin.id, admin.email, admin.role);
      final refreshToken = _generateRefreshToken(admin.id);

      // Update last login
      await adminRepo.updateLastLogin(admin.id);

      // Log successful login
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: admin.id,
        actorName: admin.email,
        eventType: 'LOGIN_SUCCESS',
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
        userAgent: request.headers['user-agent'],
      );

      return Response.ok(
        jsonEncode({
          'access_token': accessToken,
          'refresh_token': refreshToken,
          'token_type': 'Bearer',
          'expires_in': 900, // 15 minutes
          'user': {
            'id': admin.id,
            'email': admin.email,
            'role': admin.role,
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Login failed: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _logout(Request request) async {
    // TODO: Invalidate refresh token in Redis
    return Response.ok(
      jsonEncode({'message': 'Logged out successfully'}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _refresh(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final refreshToken = data['refresh_token'] as String?;

      if (refreshToken == null) {
        return Response(400,
            body: jsonEncode({'error': 'Refresh token required'}),
            headers: {'content-type': 'application/json'});
      }

      try {
        final jwt = JWT.verify(refreshToken, SecretKey(jwtSecret));
        final payload = jwt.payload as Map<String, dynamic>;

        if (payload['type'] != 'refresh') {
          return Response(401,
              body: jsonEncode({'error': 'Invalid token type'}),
              headers: {'content-type': 'application/json'});
        }

        final adminId = payload['sub'] as String;

        // Get admin details
        final admin = await adminRepo.getById(adminId);
        if (admin == null || !admin.isActive) {
          return Response(401,
              body: jsonEncode({'error': 'User not found or disabled'}),
              headers: {'content-type': 'application/json'});
        }

        // Generate new tokens
        final newAccessToken = _generateAccessToken(admin.id, admin.email, admin.role);
        final newRefreshToken = _generateRefreshToken(admin.id);

        return Response.ok(
          jsonEncode({
            'access_token': newAccessToken,
            'refresh_token': newRefreshToken,
            'token_type': 'Bearer',
            'expires_in': 900,
          }),
          headers: {'content-type': 'application/json'},
        );
      } on JWTExpiredException {
        return Response(401,
            body: jsonEncode({'error': 'Refresh token expired'}),
            headers: {'content-type': 'application/json'});
      } on JWTException catch (e) {
        return Response(401,
            body: jsonEncode({'error': 'Invalid refresh token: ${e.message}'}),
            headers: {'content-type': 'application/json'});
      }
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Token refresh failed: $e'}),
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
