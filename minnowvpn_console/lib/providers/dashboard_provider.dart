import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/api_service.dart';

/// Dashboard state containing all dashboard data
class DashboardState {
  final DashboardStats? stats;
  final List<ActiveClient> activeClients;
  final List<ActivityEvent> recentActivity;
  final Map<String, int> errorSummary;
  final List<ConnectionDataPoint> connectionHistory;
  final bool isLoading;
  final bool isConnected;
  final String? error;

  const DashboardState({
    this.stats,
    this.activeClients = const [],
    this.recentActivity = const [],
    this.errorSummary = const {},
    this.connectionHistory = const [],
    this.isLoading = false,
    this.isConnected = false,
    this.error,
  });

  DashboardState copyWith({
    DashboardStats? stats,
    List<ActiveClient>? activeClients,
    List<ActivityEvent>? recentActivity,
    Map<String, int>? errorSummary,
    List<ConnectionDataPoint>? connectionHistory,
    bool? isLoading,
    bool? isConnected,
    String? error,
  }) {
    return DashboardState(
      stats: stats ?? this.stats,
      activeClients: activeClients ?? this.activeClients,
      recentActivity: recentActivity ?? this.recentActivity,
      errorSummary: errorSummary ?? this.errorSummary,
      connectionHistory: connectionHistory ?? this.connectionHistory,
      isLoading: isLoading ?? this.isLoading,
      isConnected: isConnected ?? this.isConnected,
      error: error,
    );
  }
}

/// Dashboard notifier that manages dashboard state and WebSocket connection
class DashboardNotifier extends StateNotifier<DashboardState> {
  final ApiService _apiService;
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  static const _wsReconnectDelay = Duration(seconds: 5);
  static const _pingInterval = Duration(seconds: 30);

  DashboardNotifier(this._apiService) : super(const DashboardState()) {
    _initialize();
  }

  Future<void> _initialize() async {
    await refresh();
    _connectWebSocket();
  }

  /// Refresh all dashboard data from API
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // Fetch all data in parallel
      final results = await Future.wait([
        _fetchStats(),
        _fetchActiveClients(),
        _fetchRecentActivity(),
        _fetchErrorSummary(),
        _fetchConnectionHistory(),
      ]);

