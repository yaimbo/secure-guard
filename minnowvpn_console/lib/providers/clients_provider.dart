import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/client.dart';
import '../models/logs.dart';
import '../services/api_service.dart';

// Re-export Client, EnrollmentCode, SecurityAlerts, AuditLog, and ActiveClient for convenience
export '../models/client.dart';
export '../models/logs.dart' show AuditLog;
export '../services/api_service.dart' show EnrollmentCode, SecurityAlerts, ActiveClient;

// Clients list provider
final clientsProvider = StateNotifierProvider<ClientsNotifier, AsyncValue<List<Client>>>((ref) {
  return ClientsNotifier(ref);
});

class ClientsNotifier extends StateNotifier<AsyncValue<List<Client>>> {
  final Ref _ref;
  String? _searchQuery;
  String? _statusFilter;

  ClientsNotifier(this._ref) : super(const AsyncValue.loading()) {
    _loadClients();
  }

  Future<void> _loadClients() async {
    state = const AsyncValue.loading();
    try {
      final api = _ref.read(apiServiceProvider);
      final clients = await api.getClients(
        search: _searchQuery,
        status: _statusFilter,
      );
      state = AsyncValue.data(clients);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() async {
    await _loadClients();
  }

  void search(String query) {
    _searchQuery = query.isEmpty ? null : query;
    _loadClients();
  }

  void filterByStatus(String? status) {
    _statusFilter = status == 'all' ? null : status;
    _loadClients();
  }

  Future<void> createClient({
    required String name,
    String? description,
    String? userEmail,
  }) async {
    final api = _ref.read(apiServiceProvider);
    await api.createClient(
      name: name,
      description: description,
      userEmail: userEmail,
    );
    await _loadClients();
  }

  Future<void> updateClient(String id, {
    String? name,
    String? description,
    String? userEmail,
  }) async {
    final api = _ref.read(apiServiceProvider);
    await api.updateClient(
      id,
      name: name,
      description: description,
      userEmail: userEmail,
    );
    await _loadClients();
  }

  Future<void> deleteClient(String id) async {
    final api = _ref.read(apiServiceProvider);
    await api.deleteClient(id);
    await _loadClients();
  }

  Future<void> enableClient(String id) async {
    final api = _ref.read(apiServiceProvider);
    await api.enableClient(id);
    await _loadClients();
  }

  Future<void> disableClient(String id) async {
    final api = _ref.read(apiServiceProvider);
    await api.disableClient(id);
    await _loadClients();
  }

  Future<void> downloadConfig(String id) async {
    final api = _ref.read(apiServiceProvider);
    await api.downloadClientConfig(id);
  }
}

// Single client provider
final clientDetailProvider = FutureProvider.family<Client, String>((ref, id) async {
  final api = ref.read(apiServiceProvider);
  return api.getClient(id);
});

// QR code provider
final clientQrCodeProvider = FutureProvider.family<Uint8List, String>((ref, id) async {
  final api = ref.read(apiServiceProvider);
  return api.getClientQrCode(id);
});

// Enrollment code provider
final enrollmentCodeProvider = FutureProvider.family<EnrollmentCode?, String>((ref, clientId) async {
  final api = ref.read(apiServiceProvider);
  return api.getEnrollmentCode(clientId);
});

// Security alerts provider
final clientSecurityAlertsProvider = FutureProvider.family<SecurityAlerts, String>((ref, clientId) async {
  final api = ref.read(apiServiceProvider);
  return api.getSecurityAlerts(clientId);
});

// Client activity logs provider
final clientActivityProvider = FutureProvider.family<List<AuditLog>, String>((ref, clientId) async {
  final api = ref.read(apiServiceProvider);
  return api.getAuditLogs(
    resourceType: 'client',
    resourceId: clientId,
    limit: 10,
  );
});

// Client metrics provider (fetches from active clients and filters by ID)
final clientMetricsProvider = FutureProvider.family<ActiveClient?, String>((ref, clientId) async {
  final api = ref.read(apiServiceProvider);
  final activeClients = await api.getActiveClients(limit: 100);
  // Find the client in active clients list
  try {
    return activeClients.firstWhere((c) => c.id == clientId);
  } catch (_) {
    return null; // Client not in active list (offline)
  }
});

// Active clients provider (fetches all currently online clients)
final activeClientsProvider = FutureProvider<List<ActiveClient>>((ref) async {
  final api = ref.read(apiServiceProvider);
  return api.getActiveClients(limit: 100);
});
