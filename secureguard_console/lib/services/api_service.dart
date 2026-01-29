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

  // ═══════════════════════════════════════════════════════════════════
  // SSO CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════

  Future<List<SSOConfig>> getSSOConfigs() async {
    final response = await _dio.get('/admin/sso/configs');
    final items = response.data['configs'] as List? ?? [];
    return items.map((json) => SSOConfig.fromJson(json)).toList();
  }

  Future<void> saveSSOConfig(SSOConfig config) async {
    await _dio.post('/admin/sso/configs', data: config.toJson());
  }

  Future<void> deleteSSOConfig(String providerId) async {
    await _dio.delete('/admin/sso/configs/$providerId');
  }

  Future<List<SSOProviderInfo>> getAvailableSSOProviders() async {
    final response = await _dio.get('/auth/sso/providers');
    final items = response.data['providers'] as List? ?? [];
    return items.map((json) => SSOProviderInfo.fromJson(json)).toList();
  }
}

/// SSO configuration model
class SSOConfig {
  final String providerId;
  final String clientId;
  final String? clientSecret;
  final String? tenantId;
  final String? domain;
  final List<String> scopes;
  final bool enabled;

  SSOConfig({
    required this.providerId,
    required this.clientId,
    this.clientSecret,
    this.tenantId,
    this.domain,
    this.scopes = const ['openid', 'profile', 'email'],
    this.enabled = true,
  });

  factory SSOConfig.fromJson(Map<String, dynamic> json) {
    return SSOConfig(
      providerId: json['provider_id'] as String,
      clientId: json['client_id'] as String,
      clientSecret: json['client_secret'] as String?,
      tenantId: json['tenant_id'] as String?,
      domain: json['domain'] as String?,
      scopes: (json['scopes'] as List<dynamic>?)?.cast<String>() ??
          ['openid', 'profile', 'email'],
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'provider_id': providerId,
        'client_id': clientId,
        if (clientSecret != null) 'client_secret': clientSecret,
        if (tenantId != null) 'tenant_id': tenantId,
        if (domain != null) 'domain': domain,
        'scopes': scopes,
        'enabled': enabled,
      };
}

/// SSO provider info from server
class SSOProviderInfo {
  final String id;
  final String name;
  final bool enabled;

  SSOProviderInfo({
    required this.id,
    required this.name,
    required this.enabled,
  });

  factory SSOProviderInfo.fromJson(Map<String, dynamic> json) {
    return SSOProviderInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? false,
    );
  }
}