      state = state.copyWith(
        stats: results[0] as DashboardStats?,
        activeClients: results[1] as List<ActiveClient>,
        recentActivity: results[2] as List<ActivityEvent>,
        errorSummary: results[3] as Map<String, int>,
        connectionHistory: results[4] as List<ConnectionDataPoint>,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load dashboard data: $e',
      );
    }
  }

  Future<DashboardStats?> _fetchStats() async {
    try {
      return await _apiService.getDashboardStats();
    } catch (e) {
      // Return mock stats for now if endpoint doesn't exist
      return DashboardStats(
        activeConnections: 0,
        totalClients: 0,
        activeClients: 0,
        uploadRate: 0,
        downloadRate: 0,
        totalBytesSent: 0,
        totalBytesReceived: 0,
        timestamp: DateTime.now(),
      );
    }
  }

  Future<List<ActiveClient>> _fetchActiveClients() async {
    try {
      return await _apiService.getActiveClients();
    } catch (e) {
      return [];
    }
  }

  Future<List<ActivityEvent>> _fetchRecentActivity() async {
    try {
      return await _apiService.getRecentActivity();
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, int>> _fetchErrorSummary() async {
    try {
      return await _apiService.getErrorSummary();
    } catch (e) {
      return {};
    }
  }

  Future<List<ConnectionDataPoint>> _fetchConnectionHistory() async {
    try {
      return await _apiService.getConnectionHistory();
    } catch (e) {
      return [];
    }
  }

  /// Connect to WebSocket for real-time updates
  void _connectWebSocket() {
    // Don't connect if we don't have an access token
    final token = _apiService.accessToken;
    if (token == null) {
      _scheduleReconnect();
      return;
    }

    try {
      // Build WebSocket URL from API URL
      final apiUrl = const String.fromEnvironment(
        'API_URL',
        defaultValue: 'http://localhost:8080/api/v1',
      );

      // Convert http(s) to ws(s)
      final wsUrl = apiUrl
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://');

      // Include token as query parameter for WebSocket authentication
      _wsChannel = WebSocketChannel.connect(
        Uri.parse('$wsUrl/ws/dashboard?token=${Uri.encodeComponent(token)}'),
      );

      _wsSubscription = _wsChannel!.stream.listen(
        _handleWebSocketMessage,
        onError: _handleWebSocketError,
        onDone: _handleWebSocketClosed,
      );

      state = state.copyWith(isConnected: true);
      _startPingTimer();
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _handleWebSocketMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      final type = data['type'] as String?;
      final payload = data['data'] as Map<String, dynamic>?;

      switch (type) {
        case 'initial_state':
        case 'metrics_update':
          if (payload != null) {
            _updateFromWebSocket(payload);
          }
          break;

        case 'connection_event':
          if (payload != null) {
            _handleConnectionEvent(payload);
          }
          break;

        case 'error_event':
          if (payload != null) {
            _handleErrorEvent(payload);
          }
          break;

        case 'audit_event':
          if (payload != null) {
            _handleAuditEvent(payload);
          }
          break;

        case 'pong':
          // Heartbeat response, connection is alive
          break;
      }
    } catch (e) {
      // Ignore parse errors
    }
  }

  void _updateFromWebSocket(Map<String, dynamic> data) {
    final stats = DashboardStats(
      activeConnections: data['active_connections'] as int? ?? state.stats?.activeConnections ?? 0,
      totalClients: data['total_clients'] as int? ?? state.stats?.totalClients ?? 0,
      activeClients: data['active_clients'] as int? ?? state.stats?.activeClients ?? 0,
      uploadRate: (data['bandwidth'] as Map?)?['upload_rate'] as int? ?? 0,
      downloadRate: (data['bandwidth'] as Map?)?['download_rate'] as int? ?? 0,
      totalBytesSent: state.stats?.totalBytesSent ?? 0,
      totalBytesReceived: state.stats?.totalBytesReceived ?? 0,
      timestamp: DateTime.now(),
    );

    state = state.copyWith(stats: stats);
  }

  void _handleConnectionEvent(Map<String, dynamic> event) {
    final eventType = event['event'] as String? ?? 'unknown';
    final clientName = event['name'] as String? ?? 'Unknown';
    final clientId = event['client_id'] as String?;

    final activity = ActivityEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: eventType == 'connected' ? 'connected' : 'disconnected',
      title: '$clientName $eventType',
      clientId: clientId,
      clientName: clientName,
      timestamp: DateTime.now(),
    );

    // Add to front of activity list, keep max 10
    final updatedActivity = [activity, ...state.recentActivity].take(10).toList();
    state = state.copyWith(recentActivity: updatedActivity);

    // Refresh stats for connection count
    _fetchStats().then((stats) {
      if (stats != null) {
        state = state.copyWith(stats: stats);
      }
    });
  }

  void _handleErrorEvent(Map<String, dynamic> event) {
    final message = event['message'] as String? ?? 'Unknown error';

    final activity = ActivityEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'error',
      title: message,
      timestamp: DateTime.now(),
      details: event,
    );

    final updatedActivity = [activity, ...state.recentActivity].take(10).toList();
    state = state.copyWith(recentActivity: updatedActivity);
  }

  void _handleAuditEvent(Map<String, dynamic> event) {
    final eventType = event['event_type'] as String? ?? 'unknown';
    final actorName = event['actor_name'] as String? ?? 'System';

    final activity = ActivityEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: 'audit',
      title: '$actorName: $eventType',
      timestamp: DateTime.now(),
      details: event,
    );

    final updatedActivity = [activity, ...state.recentActivity].take(10).toList();
    state = state.copyWith(recentActivity: updatedActivity);
  }

  void _handleWebSocketError(dynamic error) {
    state = state.copyWith(isConnected: false);
    _scheduleReconnect();
  }

  void _handleWebSocketClosed() {
    state = state.copyWith(isConnected: false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_wsReconnectDelay, _connectWebSocket);
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_wsChannel != null) {
        try {
          _wsChannel!.sink.add(jsonEncode({'type': 'ping'}));
        } catch (e) {
          // Connection lost
          _handleWebSocketClosed();
        }
      }
    });
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _wsSubscription?.cancel();
    _wsChannel?.sink.close();
    super.dispose();
  }
}

/// Provider for dashboard state
final dashboardProvider =
    StateNotifierProvider<DashboardNotifier, DashboardState>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  return DashboardNotifier(apiService);
});

/// Provider for just the stats (for widgets that only need stats)
final dashboardStatsProvider = Provider<DashboardStats?>((ref) {
  return ref.watch(dashboardProvider).stats;
});

/// Provider for active connections count
final activeConnectionsProvider = Provider<int>((ref) {
  return ref.watch(dashboardProvider).stats?.activeConnections ?? 0;
});

/// Provider for WebSocket connection status
final dashboardConnectedProvider = Provider<bool>((ref) {
  return ref.watch(dashboardProvider).isConnected;
});
