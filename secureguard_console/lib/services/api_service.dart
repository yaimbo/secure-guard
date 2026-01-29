import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/client.dart';
import '../models/logs.dart';
import '../providers/settings_provider.dart';

final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

/// Exception thrown when the server is unreachable
class ServerUnavailableException implements Exception {
  final String message;
  ServerUnavailableException([this.message = 'Server is unavailable']);

  @override
  String toString() => message;
}

class ApiService {
  late final Dio _dio;
  String? _accessToken;

  ApiService() {
    _dio = Dio(BaseOptions(
      baseUrl: const String.fromEnvironment(
        'API_URL',
        defaultValue: 'http://localhost:8080/api/v1',
      ),
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
      },
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_accessToken != null) {
          options.headers['Authorization'] = 'Bearer $_accessToken';
        }
        return handler.next(options);
      },
      onError: (error, handler) {
        if (error.response?.statusCode == 401) {
          // Token expired - trigger refresh or logout
          _accessToken = null;
        }
        return handler.next(error);
      },
    ));
  }

  void setAccessToken(String? token) {
    _accessToken = token;
  }

  // ═══════════════════════════════════════════════════════════════════
  // AUTH
  // ═══════════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await _dio.post('/auth/login', data: {
      'email': email,
      'password': password,
    });
    return response.data;
  }

  Future<void> logout() async {
    await _dio.post('/auth/logout');
    _accessToken = null;
  }

  Future<Map<String, dynamic>> refreshToken(String refreshToken) async {
    final response = await _dio.post('/auth/refresh', data: {
      'refresh_token': refreshToken,
    });
    return response.data;
  }

  Future<bool> checkNeedsSetup() async {
    try {
      final response = await _dio.get('/auth/setup/status');
      return response.data['needs_setup'] == true;
    } on DioException catch (e) {
      // Network errors mean server is unavailable
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw ServerUnavailableException('Cannot connect to server');
      }
      // For other errors (404, 500), assume setup endpoint doesn't exist
      // meaning setup was completed in an older version
      return false;
    }
  }

  Future<void> setupAdmin({
    required String email,
    required String password,
  }) async {
    await _dio.post('/auth/setup', data: {
      'email': email,
      'password': password,
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  // CLIENTS
  // ═══════════════════════════════════════════════════════════════════

  Future<List<Client>> getClients({String? search, String? status}) async {
    final response = await _dio.get('/clients', queryParameters: {
      'page': 1,
      'limit': 100,
      if (status != null) 'status': status,
      if (search != null && search.isNotEmpty) 'search': search,
    });
    final items = response.data['data'] as List? ?? [];
    return items.map((json) => Client.fromJson(json)).toList();
  }

  Future<Client> getClient(String id) async {
    final response = await _dio.get('/clients/$id');
    return Client.fromJson(response.data);
  }

  Future<Client> createClient({
    required String name,
    String? description,
    String? userEmail,
  }) async {
    final response = await _dio.post('/clients', data: {
      'name': name,
      if (description != null) 'description': description,
      if (userEmail != null) 'user_email': userEmail,
    });
    return Client.fromJson(response.data);
  }

  Future<Client> updateClient(
    String id, {
    String? name,
    String? description,
    String? userEmail,
  }) async {
    final response = await _dio.put('/clients/$id', data: {
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (userEmail != null) 'user_email': userEmail,
    });
    return Client.fromJson(response.data);
  }

  Future<void> deleteClient(String id) async {
    await _dio.delete('/clients/$id');
  }

  Future<void> enableClient(String id) async {
    await _dio.post('/clients/$id/enable');
  }

  Future<void> disableClient(String id) async {
    await _dio.post('/clients/$id/disable');
  }

  Future<void> regenerateKeys(String id) async {
    await _dio.post('/clients/$id/regenerate-keys');
  }

  Future<void> downloadClientConfig(String id) async {
    final response = await _dio.get('/clients/$id/config');
    // In a real app, trigger file download via web APIs
    // ignore: avoid_print
    print('Config downloaded: ${response.data}');
  }

  Future<Uint8List> getClientQrCode(String id) async {
    final response = await _dio.get<List<int>>(
      '/clients/$id/qr',
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data!);
  }

  // ═══════════════════════════════════════════════════════════════════
  // LOGS
  // ═══════════════════════════════════════════════════════════════════

  Future<List<AuditLog>> getAuditLogs({
    DateTime? startDate,
    DateTime? endDate,
    String? eventType,
    String? search,
  }) async {
    final response = await _dio.get('/logs/audit', queryParameters: {
      'page': 1,
      'limit': 100,
      if (startDate != null) 'start_date': startDate.toIso8601String(),
      if (endDate != null) 'end_date': endDate.toIso8601String(),
      if (eventType != null) 'event_type': eventType,
      if (search != null && search.isNotEmpty) 'search': search,
    });
    final items = response.data['data'] as List? ?? [];
    return items.map((json) => AuditLog.fromJson(json)).toList();
  }

  Future<List<ErrorLog>> getErrorLogs({
    DateTime? startDate,
    DateTime? endDate,
    String? severity,
    String? component,
  }) async {
    final response = await _dio.get('/logs/errors', queryParameters: {
      'page': 1,
      'limit': 100,
      if (severity != null) 'severity': severity,
      if (component != null) 'component': component,
    });
    final items = response.data['data'] as List? ?? [];
    return items.map((json) => ErrorLog.fromJson(json)).toList();
  }

  Future<List<ConnectionLog>> getConnectionLogs({
    DateTime? startDate,
    DateTime? endDate,
    String? clientId,
  }) async {
    final response = await _dio.get('/logs/connections', queryParameters: {
      'page': 1,
      'limit': 100,
      if (clientId != null) 'client_id': clientId,
    });
    final items = response.data['data'] as List? ?? [];
    return items.map((json) => ConnectionLog.fromJson(json)).toList();
  }

  Future<Map<String, dynamic>> getConnectionStats() async {
    final response = await _dio.get('/logs/connections/stats');
    return response.data;
  }

  // ═══════════════════════════════════════════════════════════════════
  // SETTINGS
  // ═══════════════════════════════════════════════════════════════════

  Future<ServerConfig> getServerConfig() async {
    final response = await _dio.get('/settings/server');
    return ServerConfig.fromJson(response.data);
  }

  Future<void> updateServerConfig(ServerConfig config) async {
    await _dio.put('/settings/server', data: config.toJson());
  }

  Future<List<AdminUser>> getAdminUsers() async {
    final response = await _dio.get('/settings/admins');
    final items = response.data['data'] as List? ?? [];
    return items.map((json) => AdminUser.fromJson(json)).toList();
  }

  Future<AdminUser> createAdminUser({
    required String email,
    required String password,
    required String role,
  }) async {
    final response = await _dio.post('/settings/admins', data: {
      'email': email,
      'password': password,
      'role': role,
    });
    return AdminUser.fromJson(response.data);
  }

  Future<void> deleteAdminUser(String id) async {
    await _dio.delete('/settings/admins/$id');
  }

  // ═══════════════════════════════════════════════════════════════════
  // HEALTH
  // ═══════════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>> healthCheck() async {
    final response = await _dio.get('/health');
    return response.data;
  }
}
