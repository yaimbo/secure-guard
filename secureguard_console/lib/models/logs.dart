// Audit Log Entry
class AuditLog {
  final int id;
  final DateTime timestamp;
  final String actorType;
  final String? actorId;
  final String? actorName;
  final String eventType;
  final String? resourceType;
  final String? resourceId;
  final String? resourceName;
  final Map<String, dynamic>? details;
  final String? ipAddress;
  final String? userAgent;

  AuditLog({
    required this.id,
    required this.timestamp,
    required this.actorType,
    this.actorId,
    this.actorName,
    required this.eventType,
    this.resourceType,
    this.resourceId,
    this.resourceName,
    this.details,
    this.ipAddress,
    this.userAgent,
  });

  factory AuditLog.fromJson(Map<String, dynamic> json) {
    return AuditLog(
      id: json['id'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      actorType: json['actor_type'] as String,
      actorId: json['actor_id'] as String?,
      actorName: json['actor_name'] as String?,
      eventType: json['event_type'] as String,
      resourceType: json['resource_type'] as String?,
      resourceId: json['resource_id'] as String?,
      resourceName: json['resource_name'] as String?,
      details: json['details'] as Map<String, dynamic>?,
      ipAddress: json['ip_address'] as String?,
      userAgent: json['user_agent'] as String?,
    );
  }
}

// Error Log Entry
class ErrorLog {
  final int id;
  final DateTime timestamp;
  final String severity;
  final String component;
  final String? clientId;
  final String? clientName;
  final String message;
  final String? stackTrace;
  final Map<String, dynamic>? details;

  ErrorLog({
    required this.id,
    required this.timestamp,
    required this.severity,
    required this.component,
    this.clientId,
    this.clientName,
    required this.message,
    this.stackTrace,
    this.details,
  });

  factory ErrorLog.fromJson(Map<String, dynamic> json) {
    return ErrorLog(
      id: json['id'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      severity: json['severity'] as String,
      component: json['component'] as String,
      clientId: json['client_id'] as String?,
      clientName: json['client_name'] as String?,
      message: json['message'] as String,
      stackTrace: json['stack_trace'] as String?,
      details: json['details'] as Map<String, dynamic>?,
    );
  }
}

// Connection Log Entry
class ConnectionLog {
  final int id;
  final String clientId;
  final String? clientName;
  final DateTime connectedAt;
  final DateTime? disconnectedAt;
  final int? durationSecs;
  final String? sourceIp;
  final int bytesSent;
  final int bytesReceived;
  final String? disconnectReason;

  ConnectionLog({
    required this.id,
    required this.clientId,
    this.clientName,
    required this.connectedAt,
    this.disconnectedAt,
    this.durationSecs,
    this.sourceIp,
    required this.bytesSent,
    required this.bytesReceived,
    this.disconnectReason,
  });

  factory ConnectionLog.fromJson(Map<String, dynamic> json) {
    return ConnectionLog(
      id: json['id'] as int,
      clientId: json['client_id'] as String,
      clientName: json['client_name'] as String?,
      connectedAt: DateTime.parse(json['connected_at'] as String),
      disconnectedAt: json['disconnected_at'] != null
          ? DateTime.parse(json['disconnected_at'] as String)
          : null,
      durationSecs: json['duration_secs'] as int?,
      sourceIp: json['source_ip'] as String?,
      bytesSent: json['bytes_sent'] as int? ?? 0,
      bytesReceived: json['bytes_received'] as int? ?? 0,
      disconnectReason: json['disconnect_reason'] as String?,
    );
  }
}
