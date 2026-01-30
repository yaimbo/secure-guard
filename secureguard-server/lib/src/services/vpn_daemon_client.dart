import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Client for communicating with the SecureGuard Rust daemon via Unix socket.
///
/// This client enables the Dart REST API server to dynamically manage VPN peers
/// by sending JSON-RPC 2.0 commands to the Rust daemon over its Unix socket.
///
/// **Socket Path Convention:**
/// - Client mode daemon: `/var/run/secureguard.sock`
/// - Server mode daemon: `/var/run/secureguard-server.sock` (default for this client)
///
/// This allows running both client and server daemons simultaneously for testing.
///
/// Example usage:
/// ```dart
/// final client = VpnDaemonClient();
/// await client.connect();
/// await client.addPeer(
///   publicKey: 'base64-encoded-key',
///   allowedIps: ['10.0.0.2/32'],
/// );
/// await client.disconnect();
/// ```
class VpnDaemonClient {
  /// Default socket path for server mode daemon
  /// Use `/var/run/secureguard.sock` if connecting to client mode daemon
  static const String defaultSocketPath = '/var/run/secureguard-server.sock';

  final String socketPath;
  Socket? _socket;
  int _requestId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests = {};
  StreamSubscription<List<int>>? _subscription;
  StringBuffer _buffer = StringBuffer();

  VpnDaemonClient({this.socketPath = defaultSocketPath});

  /// Whether currently connected to the daemon
  bool get isConnected => _socket != null;

  /// Connect to the daemon socket
  Future<void> connect() async {
    if (_socket != null) return;

    try {
      final address = InternetAddress(socketPath, type: InternetAddressType.unix);
      _socket = await Socket.connect(address, 0);

      // Handle incoming responses
      _subscription = _socket!.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
    } catch (e) {
      throw VpnDaemonException('Failed to connect to daemon: $e');
    }
  }

  /// Disconnect from the daemon
  Future<void> disconnect() async {
    await _subscription?.cancel();
    await _socket?.close();
    _socket = null;
    _buffer.clear();

    // Complete any pending requests with error
    for (final completer in _pendingRequests.values) {
      completer.completeError(
        const VpnDaemonException('Connection closed'),
      );
    }
    _pendingRequests.clear();
  }

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

  void _processMessage(Map<String, dynamic> json) {
    // Check if it's a response (has id)
    if (json.containsKey('id') && json['id'] != null) {
      final id = json['id'] as int;
      final completer = _pendingRequests.remove(id);
      if (completer != null) {
        if (json.containsKey('error') && json['error'] != null) {
          final error = json['error'] as Map<String, dynamic>;
          completer.completeError(VpnDaemonException(
            error['message'] as String? ?? 'Unknown error',
            code: error['code'] as int?,
          ));
        } else {
          completer.complete(json['result'] as Map<String, dynamic>? ?? {});
        }
      }
    }
    // Notifications (no id) are ignored - server doesn't need them
  }

  void _onError(Object error) {
    for (final completer in _pendingRequests.values) {
      completer.completeError(VpnDaemonException('Socket error: $error'));
    }
    _pendingRequests.clear();
  }

  void _onDone() {
    _socket = null;
    for (final completer in _pendingRequests.values) {
      completer.completeError(
        const VpnDaemonException('Connection closed'),
      );
    }
    _pendingRequests.clear();
  }

  /// Send a JSON-RPC request and wait for response
  Future<Map<String, dynamic>> _sendRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_socket == null) {
      throw const VpnDaemonException('Not connected to daemon');
    }

    final id = ++_requestId;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final request = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': id,
    };

    _socket!.write('${jsonEncode(request)}\n');

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw const VpnDaemonException('Request timed out');
      },
    );
  }

  // ===========================================================================
  // Server Mode Methods
  // ===========================================================================

  /// Start the VPN server with bootstrap config
  Future<Map<String, dynamic>> startServer(String config) async {
    return _sendRequest('start', {'config': config});
  }

  /// Stop the VPN server
  Future<Map<String, dynamic>> stopServer() async {
    return _sendRequest('stop', {});
  }

  /// Get server status
  Future<Map<String, dynamic>> getStatus() async {
    return _sendRequest('status', {});
  }

  /// Add a peer to the running server
  ///
  /// [publicKey] - Base64-encoded 32-byte public key
  /// [allowedIps] - List of allowed IPs in CIDR notation (e.g., ['10.0.0.2/32'])
  /// [presharedKey] - Optional base64-encoded 32-byte preshared key
  Future<AddPeerResult> addPeer({
    required String publicKey,
    required List<String> allowedIps,
    String? presharedKey,
  }) async {
    final result = await _sendRequest('add_peer', {
      'public_key': publicKey,
      'allowed_ips': allowedIps,
      if (presharedKey != null) 'preshared_key': presharedKey,
    });

    return AddPeerResult(
      added: result['added'] as bool? ?? false,
      publicKey: result['public_key'] as String? ?? publicKey,
    );
  }

  /// Remove a peer from the running server
  ///
  /// [publicKey] - Base64-encoded 32-byte public key
  Future<RemovePeerResult> removePeer(String publicKey) async {
    final result = await _sendRequest('remove_peer', {
      'public_key': publicKey,
    });

    return RemovePeerResult(
      removed: result['removed'] as bool? ?? false,
      publicKey: result['public_key'] as String? ?? publicKey,
      wasConnected: result['was_connected'] as bool? ?? false,
    );
  }

  /// List all configured peers
  Future<List<PeerInfo>> listPeers() async {
    final result = await _sendRequest('list_peers', {});
    final peers = result['peers'] as List<dynamic>? ?? [];

    return peers
        .map((p) => PeerInfo.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  /// Get status of a specific peer
  ///
  /// [publicKey] - Base64-encoded 32-byte public key
  Future<PeerInfo> getPeerStatus(String publicKey) async {
    final result = await _sendRequest('peer_status', {
      'public_key': publicKey,
    });

    return PeerInfo.fromJson(result);
  }
}

/// Exception thrown by VpnDaemonClient
class VpnDaemonException implements Exception {
  final String message;
  final int? code;

  const VpnDaemonException(this.message, {this.code});

  @override
  String toString() => code != null
      ? 'VpnDaemonException($code): $message'
      : 'VpnDaemonException: $message';
}

/// Result of add_peer operation
class AddPeerResult {
  final bool added;
  final String publicKey;

  AddPeerResult({required this.added, required this.publicKey});
}

/// Result of remove_peer operation
class RemovePeerResult {
  final bool removed;
  final String publicKey;
  final bool wasConnected;

  RemovePeerResult({
    required this.removed,
    required this.publicKey,
    required this.wasConnected,
  });
}

/// Information about a peer
class PeerInfo {
  final String publicKey;
  final List<String> allowedIps;
  final String? endpoint;
  final bool hasSession;
  final String? lastHandshake;
  final int bytesSent;
  final int bytesReceived;

  PeerInfo({
    required this.publicKey,
    required this.allowedIps,
    this.endpoint,
    required this.hasSession,
    this.lastHandshake,
    required this.bytesSent,
    required this.bytesReceived,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> json) {
    return PeerInfo(
      publicKey: json['public_key'] as String,
      allowedIps: (json['allowed_ips'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      endpoint: json['endpoint'] as String?,
      hasSession: json['has_session'] as bool? ?? false,
      lastHandshake: json['last_handshake'] as String?,
      bytesSent: json['bytes_sent'] as int? ?? 0,
      bytesReceived: json['bytes_received'] as int? ?? 0,
    );
  }
}
