import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../repositories/client_repository.dart';
import '../../repositories/log_repository.dart';
import '../../services/redis_service.dart';

/// Dashboard API routes
class DashboardRoutes {
  final ClientRepository clientRepo;
  final LogRepository logRepo;
  final RedisService redis;

  DashboardRoutes({
    required this.clientRepo,
    required this.logRepo,
    required this.redis,
  });

  Router get router {
    final router = Router();

    router.get('/stats', _getStats);
    router.get('/active-clients', _getActiveClients);
    router.get('/activity', _getRecentActivity);
    router.get('/errors/summary', _getErrorSummary);
    router.get('/connections/history', _getConnectionHistory);

    return router;
  }

  /// GET /dashboard/stats
  /// Get dashboard statistics
  Future<Response> _getStats(Request request) async {
    try {
      // Get client counts
      final clientsResult = await clientRepo.list(limit: 1000);
      final clients = clientsResult['clients'] as List;
      final totalClients = clientsResult['pagination']['total'] as int;
      final activeClients =
          clients.where((c) => c['status'] == 'active').length;

      // Get online count from Redis
      final onlineCount = await redis.getOnlineClientCount();

      // Get connection stats
      final connectionStats = await logRepo.getConnectionStats();

      // Get bandwidth metrics from Redis counters (if available)
      int uploadRate = 0;
      int downloadRate = 0;
      if (redis.isConnected) {
        uploadRate = await redis.getCounter(RedisMetrics.bandwidthTx);
        downloadRate = await redis.getCounter(RedisMetrics.bandwidthRx);
      }

      return Response.ok(
        jsonEncode({
          'active_connections': onlineCount,
          'total_clients': totalClients,
          'active_clients': activeClients,
          'bandwidth': {
            'upload_rate': uploadRate,
            'download_rate': downloadRate,
          },
          'total_bytes_sent': connectionStats['bytes_sent_today'] ?? 0,
          'total_bytes_received': connectionStats['bytes_received_today'] ?? 0,
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get dashboard stats: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// GET /dashboard/active-clients
  /// Get list of active/online clients
  Future<Response> _getActiveClients(Request request) async {
    try {
      final limitStr = request.url.queryParameters['limit'] ?? '10';
      final limit = int.tryParse(limitStr) ?? 10;

      // Get online client IDs from Redis
      final onlineIds = await redis.getOnlineClients();

      // Fetch client details
      final activeClients = <Map<String, dynamic>>[];

      for (final clientId in onlineIds.take(limit)) {
        try {
          final client = await clientRepo.getById(clientId);
          if (client != null) {
            activeClients.add({
              'id': client.id,
              'name': client.name,
              'assigned_ip': client.assignedIp,
              'is_online': true,
              'last_seen': client.lastSeenAt?.toIso8601String(),
              'bytes_sent': 0,
              'bytes_received': 0,
            });
          }
        } catch (e) {
          // Skip clients that can't be fetched
        }
      }

      // If not enough online clients, add some recently active ones
      if (activeClients.length < limit) {
        final remaining = limit - activeClients.length;
        final clientsResult = await clientRepo.list(
          limit: remaining,
          status: 'active',
        );
        final clients = clientsResult['clients'] as List;

        for (final client in clients) {
          final clientId = client['id'] as String;
          if (!onlineIds.contains(clientId)) {
            activeClients.add({
              'id': clientId,
              'name': client['name'],
              'assigned_ip': client['assigned_ip'],
              'is_online': false,
              'last_seen': client['last_seen_at']?.toString(),
              'bytes_sent': 0,
              'bytes_received': 0,
            });
          }
        }
      }

      return Response.ok(
        jsonEncode({'clients': activeClients}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get active clients: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// GET /dashboard/activity
  /// Get recent activity events
  Future<Response> _getRecentActivity(Request request) async {
    try {
      final limitStr = request.url.queryParameters['limit'] ?? '10';
      final limit = int.tryParse(limitStr) ?? 10;

      // Get recent audit log entries
      final auditResult = await logRepo.queryAuditLog(limit: limit);
      final auditEvents = auditResult['events'] as List;

      // Get recent connection events
      final connectionResult = await logRepo.queryConnectionLog(limit: limit);
      final connectionLogs = connectionResult['connections'] as List;

      // Combine and sort by timestamp
      final events = <Map<String, dynamic>>[];

      for (final log in auditEvents) {
        events.add({
          'id': log['id']?.toString() ?? '',
          'type': _mapEventType(log['event_type'] as String?),
          'title': _formatAuditTitle(log),
          'client_id': log['resource_id']?.toString(),
          'client_name': log['resource_name'] as String?,
          'timestamp': log['timestamp']?.toString() ??
              DateTime.now().toIso8601String(),
        });
      }

      for (final log in connectionLogs) {
        final disconnectedAt = log['disconnected_at'];
        events.add({
          'id': log['id']?.toString() ?? '',
          'type': disconnectedAt != null ? 'disconnected' : 'connected',
          'title': '${log['client_name'] ?? 'Unknown'} ${disconnectedAt != null ? 'disconnected' : 'connected'}',
          'client_id': log['client_id']?.toString(),
          'client_name': log['client_name'] as String?,
          'timestamp': (disconnectedAt ?? log['connected_at'])?.toString() ??
              DateTime.now().toIso8601String(),
        });
      }

      // Sort by timestamp descending
      events.sort((a, b) {
        final aTime = DateTime.tryParse(a['timestamp'] as String) ?? DateTime.now();
        final bTime = DateTime.tryParse(b['timestamp'] as String) ?? DateTime.now();
        return bTime.compareTo(aTime);
      });

      return Response.ok(
        jsonEncode({'events': events.take(limit).toList()}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get recent activity: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  String _mapEventType(String? eventType) {
    if (eventType == null) return 'unknown';
    if (eventType.contains('connect')) return 'connected';
    if (eventType.contains('disconnect')) return 'disconnected';
    if (eventType.contains('rekey')) return 'rekeyed';
    if (eventType.contains('config')) return 'config_updated';
    if (eventType.contains('error')) return 'error';
    return 'audit';
  }

  String _formatAuditTitle(Map<String, dynamic> log) {
    final actorName = log['actor_name'] as String? ?? 'System';
    final eventType = log['event_type'] as String? ?? 'action';
    final resourceName = log['resource_name'] as String?;

    if (resourceName != null) {
      return '$actorName: $eventType on $resourceName';
    }
    return '$actorName: $eventType';
  }

  /// GET /dashboard/errors/summary
  /// Get error counts by type
  Future<Response> _getErrorSummary(Request request) async {
    try {
      final errorCounts = await logRepo.getErrorCountsBySeverity();

      return Response.ok(
        jsonEncode(errorCounts),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get error summary: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }

  /// GET /dashboard/connections/history
  /// Get connection count history for charts
  Future<Response> _getConnectionHistory(Request request) async {
    try {
      final hoursStr = request.url.queryParameters['hours'] ?? '24';
      final hours = int.tryParse(hoursStr) ?? 24;

      // Try to get metrics from Redis first
      List<Map<String, dynamic>> dataPoints = [];

      if (redis.isConnected) {
        final now = DateTime.now();
        final startTime = now.subtract(Duration(hours: hours));

        // Get connection count metrics from Redis time series
        final metrics = await redis.getMetrics(
          RedisMetrics.connectionCount,
          start: startTime,
          end: now,
        );

        for (final point in metrics) {
          dataPoints.add({
            'timestamp': point.timestamp.toIso8601String(),
            'active_connections': point.value.toInt(),
            'bytes_sent': 0,
            'bytes_received': 0,
          });
        }
      }

      // If no Redis data, generate sample data from connection log
      if (dataPoints.isEmpty) {
        final connectionResult = await logRepo.queryConnectionLog(limit: 100);
        final connections = connectionResult['connections'] as List;

        // Group connections by hour
        final hourlyData = <int, int>{};
        final now = DateTime.now();

        for (var i = 0; i < hours; i++) {
          final hourTimestamp = now.subtract(Duration(hours: i));
          hourlyData[hourTimestamp.hour] = 0;
        }

        for (final conn in connections) {
          final connectedAt = conn['connected_at'] != null
              ? DateTime.tryParse(conn['connected_at'].toString())
              : null;
          if (connectedAt != null) {
            final hour = connectedAt.hour;
            hourlyData[hour] = (hourlyData[hour] ?? 0) + 1;
          }
        }

        // Convert to data points
        for (var i = hours - 1; i >= 0; i--) {
          final timestamp = now.subtract(Duration(hours: i));
          dataPoints.add({
            'timestamp': timestamp.toIso8601String(),
            'active_connections': hourlyData[timestamp.hour] ?? 0,
            'bytes_sent': 0,
            'bytes_received': 0,
          });
        }
      }

      return Response.ok(
        jsonEncode({'data': dataPoints}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get connection history: $e'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  }
}
