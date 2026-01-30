import 'dart:convert';

import '../database/database.dart';
import '../database/postgres_utils.dart';
import '../models/audit_event.dart';

/// Repository for audit, error, and connection logs
class LogRepository {
  final Database db;

  LogRepository(this.db);

  // ═══════════════════════════════════════════════════════════════════
  // AUDIT LOG
  // ═══════════════════════════════════════════════════════════════════

  /// Log an audit event
  Future<void> auditLog({
    required String actorType,
    String? actorId,
    String? actorName,
    required String eventType,
    String severity = 'INFO',
    String? resourceType,
    String? resourceId,
    String? resourceName,
    Map<String, dynamic>? details,
    String? ipAddress,
    String? userAgent,
  }) async {
    await db.execute('''
      INSERT INTO audit_log (
        actor_type, actor_id, actor_name, event_type, severity,
        resource_type, resource_id, resource_name,
        details, ip_address, user_agent
      ) VALUES (
        @actor_type, @actor_id::uuid, @actor_name, @event_type, @severity,
        @resource_type, @resource_id::uuid, @resource_name,
        @details::jsonb, @ip_address::inet, @user_agent
      )
    ''', {
      'actor_type': actorType,
      'actor_id': actorId,
      'actor_name': actorName,
      'event_type': eventType,
      'severity': severity,
      'resource_type': resourceType,
      'resource_id': resourceId,
      'resource_name': resourceName,
      'details': details != null ? jsonEncode(details) : null,
      'ip_address': ipAddress,
      'user_agent': userAgent,
    });
  }

  /// Query audit log with filters
  Future<Map<String, dynamic>> queryAuditLog({
    DateTime? startDate,
    DateTime? endDate,
    String? eventType,
    String? severity,
    String? actorType,
    String? actorId,
    String? resourceType,
    String? resourceId,
    String? search,
    int page = 1,
    int limit = 50,
  }) async {
    final offset = (page - 1) * limit;
    final whereClauses = <String>[];
    final whereParams = <String, dynamic>{};

    if (startDate != null) {
      whereClauses.add('timestamp >= @start_date');
      whereParams['start_date'] = startDate;
    }

    if (endDate != null) {
      whereClauses.add('timestamp <= @end_date');
      whereParams['end_date'] = endDate;
    }

    if (eventType != null) {
      whereClauses.add('event_type = @event_type');
      whereParams['event_type'] = eventType;
    }

    if (severity != null) {
      // Severity filtering with hierarchy: ALERT > WARNING > INFO
      // - ALERT: show only ALERT
      // - WARNING: show WARNING and ALERT
      // - INFO: show all (INFO, WARNING, ALERT)
      if (severity == 'ALERT') {
        whereClauses.add("severity = 'ALERT'");
      } else if (severity == 'WARNING') {
        whereClauses.add("severity IN ('WARNING', 'ALERT')");
      }
      // severity == 'INFO' means show all, so no filter needed
    }

    if (actorType != null) {
      whereClauses.add('actor_type = @actor_type');
      whereParams['actor_type'] = actorType;
    }

    if (actorId != null) {
      whereClauses.add('actor_id = @actor_id::uuid');
      whereParams['actor_id'] = actorId;
    }

    if (resourceType != null) {
      whereClauses.add('resource_type = @resource_type');
      whereParams['resource_type'] = resourceType;
    }

    if (resourceId != null) {
      whereClauses.add('resource_id = @resource_id::uuid');
      whereParams['resource_id'] = resourceId;
    }

    if (search != null && search.isNotEmpty) {
      whereClauses.add('''
        (event_type ILIKE @search
         OR actor_name ILIKE @search
         OR resource_name ILIKE @search
         OR details::text ILIKE @search)
      ''');
      whereParams['search'] = '%$search%';
    }

    final whereClause =
        whereClauses.isEmpty ? '' : 'WHERE ${whereClauses.join(' AND ')}';

    // Get total count (only pass where params)
    final countResult = await db.execute(
      'SELECT COUNT(*) FROM audit_log $whereClause',
      whereParams.isEmpty ? null : whereParams,
    );
    final total = countResult.first[0] as int;

    // Get page of events (include limit and offset)
    final queryParams = <String, dynamic>{
      ...whereParams,
      'limit': limit,
      'offset': offset,
    };

    final result = await db.execute('''
      SELECT * FROM audit_log
      $whereClause
      ORDER BY timestamp DESC
      LIMIT @limit OFFSET @offset
    ''', queryParams);

    final events =
        result.map((row) => AuditEvent.fromRow(row.toColumnMap())).toList();

    return {
      'events': events.map((e) => e.toJson()).toList(),
      'pagination': {
        'page': page,
        'limit': limit,
        'total': total,
        'total_pages': (total / limit).ceil(),
      },
    };
  }

