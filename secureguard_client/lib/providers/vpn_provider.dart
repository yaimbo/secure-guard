import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc_client.dart';
import '../services/update_service.dart';

/// Provider for the IPC client singleton
final ipcClientProvider = Provider<IpcClient>((ref) {
  final client = IpcClient();
  ref.onDispose(() => client.dispose());
  return client;
});

/// Provider for daemon connection state
final daemonConnectedProvider = StreamProvider<bool>((ref) {
  final client = ref.watch(ipcClientProvider);
  return client.connectionStream;
});

/// Provider for VPN status updates from daemon
final vpnStatusStreamProvider = StreamProvider<VpnStatus>((ref) {
  final client = ref.watch(ipcClientProvider);
  return client.statusStream;
});

/// State for the VPN connection
class VpnState {
  final bool isDaemonConnected;
  final VpnStatus status;
  final bool isLoading;
  final String? error;
  final String? savedConfig;

  const VpnState({
    this.isDaemonConnected = false,
    VpnStatus? status,
    this.isLoading = false,
    this.error,
    this.savedConfig,
  }) : status = status ?? const _DefaultVpnStatus();

  VpnState copyWith({
    bool? isDaemonConnected,
    VpnStatus? status,
    bool? isLoading,
    String? error,
    String? savedConfig,
    bool clearError = false,
  }) {
    return VpnState(
      isDaemonConnected: isDaemonConnected ?? this.isDaemonConnected,
      status: status ?? this.status,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      savedConfig: savedConfig ?? this.savedConfig,
    );
  }
}

/// Default VPN status when not available
class _DefaultVpnStatus implements VpnStatus {
  const _DefaultVpnStatus();

  @override
  VpnConnectionState get state => VpnConnectionState.disconnected;
  @override
  String? get vpnIp => null;
  @override
  String? get serverEndpoint => null;
  @override
  String? get connectedAt => null;
  @override
  int get bytesSent => 0;
  @override
  int get bytesReceived => 0;
  @override
  String? get lastHandshake => null;
  @override
  String? get errorMessage => null;
  @override
  bool get isConnected => false;
  @override
  bool get isDisconnected => true;
  @override
  bool get isTransitioning => false;
}

/// Notifier for VPN state management
class VpnNotifier extends StateNotifier<VpnState> {
  final IpcClient _client;
  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<VpnStatus>? _statusSub;
  Timer? _reconnectTimer;

  VpnNotifier(this._client) : super(const VpnState()) {
    _init();
  }

  Future<void> _init() async {
    // Listen to daemon connection state
    _connectionSub = _client.connectionStream.listen((connected) {
      state = state.copyWith(isDaemonConnected: connected);
      if (!connected) {
        _scheduleReconnect();
      }
    });

    // Listen to VPN status updates
    _statusSub = _client.statusStream.listen((status) {
      state = state.copyWith(status: status, clearError: true);
    });

    // Listen to config updates from update service
    UpdateService.instance.onConfigUpdated = _onConfigUpdated;

    // Try initial connection
    await connectToDaemon();
  }

  /// Handle config update from server
  void _onConfigUpdated(String newConfig) {
    // If currently connected, reconnect with new config
    if (state.status.isConnected && state.isDaemonConnected) {
      // Store the new config and reconnect
      state = state.copyWith(savedConfig: newConfig);
      _reconnectWithNewConfig(newConfig);
    } else {
      // Just save the new config for next connection
      state = state.copyWith(savedConfig: newConfig);
    }
  }

  /// Reconnect with new config (for seamless config updates)
  Future<void> _reconnectWithNewConfig(String config) async {
    // Disconnect and reconnect with new config
    try {
      await _client.disconnectVpn();
      // Small delay to ensure clean disconnect
      await Future.delayed(const Duration(milliseconds: 500));
      await _client.connectVpn(config);
    } catch (e) {
      state = state.copyWith(error: 'Config update failed: $e');
    }
  }

  /// Schedule a reconnection attempt
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!state.isDaemonConnected) {
        connectToDaemon();
      }
    });
  }

  /// Connect to the daemon
  Future<void> connectToDaemon() async {
    state = state.copyWith(isLoading: true);
    final success = await _client.connect();

    if (success) {
      state = state.copyWith(isDaemonConnected: true, isLoading: false, clearError: true);
      // Fetch initial status
      await refreshStatus();
    } else {
      state = state.copyWith(
        isDaemonConnected: false,
        isLoading: false,
        error: 'Failed to connect to VPN service. Is the daemon running?',
      );
      _scheduleReconnect();
    }
  }

  /// Refresh VPN status from daemon
  Future<void> refreshStatus() async {
    if (!state.isDaemonConnected) return;

    try {
      final status = await _client.getStatus();
      state = state.copyWith(status: status, clearError: true);
    } catch (e) {
      state = state.copyWith(error: 'Failed to get status: $e');
    }
  }

  /// Connect to VPN
  Future<void> connect(String config) async {
    if (!state.isDaemonConnected) {
      state = state.copyWith(error: 'Not connected to VPN service');
      return;
    }

    state = state.copyWith(
      isLoading: true,
      savedConfig: config,
      clearError: true,
    );

    try {
      await _client.connectVpn(config);
      // Status will be updated via stream
      state = state.copyWith(isLoading: false);
    } on IpcError catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Connection failed: $e',
      );
    }
  }

  /// Disconnect from VPN
  Future<void> disconnect() async {
    if (!state.isDaemonConnected) {
      state = state.copyWith(error: 'Not connected to VPN service');
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      await _client.disconnectVpn();
      // Status will be updated via stream
      state = state.copyWith(isLoading: false);
    } on IpcError catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Disconnect failed: $e',
      );
    }
  }

  /// Clear error message
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _statusSub?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}

/// Provider for VPN state
final vpnProvider = StateNotifierProvider<VpnNotifier, VpnState>((ref) {
  final client = ref.watch(ipcClientProvider);
  return VpnNotifier(client);
});
