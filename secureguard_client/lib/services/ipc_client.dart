import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// IPC client for communicating with SecureGuard daemon
class IpcClient {
  static const String defaultSocketPath = '/var/run/secureguard.sock';

  final String socketPath;
  Socket? _socket;
  int _requestId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final StreamController<VpnStatus> _statusController = StreamController.broadcast();
  final StreamController<bool> _connectionController = StreamController.broadcast();
  final StreamController<ConfigUpdateNotification> _configUpdatedController = StreamController.broadcast();
  final StreamController<ConfigUpdateFailedNotification> _configUpdateFailedController = StreamController.broadcast();
  StringBuffer _buffer = StringBuffer();

  IpcClient({this.socketPath = defaultSocketPath});

  /// Stream of VPN status updates
  Stream<VpnStatus> get statusStream => _statusController.stream;

  /// Stream of daemon connection state
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Stream of config update success notifications
  Stream<ConfigUpdateNotification> get configUpdatedStream => _configUpdatedController.stream;

  /// Stream of config update failure notifications
  Stream<ConfigUpdateFailedNotification> get configUpdateFailedStream => _configUpdateFailedController.stream;

  /// Whether connected to daemon
  bool get isConnectedToDaemon => _socket != null;

  /// Connect to the daemon socket
  Future<bool> connect() async {
    if (_socket != null) return true;

    try {
      final address = InternetAddress(socketPath, type: InternetAddressType.unix);
      _socket = await Socket.connect(address, 0);
      _connectionController.add(true);

      _socket!.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      return true;
    } catch (e) {
      _connectionController.add(false);
      return false;
    }
  }

  /// Disconnect from daemon socket
  Future<void> disconnect() async {
    await _socket?.close();
    _socket = null;
    _connectionController.add(false);
    _pendingRequests.clear();
    _buffer.clear();
  }

  /// Handle incoming data from socket
  void _onData(List<int> data) {
    _buffer.write(utf8.decode(data));

    // Process complete JSON-RPC messages (newline-delimited)
    final content = _buffer.toString();
    final lines = content.split('\n');

    // Process all complete lines
    for (int i = 0; i < lines.length - 1; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        _processMessage(json);
      } catch (e) {
        // Skip malformed JSON
      }
    }

    // Keep incomplete line in buffer
    _buffer = StringBuffer(lines.last);
  }

  /// Process a JSON-RPC message
  void _processMessage(Map<String, dynamic> json) {
    // Check if it's a notification (no id)
    if (!json.containsKey('id') || json['id'] == null) {
      _handleNotification(json);
      return;
    }

    // It's a response to a request
    final id = json['id'] as int;
    final completer = _pendingRequests.remove(id);
    if (completer != null) {
      if (json.containsKey('error')) {
        completer.completeError(IpcError.fromJson(json['error'] as Map<String, dynamic>));
      } else {
        completer.complete(json['result'] as Map<String, dynamic>? ?? {});
      }
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

  void _onError(Object error) {
    _connectionController.add(false);
    for (final completer in _pendingRequests.values) {
      completer.completeError(error);
    }
    _pendingRequests.clear();
  }

  void _onDone() {
    _socket = null;
    _connectionController.add(false);
    for (final completer in _pendingRequests.values) {
      completer.completeError(const SocketException('Connection closed'));
    }
    _pendingRequests.clear();
  }

  /// Send a JSON-RPC request
  Future<Map<String, dynamic>> _request(String method, [Map<String, dynamic>? params]) async {
    if (_socket == null) {
      throw const SocketException('Not connected to daemon');
    }

    final id = ++_requestId;
    final request = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params ?? {},
      'id': id,
    };

    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final json = jsonEncode(request);
    _socket!.write('$json\n');

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException('Request timed out');
      },
    );
  }

  /// Connect to VPN with config
  Future<void> connectVpn(String config) async {
    await _request('connect', {'config': config});
  }

  /// Disconnect from VPN
  Future<void> disconnectVpn() async {
    await _request('disconnect');
  }

  /// Get current VPN status
  Future<VpnStatus> getStatus() async {
    final result = await _request('status');
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
    final result = await _request('update_config', {'config': config});
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