  /// Get distinct event types for filter dropdown
  Future<List<String>> getAuditEventTypes() async {
    final result = await db.execute('''
      SELECT DISTINCT event_type FROM audit_log ORDER BY event_type
    ''');
    return result.map((row) => row[0] as String).toList();
  }

  // ═══════════════════════════════════════════════════════════════════
  // ERROR LOG
  // ═══════════════════════════════════════════════════════════════════

  /// Log an error
  Future<void> errorLog({
    required String severity,
    required String component,
    String? clientId,
    required String message,
    String? stackTrace,
    Map<String, dynamic>? details,
  }) async {
    await db.execute('''
      INSERT INTO error_log (
        severity, component, client_id, message, stack_trace, details
      ) VALUES (
        @severity, @component, @client_id::uuid, @message, @stack_trace, @details::jsonb
      )
    ''', {
      'severity': severity,
      'component': component,
      'client_id': clientId,
      'message': message,
      'stack_trace': stackTrace,
      'details': details != null ? jsonEncode(details) : null,
    });
  }

  /// Query error log
  Future<Map<String, dynamic>> queryErrorLog({
    DateTime? startDate,
    DateTime? endDate,
    String? severity,
    String? component,
    String? clientId,
    int page = 1,
    int limit = 50,
  }) async {
    final offset = (page - 1) * limit;
    final whereClauses = <String>[];
    final whereParams = <String, dynamic>{};

    if (startDate != null) {
      whereClauses.add('timestamp >= @start_date');
      whereParams['start_date'] = startDate;
    }

    if (endDate != null) {
      whereClauses.add('timestamp <= @end_date');
      whereParams['end_date'] = endDate;
    }

    if (severity != null) {
      whereClauses.add('severity = @severity');
      whereParams['severity'] = severity;
    }

    if (component != null) {
      whereClauses.add('component = @component');
      whereParams['component'] = component;
    }

    if (clientId != null) {
      whereClauses.add('client_id = @client_id::uuid');
      whereParams['client_id'] = clientId;
    }

    final whereClause =
        whereClauses.isEmpty ? '' : 'WHERE ${whereClauses.join(' AND ')}';

    // Get total count (only pass where params)
    final countResult = await db.execute(
      'SELECT COUNT(*) FROM error_log $whereClause',
      whereParams.isEmpty ? null : whereParams,
    );
    final total = countResult.first[0] as int;

    // Get page of errors (include limit and offset)
    final queryParams = <String, dynamic>{
      ...whereParams,
      'limit': limit,
      'offset': offset,
    };

    final result = await db.execute('''
      SELECT * FROM error_log
      $whereClause
      ORDER BY timestamp DESC
      LIMIT @limit OFFSET @offset
    ''', queryParams);

    final errors = result.map((row) => row.toColumnMap()).toList();

    return {
      'errors': errors,
      'pagination': {
        'page': page,
        'limit': limit,
        'total': total,
        'total_pages': (total / limit).ceil(),
      },
    };
  }

  /// Get error counts by severity in last 24 hours
  Future<Map<String, int>> getErrorCountsBySeverity() async {
    final result = await db.execute('''
      SELECT severity, COUNT(*) as count
      FROM error_log
      WHERE timestamp > NOW() - INTERVAL '24 hours'
      GROUP BY severity
    ''');

    return {for (var row in result) row[0] as String: row[1] as int};
  }

  // ═══════════════════════════════════════════════════════════════════
  // CONNECTION LOG
  // ═══════════════════════════════════════════════════════════════════

  /// Log a connection start
  Future<int> connectionStart({
    required String clientId,
    required String sourceIp,
  }) async {
    final result = await db.execute('''
      INSERT INTO connection_log (client_id, connected_at, source_ip)
      VALUES (@client_id::uuid, NOW(), @source_ip::inet)
      RETURNING id
    ''', {
      'client_id': clientId,
      'source_ip': sourceIp,
    });
    return result.first[0] as int;
  }

