import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../repositories/log_repository.dart';

/// Log query routes (admin only)
class LogRoutes {
  final LogRepository logRepo;

  LogRoutes(this.logRepo);

  Router get router {
    final router = Router();

    router.get('/audit', _queryAuditLog);
    router.get('/audit/types', _getAuditEventTypes);
    router.get('/errors', _queryErrorLog);
    router.get('/errors/summary', _getErrorSummary);
    router.get('/connections', _queryConnectionLog);
    router.get('/connections/stats', _getConnectionStats);
    router.get('/export', _exportLogs);

    return router;
  }

  /// Query audit log
  /// GET /api/v1/logs/audit
  Future<Response> _queryAuditLog(Request request) async {
    try {
      final params = request.url.queryParameters;

      final result = await logRepo.queryAuditLog(
        startDate: params['start_date'] != null
            ? DateTime.parse(params['start_date']!)
            : null,
        endDate: params['end_date'] != null
            ? DateTime.parse(params['end_date']!)
            : null,
        eventType: params['event_type'],
        actorType: params['actor_type'],
        actorId: params['actor_id'],
        resourceType: params['resource_type'],
        resourceId: params['resource_id'],
        search: params['search'],
        page: int.tryParse(params['page'] ?? '1') ?? 1,
        limit: int.tryParse(params['limit'] ?? '50') ?? 50,
      );

      return Response.ok(
        jsonEncode(result),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to query audit log: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Get distinct audit event types
  /// GET /api/v1/logs/audit/types
  Future<Response> _getAuditEventTypes(Request request) async {
    try {
      final types = await logRepo.getAuditEventTypes();

      return Response.ok(
        jsonEncode({'event_types': types}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get event types: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Query error log
  /// GET /api/v1/logs/errors
  Future<Response> _queryErrorLog(Request request) async {
    try {
      final params = request.url.queryParameters;

      final result = await logRepo.queryErrorLog(
        startDate: params['start_date'] != null
            ? DateTime.parse(params['start_date']!)
            : null,
        endDate: params['end_date'] != null
            ? DateTime.parse(params['end_date']!)
            : null,
        severity: params['severity'],
        component: params['component'],
        clientId: params['client_id'],
        page: int.tryParse(params['page'] ?? '1') ?? 1,
        limit: int.tryParse(params['limit'] ?? '50') ?? 50,
      );

      return Response.ok(
        jsonEncode(result),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to query error log: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Get error counts by severity (last 24h)
  /// GET /api/v1/logs/errors/summary
  Future<Response> _getErrorSummary(Request request) async {
    try {
      final counts = await logRepo.getErrorCountsBySeverity();

      return Response.ok(
        jsonEncode({'counts': counts}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get error summary: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Query connection log
  /// GET /api/v1/logs/connections
  Future<Response> _queryConnectionLog(Request request) async {
    try {
      final params = request.url.queryParameters;

      final result = await logRepo.queryConnectionLog(
        clientId: params['client_id'],
        startDate: params['start_date'] != null
            ? DateTime.parse(params['start_date']!)
            : null,
        endDate: params['end_date'] != null
            ? DateTime.parse(params['end_date']!)
            : null,
        page: int.tryParse(params['page'] ?? '1') ?? 1,
        limit: int.tryParse(params['limit'] ?? '50') ?? 50,
      );

      return Response.ok(
        jsonEncode(result),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to query connection log: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Get connection stats for dashboard
  /// GET /api/v1/logs/connections/stats
  Future<Response> _getConnectionStats(Request request) async {
    try {
      final stats = await logRepo.getConnectionStats();

      return Response.ok(
        jsonEncode(stats),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get connection stats: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Export logs (CSV or JSON)
  /// GET /api/v1/logs/export
  Future<Response> _exportLogs(Request request) async {
    try {
      final params = request.url.queryParameters;
      final logType = params['type'] ?? 'audit'; // audit, errors, connections
      final format = params['format'] ?? 'json'; // json, csv
      final limit = int.tryParse(params['limit'] ?? '1000') ?? 1000;

      Map<String, dynamic> data;

      switch (logType) {
        case 'audit':
          data = await logRepo.queryAuditLog(
            startDate: params['start_date'] != null
                ? DateTime.parse(params['start_date']!)
                : null,
            endDate: params['end_date'] != null
                ? DateTime.parse(params['end_date']!)
                : null,
            limit: limit,
          );
          break;
        case 'errors':
          data = await logRepo.queryErrorLog(
            startDate: params['start_date'] != null
                ? DateTime.parse(params['start_date']!)
                : null,
            endDate: params['end_date'] != null
                ? DateTime.parse(params['end_date']!)
                : null,
            limit: limit,
          );
          break;
        case 'connections':
          data = await logRepo.queryConnectionLog(
            startDate: params['start_date'] != null
                ? DateTime.parse(params['start_date']!)
                : null,
            endDate: params['end_date'] != null
                ? DateTime.parse(params['end_date']!)
                : null,
            limit: limit,
          );
          break;
        default:
          return Response(400,
              body: jsonEncode({'error': 'Invalid log type'}),
              headers: {'content-type': 'application/json'});
      }

      if (format == 'csv') {
        final csv = _toCsv(data);
        return Response.ok(
          csv,
          headers: {
            'content-type': 'text/csv',
            'content-disposition': 'attachment; filename="$logType-export.csv"',
          },
        );
      }

      return Response.ok(
        jsonEncode(data),
        headers: {
          'content-type': 'application/json',
          'content-disposition': 'attachment; filename="$logType-export.json"',
        },
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to export logs: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Convert data to CSV format
  String _toCsv(Map<String, dynamic> data) {
    final items = data['events'] ?? data['errors'] ?? data['connections'] ?? [];
    if (items.isEmpty) return '';

    final List<Map<String, dynamic>> rows = List.from(items);
    if (rows.isEmpty) return '';

    // Get headers from first row
    final headers = rows.first.keys.toList();

    final buffer = StringBuffer();

    // Header row
    buffer.writeln(headers.map(_escapeCsv).join(','));

    // Data rows
    for (final row in rows) {
      buffer.writeln(headers.map((h) => _escapeCsv(row[h]?.toString() ?? '')).join(','));
    }

    return buffer.toString();
  }

  String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
