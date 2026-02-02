import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Daemon installation/running status
enum DaemonStatus {
  /// Daemon is running and responding
  running,

  /// Daemon appears to be installed but not responding
  notRunning,

  /// Daemon is not installed (token file missing)
  notInstalled,
}

/// Connection state enum matching Rust daemon
enum VpnConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error;

  static VpnConnectionState fromString(String value) {
    return VpnConnectionState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => VpnConnectionState.disconnected,
    );
  }
}

/// VPN status from daemon
class VpnStatus {
  final VpnConnectionState state;
  final String? vpnIp;
  final String? serverEndpoint;
  final String? connectedAt;
  final int bytesSent;
  final int bytesReceived;
  final String? lastHandshake;
  final String? errorMessage;

  VpnStatus({
    required this.state,
    this.vpnIp,
    this.serverEndpoint,
    this.connectedAt,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.lastHandshake,
    this.errorMessage,
  });

  factory VpnStatus.disconnected() => VpnStatus(state: VpnConnectionState.disconnected);

  factory VpnStatus.fromJson(Map<String, dynamic> json) {
    return VpnStatus(
      state: VpnConnectionState.fromString(json['state'] as String? ?? 'disconnected'),
      vpnIp: json['vpn_ip'] as String?,
      serverEndpoint: json['server_endpoint'] as String?,
      connectedAt: json['connected_at'] as String?,
      bytesSent: json['bytes_sent'] as int? ?? 0,
      bytesReceived: json['bytes_received'] as int? ?? 0,
      lastHandshake: json['last_handshake'] as String?,
      errorMessage: json['error_message'] as String?,
    );
  }

  bool get isConnected => state == VpnConnectionState.connected;
  bool get isDisconnected => state == VpnConnectionState.disconnected;
  bool get isTransitioning =>
      state == VpnConnectionState.connecting || state == VpnConnectionState.disconnecting;
}

/// REST API client for communicating with MinnowVPN daemon
///
/// Uses HTTP REST API with Bearer token authentication and SSE for real-time notifications.
class IpcClient {
  /// Default HTTP port for client mode daemon
  static const int defaultPort = 51820;

  /// Token file path (platform-specific)
  static String get tokenFilePath {
    if (Platform.isWindows) {
      return r'C:\ProgramData\MinnowVPN\auth-token';
    }
    return '/var/run/minnowvpn/auth-token';
  }

  final String host;
  final int port;
  String? _authToken;
  http.Client? _httpClient;
  HttpClient? _sseClient;
  bool _sseRunning = false;

  final StreamController<VpnStatus> _statusController = StreamController.broadcast();
  final StreamController<bool> _connectionController = StreamController.broadcast();
  final StreamController<ConfigUpdateNotification> _configUpdatedController = StreamController.broadcast();
  final StreamController<ConfigUpdateFailedNotification> _configUpdateFailedController = StreamController.broadcast();

  IpcClient({this.host = '127.0.0.1', this.port = defaultPort});

  /// Stream of VPN status updates
  Stream<VpnStatus> get statusStream => _statusController.stream;

  /// Stream of daemon connection state
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Stream of config update success notifications
  Stream<ConfigUpdateNotification> get configUpdatedStream => _configUpdatedController.stream;

  /// Stream of config update failure notifications
  Stream<ConfigUpdateFailedNotification> get configUpdateFailedStream => _configUpdateFailedController.stream;

  /// Whether connected to daemon
  bool get isConnectedToDaemon => _httpClient != null && _authToken != null;

  /// Base URL for API requests
  String get _baseUrl => 'http://$host:$port/api/v1';

  /// Connect to the daemon (load token and start SSE)
  Future<bool> connect() async {
    if (_httpClient != null) return true;

    try {
      // Load auth token from file
      _authToken = await _loadAuthToken();
      if (_authToken == null) {
        _connectionController.add(false);
        return false;
      }

      _httpClient = http.Client();

      // Verify connection by getting status
      await getStatus();

      _connectionController.add(true);

      // Start SSE listener for notifications
      _startSseListener();

      return true;
    } catch (e) {
      _httpClient?.close();
      _httpClient = null;
      _authToken = null;
      _connectionController.add(false);
      return false;
    }
  }