  /// Log a connection end
  Future<void> connectionEnd({
    required int connectionId,
    int? bytesSent,
    int? bytesReceived,
    String? disconnectReason,
  }) async {
    await db.execute('''
      UPDATE connection_log
      SET disconnected_at = NOW(),
          duration_secs = EXTRACT(EPOCH FROM (NOW() - connected_at))::int,
          bytes_sent = @bytes_sent,
          bytes_received = @bytes_received,
          disconnect_reason = @disconnect_reason
      WHERE id = @id
    ''', {
      'id': connectionId,
      'bytes_sent': bytesSent,
      'bytes_received': bytesReceived,
      'disconnect_reason': disconnectReason,
    });
  }

  /// Query connection log
  Future<Map<String, dynamic>> queryConnectionLog({
    String? clientId,
    DateTime? startDate,
    DateTime? endDate,
    int page = 1,
    int limit = 50,
  }) async {
    final offset = (page - 1) * limit;
    final whereClauses = <String>[];
    final whereParams = <String, dynamic>{};

    if (clientId != null) {
      whereClauses.add('cl.client_id = @client_id::uuid');
      whereParams['client_id'] = clientId;
    }

    if (startDate != null) {
      whereClauses.add('cl.connected_at >= @start_date');
      whereParams['start_date'] = startDate;
    }

    if (endDate != null) {
      whereClauses.add('cl.connected_at <= @end_date');
      whereParams['end_date'] = endDate;
    }

    final whereClause =
        whereClauses.isEmpty ? '' : 'WHERE ${whereClauses.join(' AND ')}';

    // Get total count (only pass where params)
    // Use a simpler count query without join
    final countWhereClause = whereClauses.isEmpty
        ? ''
        : 'WHERE ${whereClauses.map((c) => c.replaceAll('cl.', '')).join(' AND ')}';
    final countResult = await db.execute(
      'SELECT COUNT(*) FROM connection_log $countWhereClause',
      whereParams.isEmpty ? null : whereParams,
    );
    final total = countResult.first[0] as int;

    // Get page of connections with client name (include limit and offset)
    final queryParams = <String, dynamic>{
      ...whereParams,
      'limit': limit,
      'offset': offset,
    };

    final result = await db.execute('''
      SELECT cl.*, c.name as client_name
      FROM connection_log cl
      JOIN clients c ON c.id = cl.client_id
      $whereClause
      ORDER BY cl.connected_at DESC
      LIMIT @limit OFFSET @offset
    ''', queryParams);

    // Convert source_ip INET binary to string
    final connections = result.map((row) {
      final map = row.toColumnMap();
      if (map['source_ip'] != null) {
        map['source_ip'] = pgToString(map['source_ip']);
      }
      return map;
    }).toList();

    return {
      'connections': connections,
      'pagination': {
        'page': page,
        'limit': limit,
        'total': total,
        'total_pages': (total / limit).ceil(),
      },
    };
  }

  /// Get active connection count
  Future<int> getActiveConnectionCount() async {
    final result = await db.execute('''
      SELECT COUNT(*) FROM connection_log WHERE disconnected_at IS NULL
    ''');
    return result.first[0] as int;
  }

  /// Get connection stats for dashboard
  Future<Map<String, dynamic>> getConnectionStats() async {
    // Total connections today
    final todayResult = await db.execute('''
      SELECT COUNT(*) FROM connection_log
      WHERE connected_at >= CURRENT_DATE
    ''');
    final todayCount = todayResult.first[0] as int;

    // Active now
    final activeResult = await db.execute('''
      SELECT COUNT(*) FROM connection_log WHERE disconnected_at IS NULL
    ''');
    final activeCount = activeResult.first[0] as int;

    // Total bandwidth today
    final bandwidthResult = await db.execute('''
      SELECT COALESCE(SUM(bytes_sent), 0), COALESCE(SUM(bytes_received), 0)
      FROM connection_log
      WHERE connected_at >= CURRENT_DATE
    ''');
    final bytesSent = bandwidthResult.first[0] as int;
    final bytesReceived = bandwidthResult.first[1] as int;

    return {
      'connections_today': todayCount,
      'active_connections': activeCount,
      'bytes_sent_today': bytesSent,
      'bytes_received_today': bytesReceived,
    };
  }
}
