import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/vpn_provider.dart';
import '../services/ipc_client.dart';
import '../services/tray_service.dart';
import '../widgets/config_dialog.dart';
import '../widgets/connection_button.dart';
import '../widgets/status_card.dart';
import '../widgets/traffic_stats.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _setupTrayCallbacks();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  void _setupTrayCallbacks() {
    // Wire up tray connect/disconnect callbacks
    TrayService.instance.onConnectRequested = () {
      _showConfigDialog(context);
    };
    TrayService.instance.onDisconnectRequested = () {
      ref.read(vpnProvider.notifier).disconnect();
    };
  }

  void _updateTrayStatus(VpnStatus status) {
    TrayService.instance.updateStatus(status);
  }

  @override
  void onWindowClose() async {
    // Minimize to tray instead of closing (optional behavior)
    await windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    // Listen to VPN state changes and update tray
    ref.listen<VpnState>(vpnProvider, (previous, next) {
      _updateTrayStatus(next.status);
    });

    final vpnState = ref.watch(vpnProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
      body: Column(
        children: [
          // Custom title bar
          _buildTitleBar(context, isDark),

          // Main content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Connection status indicator
                  _buildStatusIcon(vpnState),
                  const SizedBox(height: 24),

                  // Status card
                  StatusCard(status: vpnState.status),
                  const SizedBox(height: 16),

                  // Traffic stats (when connected)
                  if (vpnState.status.isConnected)
                    TrafficStats(status: vpnState.status),

                  if (vpnState.status.isConnected) const SizedBox(height: 16),

                  // Error message
                  if (vpnState.error != null) ...[
                    _buildErrorCard(vpnState.error!, theme),
                    const SizedBox(height: 16),
                  ],

                  // Daemon connection warning
                  if (!vpnState.isDaemonConnected)
                    _buildDaemonWarning(theme),
                ],
              ),
            ),
          ),

          // Bottom action area
          _buildBottomArea(context, vpnState),
        ],
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context, bool isDark) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 48,
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        child: Row(
          children: [
            const SizedBox(width: 16),
            Icon(
              Icons.shield,
              size: 20,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
            const SizedBox(width: 8),
            Text(
              'SecureGuard VPN',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const Spacer(),
            // Window controls
            IconButton(
              icon: const Icon(Icons.remove, size: 18),
              onPressed: () => windowManager.minimize(),
              tooltip: 'Minimize',
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => windowManager.hide(),
              tooltip: 'Close',
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(VpnState vpnState) {
    final status = vpnState.status;
    final isLoading = vpnState.isLoading || status.isTransitioning;

    Color iconColor;
    IconData iconData;
    String statusText;

    switch (status.state) {
      case VpnConnectionState.connected:
        iconColor = const Color(0xFF22C55E); // Green
        iconData = Icons.shield;
        statusText = 'Protected';
      case VpnConnectionState.connecting:
        iconColor = const Color(0xFFF59E0B); // Amber
        iconData = Icons.shield_outlined;
        statusText = 'Connecting...';
      case VpnConnectionState.disconnecting:
        iconColor = const Color(0xFFF59E0B); // Amber
        iconData = Icons.shield_outlined;
        statusText = 'Disconnecting...';
      case VpnConnectionState.error:
        iconColor = const Color(0xFFEF4444); // Red
        iconData = Icons.shield_outlined;
        statusText = 'Error';
      case VpnConnectionState.disconnected:
        iconColor = const Color(0xFF6B7280); // Gray
        iconData = Icons.shield_outlined;
        statusText = 'Not Protected';
    }

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            if (isLoading)
              SizedBox(
                width: 100,
                height: 100,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                ),
              ),
            Icon(
              iconData,
              size: 80,
              color: iconColor,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          statusText,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: iconColor,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard(String error, ThemeData theme) {
    return Card(
      color: const Color(0xFFFEE2E2),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => ref.read(vpnProvider.notifier).clearError(),
              color: const Color(0xFF991B1B),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDaemonWarning(ThemeData theme) {
    return Card(
      color: const Color(0xFFFEF3C7),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: Color(0xFFD97706), size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'VPN service not running. Start with:\nsudo secureguard-poc --daemon',
                style: TextStyle(color: Color(0xFF92400E), fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => ref.read(vpnProvider.notifier).connectToDaemon(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomArea(BuildContext context, VpnState vpnState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? Colors.white10 : Colors.black12,
          ),
        ),
      ),
      child: ConnectionButton(
        status: vpnState.status,
        isLoading: vpnState.isLoading,
        isDaemonConnected: vpnState.isDaemonConnected,
        onConnect: () => _showConfigDialog(context),
        onDisconnect: () => ref.read(vpnProvider.notifier).disconnect(),
      ),
    );
  }

  void _showConfigDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => ConfigDialog(
        initialConfig: ref.read(vpnProvider).savedConfig,
        onConnect: (config) {
          ref.read(vpnProvider.notifier).connect(config);
        },
      ),
    );
  }
}
