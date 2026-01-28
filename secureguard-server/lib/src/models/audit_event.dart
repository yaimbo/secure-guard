/// Audit log event model
class AuditEvent {
  final int id;
  final DateTime timestamp;
  final String actorType; // admin, client, system
  final String? actorId;
  final String? actorName;
  final String eventType;
  final String? resourceType;
  final String? resourceId;
  final String? resourceName;
  final Map<String, dynamic>? details;
  final String? ipAddress;
  final String? userAgent;

  AuditEvent({
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

  factory AuditEvent.fromRow(Map<String, dynamic> row) {
    return AuditEvent(
      id: row['id'] as int,
      timestamp: row['timestamp'] as DateTime,
      actorType: row['actor_type'] as String,
      actorId: row['actor_id'] as String?,
      actorName: row['actor_name'] as String?,
      eventType: row['event_type'] as String,
      resourceType: row['resource_type'] as String?,
      resourceId: row['resource_id'] as String?,
      resourceName: row['resource_name'] as String?,
      details: row['details'] as Map<String, dynamic>?,
      ipAddress: row['ip_address'] as String?,
      userAgent: row['user_agent'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'actor_type': actorType,
      'actor_id': actorId,
      'actor_name': actorName,
      'event_type': eventType,
      'resource_type': resourceType,
      'resource_id': resourceId,
      'resource_name': resourceName,
      'details': details,
      'ip_address': ipAddress,
      'user_agent': userAgent,
    };
  }
}
