import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// API client for communicating with MinnowVPN server
class ApiClient {
  static const String _serverUrlKey = 'server_url';
  static const String _deviceTokenKey = 'device_token';

  String? _serverUrl;
  String? _deviceToken;
  HttpClient? _httpClient;

  static final ApiClient _instance = ApiClient._();
  static ApiClient get instance => _instance;

  ApiClient._();

  /// Initialize the API client
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_serverUrlKey);
    _deviceToken = prefs.getString(_deviceTokenKey);

    _httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 60);
  }

  /// Check if the client is configured
  bool get isConfigured => _serverUrl != null && _serverUrl!.isNotEmpty;

  /// Check if the device is enrolled
  bool get isEnrolled => _deviceToken != null && _deviceToken!.isNotEmpty;

  /// Get the current server URL
  String? get serverUrl => _serverUrl;

  /// Configure the server URL
  Future<void> setServerUrl(String url) async {
    _serverUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _serverUrl!);
  }

  /// Set the device token (after enrollment)
  Future<void> setDeviceToken(String token) async {
    _deviceToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deviceTokenKey, token);
  }

  /// Clear stored credentials
  Future<void> clearCredentials() async {
    _deviceToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_deviceTokenKey);
  }

  /// Make a GET request
  Future<ApiResponse> get(String path, {Map<String, String>? queryParams}) async {
    if (_serverUrl == null) {
      return ApiResponse.error('Server URL not configured');
    }
    if (_httpClient == null) {
      return ApiResponse.error('API client not initialized');
    }

    try {
      var uri = Uri.parse('$_serverUrl$path');
      if (queryParams != null && queryParams.isNotEmpty) {
        uri = uri.replace(queryParameters: queryParams);
      }

      final request = await _httpClient!.getUrl(uri);
      _addHeaders(request);

      final response = await request.close();
      return _processResponse(response);
    } on SocketException catch (e) {
      return ApiResponse.error('Network error: ${e.message}');
    } catch (e) {
      return ApiResponse.error('Request failed: $e');
    }
  }

  /// Make a POST request
  Future<ApiResponse> post(String path, {dynamic body}) async {
    if (_serverUrl == null) {
      return ApiResponse.error('Server URL not configured');
    }
    if (_httpClient == null) {
      return ApiResponse.error('API client not initialized');
    }

    try {
      final uri = Uri.parse('$_serverUrl$path');
      final request = await _httpClient!.postUrl(uri);
      _addHeaders(request);

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close();
      return _processResponse(response);
    } on SocketException catch (e) {
      return ApiResponse.error('Network error: ${e.message}');
    } catch (e) {
      return ApiResponse.error('Request failed: $e');
    }
  }

  /// Make a POST request to a full URL (for enrollment with dynamic server)
  Future<ApiResponse> postToUrl(String fullUrl, {dynamic body}) async {
    if (_httpClient == null) {
      return ApiResponse.error('API client not initialized');
    }

    try {
      final uri = Uri.parse(fullUrl);
      final request = await _httpClient!.postUrl(uri);
      request.headers.add('Accept', 'application/json');

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close();
      return _processResponse(response);
    } on SocketException catch (e) {
      return ApiResponse.error('Network error: ${e.message}');
    } catch (e) {
      return ApiResponse.error('Request failed: $e');
    }
  }

  void _addHeaders(HttpClientRequest request) {
    request.headers.add('Accept', 'application/json');
    if (_deviceToken != null) {
      request.headers.add('Authorization', 'Bearer $_deviceToken');
    }
  }

  Future<ApiResponse> _processResponse(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        if (body.isEmpty) {
          return ApiResponse.success(null);
        }
        // Check if it's JSON or plain text
        if (response.headers.contentType?.mimeType == 'application/json') {
          return ApiResponse.success(jsonDecode(body));
        }
        return ApiResponse.success(body);
      } catch (e) {
        return ApiResponse.success(body);
      }
    } else {
      String errorMessage;
      try {
        final errorJson = jsonDecode(body);
        errorMessage = errorJson['error'] ?? 'Unknown error';
      } catch (_) {
        errorMessage = body.isNotEmpty ? body : 'HTTP ${response.statusCode}';
      }
      return ApiResponse.error(errorMessage, statusCode: response.statusCode);
    }
  }

  void dispose() {
    _httpClient?.close();
  }
}

/// API response wrapper
class ApiResponse {
  final bool isSuccess;
  final dynamic data;
  final String? error;
  final int? statusCode;

  ApiResponse._({
    required this.isSuccess,
    this.data,
    this.error,
    this.statusCode,
  });

  factory ApiResponse.success(dynamic data) => ApiResponse._(
        isSuccess: true,
        data: data,
      );

  factory ApiResponse.error(String error, {int? statusCode}) => ApiResponse._(
        isSuccess: false,
        error: error,
        statusCode: statusCode,
      );
}
