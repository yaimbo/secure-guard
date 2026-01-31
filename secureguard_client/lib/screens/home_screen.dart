import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/vpn_provider.dart';
import '../services/ipc_client.dart';
import '../services/tray_service.dart';
import '../widgets/animated_shield_logo.dart';
import '../widgets/bandwidth_graph.dart';
import '../widgets/connection_button.dart';
import '../widgets/disconnected_hero.dart';
import '../widgets/status_card.dart';
import '../widgets/traffic_stats.dart';
import '../widgets/welcome_hero.dart';
import 'enrollment_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _setupTrayCallbacks();
    _checkDaemonInstallation();
  }

  /// Check if daemon is installed on first launch
  Future<void> _checkDaemonInstallation() async {
    // Only check on macOS for now (PKG installer is macOS-specific)
    if (!Platform.isMacOS) return;

    final ipcClient = IpcClient();
    final status = await ipcClient.checkDaemonStatus();

    if (status == DaemonStatus.notInstalled && mounted) {
      // Show installation prompt dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.security, color: Color(0xFF3B82F6)),
              SizedBox(width: 12),
              Text('Install VPN Service'),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SecureGuard requires a background service to manage VPN connections.',
              ),
              SizedBox(height: 16),
              Text(
                'Please run the SecureGuard installer (SecureGuard-x.x.x.pkg) to install the VPN service.',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              SizedBox(height: 12),
              Text(
                'After installation, click "Retry" to connect.',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                // Try to reconnect to daemon
                ref.read(vpnProvider.notifier).connectToDaemon();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
  }

  void _setupTrayCallbacks() {
    // Wire up tray connect/disconnect callbacks
    TrayService.instance.onConnectRequested = () {
      final savedConfig = ref.read(vpnProvider).savedConfig;
      if (savedConfig != null && savedConfig.isNotEmpty) {
        ref.read(vpnProvider.notifier).connect(savedConfig);
      }
      // If no config, do nothing - tray button should be disabled
    };
    TrayService.instance.onDisconnectRequested = () {
      ref.read(vpnProvider.notifier).disconnect();
    };
  }

  void _updateTrayStatus(VpnStatus status, String? savedConfig) {
    final hasConfig = savedConfig != null && savedConfig.isNotEmpty;
    TrayService.instance.updateStatus(status, hasConfig: hasConfig);
  }

  @override
  Widget build(BuildContext context) {
    // Listen to VPN state changes and update tray
    ref.listen<VpnState>(vpnProvider, (previous, next) {
      _updateTrayStatus(next.status, next.savedConfig);
    });

    final vpnState = ref.watch(vpnProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final hasConfig =
        vpnState.savedConfig != null && vpnState.savedConfig!.isNotEmpty;
    final isDisconnectedNoConfig =
        vpnState.status.isDisconnected && !hasConfig && vpnState.isDaemonConnected;
    final isDisconnectedWithConfig =
        vpnState.status.isDisconnected && hasConfig && !vpnState.isLoading;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
      body: Column(
        children: [
          // Custom title bar
          _buildTitleBar(context, isDark),

          // Show welcome hero for first-time users (no config)
          if (isDisconnectedNoConfig)
            Expanded(
              child: WelcomeHero(
                onEnroll: () => _showEnrollmentScreen(context),
              ),
            )
          // Show disconnected hero when has config but not connected
          else if (isDisconnectedWithConfig)
            Expanded(
              child: Column(
                children: [
                  const Expanded(child: DisconnectedHero()),
                  // Error message if any
                  if (vpnState.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildErrorCard(vpnState.error!, theme),
                    ),
                  // Daemon warning if needed
                  if (!vpnState.isDaemonConnected)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildDaemonWarning(theme),
                    ),
                ],
              ),
            )
          else ...[
            // Main content (connected or transitioning states)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    // Connection status indicator with animated shield (compact)
                    if (vpnState.status.isConnected) ...[
                      const AnimatedShieldLogo(
                        color: Color(0xFF22C55E), // Green
                        size: 80,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Protected',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF22C55E),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else ...[
                      _buildStatusIcon(vpnState),
                      const SizedBox(height: 24),
                    ],

                    // Status card (only when connected)
                    if (vpnState.status.isConnected) ...[
                      StatusCard(status: vpnState.status),
                      const SizedBox(height: 16),
                    ],

                    // Traffic stats (when connected)
                    if (vpnState.status.isConnected) ...[
                      const TrafficStats(),
                      const SizedBox(height: 16),
                    ],

                    // Bandwidth graph (when connected)
                    if (vpnState.status.isConnected) ...[
                      const BandwidthGraph(),
                      const SizedBox(height: 16),
                    ],

                    // Error message
                    if (vpnState.error != null) ...[
                      _buildErrorCard(vpnState.error!, theme),
                      const SizedBox(height: 16),
                    ],

                    // Daemon connection warning
                    if (!vpnState.isDaemonConnected) _buildDaemonWarning(theme),
                  ],
                ),
              ),
            ),
          ],

          // Bottom action area (not shown for welcome hero)
          if (!isDisconnectedNoConfig) _buildBottomArea(context, vpnState),
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
        child: Center(
          child: Text(
            'SecureGuard VPN',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(VpnState vpnState) {
    final status = vpnState.status;

    Color iconColor;
    String statusText;

    switch (status.state) {
      case VpnConnectionState.connected:
        iconColor = const Color(0xFF22C55E); // Green
        statusText = 'Protected';
      case VpnConnectionState.connecting:
        iconColor = const Color(0xFFF59E0B); // Amber
        statusText = 'Connecting...';
      case VpnConnectionState.disconnecting:
        iconColor = const Color(0xFFF59E0B); // Amber
        statusText = 'Disconnecting...';
      case VpnConnectionState.error:
        iconColor = const Color(0xFFEF4444); // Red
        statusText = 'Error';
      case VpnConnectionState.disconnected:
        iconColor = const Color(0xFF3B82F6); // Blue
        statusText = 'Not Protected';
    }

    return Column(
      children: [
        AnimatedShieldLogo(
          color: iconColor,
          size: 160,
        ),
        const SizedBox(height: 12),
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 300),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: iconColor,
          ),
          child: Text(statusText),
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
    final hasConfig =
        vpnState.savedConfig != null && vpnState.savedConfig!.isNotEmpty;
    final isDisconnected = vpnState.status.isDisconnected && !vpnState.isLoading;
    final isTransitioning =
        vpnState.isLoading || vpnState.status.isTransitioning;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectionButton(
            status: vpnState.status,
            isLoading: vpnState.isLoading,
            isDaemonConnected: vpnState.isDaemonConnected,
            hasConfig: hasConfig,
            onConnect: () {
              if (hasConfig) {
                ref.read(vpnProvider.notifier).connect(vpnState.savedConfig!);
              }
            },
            onDisconnect: () => ref.read(vpnProvider.notifier).disconnect(),
          ),
          // Enroll / Change Config button (only when disconnected)
          if (isDisconnected && vpnState.isDaemonConnected) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: isTransitioning
                  ? null
                  : () => _showEnrollmentScreen(context),
              icon: Icon(
                hasConfig ? Icons.settings : Icons.vpn_key,
                size: 18,
              ),
              label: Text(hasConfig ? 'Change Config' : 'Enroll'),
            ),
          ],
        ],
      ),
    );
  }

  void _showEnrollmentScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EnrollmentScreen()),
    );
  }
}