  /// Check if daemon is installed and running
  ///
  /// Returns:
  /// - [DaemonStatus.running] if daemon responds to API requests
  /// - [DaemonStatus.notRunning] if token exists but daemon not responding
  /// - [DaemonStatus.notInstalled] if token file doesn't exist
  Future<DaemonStatus> checkDaemonStatus() async {
    try {
      // Check if token file exists
      final tokenFile = File(tokenFilePath);
      print('[IpcClient] Checking token file at: $tokenFilePath');

      final exists = await tokenFile.exists();
      print('[IpcClient] Token file exists: $exists');

      if (!exists) {
        print('[IpcClient] Token file not found - returning notInstalled');
        return DaemonStatus.notInstalled;
      }

      // Load token
      print('[IpcClient] Reading token file...');
      final token = await tokenFile.readAsString();
      print('[IpcClient] Token length: ${token.length}, empty: ${token.trim().isEmpty}');

      if (token.trim().isEmpty) {
        print('[IpcClient] Token is empty - returning notInstalled');
        return DaemonStatus.notInstalled;
      }

      // Try to connect to daemon
      print('[IpcClient] Connecting to daemon at http://$host:$port/api/v1/status');
      final client = http.Client();
      try {
        final response = await client
            .get(
              Uri.parse('http://$host:$port/api/v1/status'),
              headers: {'Authorization': 'Bearer ${token.trim()}'},
            )
            .timeout(const Duration(seconds: 3));

        print('[IpcClient] Response status: ${response.statusCode}');

        if (response.statusCode == 200 || response.statusCode == 401) {
          // 200 = success, 401 = wrong token but daemon is responding
          print('[IpcClient] Daemon is running');
          return DaemonStatus.running;
        }
        print('[IpcClient] Unexpected status code - returning notRunning');
        return DaemonStatus.notRunning;
      } catch (e) {
        // Connection failed - daemon not responding
        print('[IpcClient] HTTP error: $e - returning notRunning');
        return DaemonStatus.notRunning;
      } finally {
        client.close();
      }
    } catch (e) {
      // Error reading token file
      print('[IpcClient] Exception: $e - returning notInstalled');
      return DaemonStatus.notInstalled;
    }
  }

  /// Load authentication token from file
  Future<String?> _loadAuthToken() async {
    try {
      final file = File(tokenFilePath);
      if (!await file.exists()) {
        return null;
      }
      final token = await file.readAsString();
      return token.trim();
    } catch (e) {
      return null;
    }
  }

  /// Start SSE listener for real-time notifications
  void _startSseListener() {
    _sseClient = HttpClient();
    _sseRunning = true;
    _connectSse();
  }

  Future<void> _connectSse() async {
    if (_sseClient == null || _authToken == null || !_sseRunning) return;

    try {
      final request = await _sseClient!.getUrl(Uri.parse('$_baseUrl/events'));
      request.headers.set('Authorization', 'Bearer $_authToken');
      request.headers.set('Accept', 'text/event-stream');
      request.headers.set('Cache-Control', 'no-cache');

      final response = await request.close();

      if (response.statusCode != 200) {
        // Retry after delay
        await Future.delayed(const Duration(seconds: 5));
        if (_sseRunning) _connectSse();
        return;
      }

      // Process SSE stream
      await for (final chunk in response.transform(utf8.decoder)) {
        if (!_sseRunning) break;
        _processSseChunk(chunk);
      }
    } catch (e) {
      // Reconnect on error after delay
      await Future.delayed(const Duration(seconds: 5));
      if (_sseRunning) {
        _connectSse();
      }
    }
  }

  String _sseBuffer = '';

  void _processSseChunk(String chunk) {
    _sseBuffer += chunk;

    // Process complete events (double newline separated)
    while (_sseBuffer.contains('\n\n')) {
      final eventEnd = _sseBuffer.indexOf('\n\n');
      final event = _sseBuffer.substring(0, eventEnd);
      _sseBuffer = _sseBuffer.substring(eventEnd + 2);

      _processSseEvent(event);
    }
  }

