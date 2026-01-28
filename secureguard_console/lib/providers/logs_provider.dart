import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/logs.dart';
import '../services/api_service.dart';

// Re-export log models for convenience
export '../models/logs.dart';

// Audit logs provider
final auditLogsProvider = FutureProvider<List<AuditLog>>((ref) async {
  final api = ref.read(apiServiceProvider);
  return api.getAuditLogs();
});

// Error logs provider
final errorLogsProvider = FutureProvider<List<ErrorLog>>((ref) async {
  final api = ref.read(apiServiceProvider);
  return api.getErrorLogs();
});

// Connection logs provider
final connectionLogsProvider = FutureProvider<List<ConnectionLog>>((ref) async {
  final api = ref.read(apiServiceProvider);
  return api.getConnectionLogs();
});

// Parameterized providers with filters
final filteredAuditLogsProvider = FutureProvider.family<List<AuditLog>, LogsFilter>((ref, filter) async {
  final api = ref.read(apiServiceProvider);
  return api.getAuditLogs(
    startDate: filter.startDate,
    endDate: filter.endDate,
    eventType: filter.eventType,
    search: filter.search,
  );
});

final filteredErrorLogsProvider = FutureProvider.family<List<ErrorLog>, LogsFilter>((ref, filter) async {
  final api = ref.read(apiServiceProvider);
  return api.getErrorLogs(
    startDate: filter.startDate,
    endDate: filter.endDate,
    severity: filter.severity,
    component: filter.component,
  );
});

final filteredConnectionLogsProvider = FutureProvider.family<List<ConnectionLog>, LogsFilter>((ref, filter) async {
  final api = ref.read(apiServiceProvider);
  return api.getConnectionLogs(
    startDate: filter.startDate,
    endDate: filter.endDate,
    clientId: filter.clientId,
  );
});

// Filter class
class LogsFilter {
  final DateTime? startDate;
  final DateTime? endDate;
  final String? eventType;
  final String? severity;
  final String? component;
  final String? clientId;
  final String? search;

  const LogsFilter({
    this.startDate,
    this.endDate,
    this.eventType,
    this.severity,
    this.component,
    this.clientId,
    this.search,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LogsFilter &&
        other.startDate == startDate &&
        other.endDate == endDate &&
        other.eventType == eventType &&
        other.severity == severity &&
        other.component == component &&
        other.clientId == clientId &&
        other.search == search;
  }

  @override
  int get hashCode {
    return Object.hash(
      startDate,
      endDate,
      eventType,
      severity,
      component,
      clientId,
      search,
    );
  }
}
