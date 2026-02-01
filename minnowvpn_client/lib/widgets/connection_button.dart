import 'package:flutter/material.dart';

import '../services/ipc_client.dart';

class ConnectionButton extends StatelessWidget {
  final VpnStatus status;
  final bool isLoading;
  final bool isDaemonConnected;
  final bool hasConfig;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const ConnectionButton({
    super.key,
    required this.status,
    required this.isLoading,
    required this.isDaemonConnected,
    required this.hasConfig,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = status.isConnected;
    final isTransitioning = status.isTransitioning || isLoading;

    // Can connect only if: daemon connected, not transitioning, AND has config
    // Can disconnect if: daemon connected and not transitioning
    final canConnect = isDaemonConnected && !isTransitioning && hasConfig;
    final canDisconnect = isDaemonConnected && !isTransitioning;
    final canInteract = isConnected ? canDisconnect : canConnect;

    // Visual states
    final isDisabled = !canInteract;
    final showNoConfig = !isConnected && !hasConfig && isDaemonConnected;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        child: ElevatedButton(
          onPressed: canInteract ? (isConnected ? onDisconnect : onConnect) : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: isConnected
                ? const Color(0xFFEF4444) // Red for disconnect
                : (isDisabled ? Colors.grey.shade600 : const Color(0xFF3B82F6)),
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade600,
            disabledForegroundColor: Colors.white60,
            elevation: isDisabled ? 0 : 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: isTransitioning
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isConnected
                          ? Icons.power_settings_new
                          : (showNoConfig ? Icons.block : Icons.power),
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isConnected
                          ? 'Disconnect'
                          : (showNoConfig ? 'No Config' : 'Connect'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