  void _processSseEvent(String event) {
    // Parse SSE event - just look for data field
    String? data;

    for (final line in event.split('\n')) {
      if (line.startsWith('data:')) {
        data = line.substring(5).trim();
      }
    }

    if (data == null || data.isEmpty) return;

    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      _handleNotification(json);
    } catch (e) {
      // Skip malformed JSON
    }
  }

  /// Handle notification from daemon
  void _handleNotification(Map<String, dynamic> json) {
    final method = json['method'] as String?;
    final params = json['params'] as Map<String, dynamic>? ?? {};

    switch (method) {
      case 'status_changed':
        _statusController.add(VpnStatus.fromJson(params));
        break;
      case 'config_updated':
        _configUpdatedController.add(ConfigUpdateNotification.fromJson(params));
        break;
      case 'config_update_failed':
        _configUpdateFailedController.add(ConfigUpdateFailedNotification.fromJson(params));
        break;
    }
  }

  /// Disconnect from daemon
  Future<void> disconnect() async {
    _sseRunning = false;
    _sseClient?.close(force: true);
    _sseClient = null;
    _httpClient?.close();
    _httpClient = null;
    _authToken = null;
    _sseBuffer = '';
    _connectionController.add(false);
  }

  /// Make an HTTP request with authentication
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (_httpClient == null || _authToken == null) {
      throw const SocketException('Not connected to daemon');
    }

    final uri = Uri.parse('$_baseUrl$path');
    final headers = {
      'Authorization': 'Bearer $_authToken',
      'Content-Type': 'application/json',
    };

    http.Response response;

    switch (method) {
      case 'GET':
        response = await _httpClient!.get(uri, headers: headers);
        break;
      case 'POST':
        response = await _httpClient!.post(
          uri,
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        );
        break;
      case 'PUT':
        response = await _httpClient!.put(
          uri,
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        );
        break;
      case 'DELETE':
        response = await _httpClient!.delete(uri, headers: headers);
        break;
      default:
        throw ArgumentError('Unknown HTTP method: $method');
    }

    if (response.statusCode == 401) {
      _connectionController.add(false);
      throw IpcError(code: -401, message: 'Unauthorized');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode >= 400) {
      throw IpcError(
        code: json['code'] as int? ?? response.statusCode,
        message: json['message'] as String? ?? 'Request failed',
      );
    }

    return json;
  }

  /// Connect to VPN with config
  Future<void> connectVpn(String config) async {
    await _request('POST', '/connect', body: {'config': config});
  }

  /// Disconnect from VPN
  Future<void> disconnectVpn() async {
    await _request('POST', '/disconnect');
  }

  /// Get current VPN status
  Future<VpnStatus> getStatus() async {
    final result = await _request('GET', '/status');
    return VpnStatus.fromJson(result);
  }

  /// Update VPN configuration dynamically
  ///
  /// If connected, will disconnect and reconnect with new config.
  /// If disconnected, returns an error (use connectVpn instead).
  ///
  /// Listen to [configUpdatedStream] for success notifications and
  /// [configUpdateFailedStream] for failure notifications.
  Future<UpdateConfigResponse> updateConfig(String config) async {
    final result = await _request('PUT', '/config', body: {'config': config});
    return UpdateConfigResponse.fromJson(result);
  }

  /// Dispose resources
  void dispose() {
    disconnect();
    _statusController.close();
    _connectionController.close();
    _configUpdatedController.close();
    _configUpdateFailedController.close();
  }
}

/// Response from update_config request
class UpdateConfigResponse {
  final bool updated;
  final String? vpnIp;
  final String? serverEndpoint;

  UpdateConfigResponse({
    required this.updated,
    this.vpnIp,
    this.serverEndpoint,
  });

  factory UpdateConfigResponse.fromJson(Map<String, dynamic> json) {
    return UpdateConfigResponse(
      updated: json['updated'] as bool? ?? false,
      vpnIp: json['vpn_ip'] as String?,
      serverEndpoint: json['server_endpoint'] as String?,
    );
  }
}

/// Config update notification data
class ConfigUpdateNotification {
  final String vpnIp;
  final String serverEndpoint;
  final bool reconnected;

  ConfigUpdateNotification({
    required this.vpnIp,
    required this.serverEndpoint,
    required this.reconnected,
  });

  factory ConfigUpdateNotification.fromJson(Map<String, dynamic> json) {
    return ConfigUpdateNotification(
      vpnIp: json['vpn_ip'] as String? ?? '',
      serverEndpoint: json['server_endpoint'] as String? ?? '',
      reconnected: json['reconnected'] as bool? ?? false,
    );
  }
}

/// Config update failed notification data
class ConfigUpdateFailedNotification {
  final String error;
  final bool rolledBack;

  ConfigUpdateFailedNotification({
    required this.error,
    required this.rolledBack,
  });

  factory ConfigUpdateFailedNotification.fromJson(Map<String, dynamic> json) {
    return ConfigUpdateFailedNotification(
      error: json['error'] as String? ?? 'Unknown error',
      rolledBack: json['rolled_back'] as bool? ?? false,
    );
  }
}

/// IPC error from daemon
class IpcError implements Exception {
  final int code;
  final String message;
  final dynamic data;

  IpcError({required this.code, required this.message, this.data});

  factory IpcError.fromJson(Map<String, dynamic> json) {
    return IpcError(
      code: json['code'] as int,
      message: json['message'] as String,
      data: json['data'],
    );
  }

  @override
  String toString() => 'IpcError($code): $message';
}
