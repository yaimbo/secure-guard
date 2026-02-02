import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Client for communicating with the MinnowVPN Rust daemon via HTTP REST API.
///
/// This client enables the Dart REST API server to dynamically manage VPN peers
/// by sending HTTP requests to the Rust daemon's REST API.
///
/// **Port Convention:**
/// - Client mode daemon: `127.0.0.1:51820`
/// - Server mode daemon: `127.0.0.1:51821` (default for this client)
///
/// **Authentication:**
/// Uses Bearer token authentication. The token is read from a protected file:
/// - Unix: `/var/run/minnowvpn/auth-token`
/// - Windows: `C:\ProgramData\MinnowVPN\auth-token`
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
  /// Default HTTP port for server mode daemon
  /// Use 51820 if connecting to client mode daemon
  static const int defaultPort = 51821;

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

  VpnDaemonClient({this.host = '127.0.0.1', this.port = defaultPort});

  /// Whether currently connected to the daemon
  bool get isConnected => _httpClient != null && _authToken != null;

  /// Base URL for API requests
  String get _baseUrl => 'http://$host:$port/api/v1';

  /// Connect to the daemon (load token and verify connection)
  Future<void> connect() async {
    if (_httpClient != null) return;

    try {
      // Load auth token from file
      _authToken = await _loadAuthToken();
      if (_authToken == null) {
        throw const VpnDaemonException('Auth token not found');
      }

      _httpClient = http.Client();

      // Verify connection by getting status
      await getStatus();
    } catch (e) {
      _httpClient?.close();
      _httpClient = null;
      _authToken = null;
      throw VpnDaemonException('Failed to connect to daemon: $e');
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

  /// Disconnect from the daemon
  Future<void> disconnect() async {
    _httpClient?.close();
    _httpClient = null;
    _authToken = null;
  }

  /// Make an HTTP request with authentication
  Future<Map<String, dynamic>> _sendRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (_httpClient == null || _authToken == null) {
      throw const VpnDaemonException('Not connected to daemon');
    }

    final uri = Uri.parse('$_baseUrl$path');
    final headers = {
      'Authorization': 'Bearer $_authToken',
      'Content-Type': 'application/json',
    };

    http.Response response;

    try {
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
          throw VpnDaemonException('Unknown HTTP method: $method');
      }
    } catch (e) {
      throw VpnDaemonException('Request failed: $e');
    }

    if (response.statusCode == 401) {
      throw const VpnDaemonException('Unauthorized', code: 401);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode >= 400) {
      throw VpnDaemonException(
        json['message'] as String? ?? 'Request failed',
        code: json['code'] as int? ?? response.statusCode,
      );
    }

    return json;
  }

  // ===========================================================================
  // Server Mode Methods
  // ===========================================================================

  /// Start the VPN server with bootstrap config
  Future<Map<String, dynamic>> startServer(String config) async {
    return _sendRequest('POST', '/server/start', body: {'config': config});
  }

  /// Stop the VPN server
  Future<Map<String, dynamic>> stopServer() async {
    return _sendRequest('POST', '/server/stop');
  }

  /// Get server status
  Future<Map<String, dynamic>> getStatus() async {
    return _sendRequest('GET', '/status');
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
    final result = await _sendRequest('POST', '/server/peers', body: {
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
    // URL-encode the public key for path parameter
    final encodedKey = Uri.encodeComponent(publicKey);
    final result = await _sendRequest('DELETE', '/server/peers/$encodedKey');

    return RemovePeerResult(
      removed: result['removed'] as bool? ?? false,
      publicKey: result['public_key'] as String? ?? publicKey,
      wasConnected: result['was_connected'] as bool? ?? false,
    );
  }

  /// List all configured peers
  Future<List<PeerInfo>> listPeers() async {
    final result = await _sendRequest('GET', '/server/peers');
    final peers = result['peers'] as List<dynamic>? ?? [];

    return peers
        .map((p) => PeerInfo.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  /// Get status of a specific peer
  ///
  /// [publicKey] - Base64-encoded 32-byte public key
  Future<PeerInfo> getPeerStatus(String publicKey) async {
    // URL-encode the public key for path parameter
    final encodedKey = Uri.encodeComponent(publicKey);
    final result = await _sendRequest('GET', '/server/peers/$encodedKey');

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
