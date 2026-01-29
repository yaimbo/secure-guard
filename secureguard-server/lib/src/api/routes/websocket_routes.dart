import 'dart:async';
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../services/redis_service.dart';
import '../../repositories/client_repository.dart';
import '../../repositories/log_repository.dart';

/// WebSocket routes for real-time dashboard updates
class WebSocketRoutes {
  final RedisService redis;
  final ClientRepository clientRepo;
  final LogRepository logRepo;
  final String jwtSecret;
  final _log = Logger('WebSocketRoutes');

  final _dashboardClients = <WebSocketChannel>[];
  Timer? _metricsTimer;

  WebSocketRoutes({
    required this.redis,
    required this.clientRepo,
    required this.logRepo,
    required this.jwtSecret,
  }) {
    _startMetricsBroadcast();
    _subscribeToRedisChannels();
  }

  /// Router for WebSocket endpoints
  Router get router {
    final router = Router();

    // Dashboard real-time updates (requires token query param)
    router.get('/dashboard', _authenticatedDashboardHandler);

    return router;
  }

  /// Authenticate WebSocket connection via token query parameter
  Future<Response> _authenticatedDashboardHandler(Request request) async {
    // WebSocket connections can't use Authorization header during upgrade,
    // so we accept token as a query parameter
    final token = request.url.queryParameters['token'];

    if (token == null || token.isEmpty) {
      return Response(401,
          body: jsonEncode({'error': 'Missing token parameter'}),
          headers: {'content-type': 'application/json'});
    }

    try {
      // Verify JWT token
      JWT.verify(token, SecretKey(jwtSecret));
      // Token is valid, upgrade to WebSocket
      return dashboardHandler(request);
    } on JWTExpiredException {
      return Response(401,
          body: jsonEncode({'error': 'Token expired'}),
          headers: {'content-type': 'application/json'});
    } on JWTException catch (e) {
      return Response(401,
          body: jsonEncode({'error': 'Invalid token: ${e.message}'}),
          headers: {'content-type': 'application/json'});
    }
  }

  /// WebSocket handler for dashboard streaming
  Handler get dashboardHandler => webSocketHandler(_handleDashboardConnection);

  void _handleDashboardConnection(WebSocketChannel webSocket) {
    _log.info('Dashboard WebSocket client connected');
    _dashboardClients.add(webSocket);

    // Send initial state
    _sendInitialState(webSocket);

    // Listen for client messages (ping/pong, subscriptions)
    webSocket.stream.listen(
      (message) => _handleClientMessage(webSocket, message),
      onDone: () {
        _log.info('Dashboard WebSocket client disconnected');
        _dashboardClients.remove(webSocket);
      },
      onError: (error) {
        _log.warning('Dashboard WebSocket error: $error');
        _dashboardClients.remove(webSocket);
      },
    );
  }

  void _handleClientMessage(WebSocketChannel webSocket, dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case 'ping':
          webSocket.sink.add(jsonEncode({'type': 'pong'}));
          break;
        case 'subscribe':
          // Handle specific subscriptions if needed
          break;
      }
    } catch (e) {
      _log.warning('Failed to handle client message: $e');
    }
  }

  Future<void> _sendInitialState(WebSocketChannel webSocket) async {
    try {
      // Fetch current stats
      final stats = await _gatherDashboardStats();
      webSocket.sink.add(jsonEncode({
        'type': 'initial_state',
        'data': stats,
      }));
    } catch (e) {
      _log.warning('Failed to send initial state: $e');
    }
  }

  Future<Map<String, dynamic>> _gatherDashboardStats() async {
    // Get client counts
    final clientsResult = await clientRepo.list(limit: 1000);
    final clients = clientsResult['clients'] as List;
    final totalClients = clientsResult['pagination']['total'] as int;
    final activeClients = clients.where((c) => c['status'] == 'active').length;

    // Get online count from Redis
    final onlineCount = await redis.getOnlineClientCount();

    // Get connection stats from database
    final connectionStats = await logRepo.getConnectionStats();

    // Get error counts by severity
    final errorSummary = await logRepo.getErrorCountsBySeverity();

    // Get recent connection activity
    final recentConnectionsResult = await logRepo.queryConnectionLog(limit: 10);
    final recentConnections = recentConnectionsResult['connections'] as List;

    return {
      'active_connections': onlineCount,
      'total_clients': totalClients,
      'active_clients': activeClients,
      'bandwidth': {
        'upload_rate': connectionStats['total_bytes_sent'] ?? 0,
        'download_rate': connectionStats['total_bytes_received'] ?? 0,
      },
      'connection_stats': connectionStats,
      'error_summary': errorSummary,
      'recent_connections': recentConnections,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  void _startMetricsBroadcast() {
    // Broadcast metrics every 10 seconds
    _metricsTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_dashboardClients.isEmpty) return;

      try {
        final stats = await _gatherDashboardStats();
        _broadcastToDashboard({
          'type': 'metrics_update',
          'data': stats,
        });
      } catch (e) {
        _log.warning('Failed to broadcast metrics: $e');
      }
    });
  }

  void _subscribeToRedisChannels() {
    if (!redis.isConnected) return;

    // Subscribe to connection events
    redis.subscribe(RedisChannels.connections).listen((event) {
      _broadcastToDashboard({
        'type': 'connection_event',
        'data': event,
      });
    });

    // Subscribe to error events
    redis.subscribe(RedisChannels.errors).listen((event) {
      _broadcastToDashboard({
        'type': 'error_event',
        'data': event,
      });
    });

    // Subscribe to audit events
    redis.subscribe(RedisChannels.audit).listen((event) {
      _broadcastToDashboard({
        'type': 'audit_event',
        'data': event,
      });
    });
  }

  void _broadcastToDashboard(Map<String, dynamic> message) {
    final json = jsonEncode(message);
    final deadClients = <WebSocketChannel>[];

    for (final client in _dashboardClients) {
      try {
        client.sink.add(json);
      } catch (e) {
        deadClients.add(client);
      }
    }

    // Clean up dead clients
    for (final client in deadClients) {
      _dashboardClients.remove(client);
    }
  }

  /// Publish an event to connected dashboard clients
  void publishEvent(String type, Map<String, dynamic> data) {
    _broadcastToDashboard({
      'type': type,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // Also publish to Redis for other server instances
    if (redis.isConnected) {
      final channel = switch (type) {
        'connection_event' => RedisChannels.connections,
        'error_event' => RedisChannels.errors,
        'audit_event' => RedisChannels.audit,
        _ => RedisChannels.metrics,
      };
      redis.publish(channel, data);
    }
  }

  void dispose() {
    _metricsTimer?.cancel();
    for (final client in _dashboardClients) {
      client.sink.close();
    }
    _dashboardClients.clear();
  }
}
