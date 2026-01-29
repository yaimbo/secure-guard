import 'package:flutter/material.dart';

import '../services/ipc_client.dart';

class ConnectionButton extends StatelessWidget {
  final VpnStatus status;
  final bool isLoading;
  final bool isDaemonConnected;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const ConnectionButton({
    super.key,
    required this.status,
    required this.isLoading,
    required this.isDaemonConnected,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = status.isConnected;
    final isTransitioning = status.isTransitioning || isLoading;
    final canInteract = isDaemonConnected && !isTransitioning;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: canInteract ? (isConnected ? onDisconnect : onConnect) : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: isConnected
              ? const Color(0xFFEF4444) // Red for disconnect
              : const Color(0xFF3B82F6), // Blue for connect
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade400,
          disabledForegroundColor: Colors.white70,
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
                    isConnected ? Icons.power_settings_new : Icons.power,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isConnected ? 'Disconnect' : 'Connect',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
