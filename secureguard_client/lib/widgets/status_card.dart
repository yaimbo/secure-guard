import 'package:flutter/material.dart';

import '../services/ipc_client.dart';

class StatusCard extends StatelessWidget {
  final VpnStatus status;

  const StatusCard({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (!status.isConnected) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRow(
              context,
              icon: Icons.language,
              label: 'VPN IP',
              value: status.vpnIp ?? 'N/A',
              isDark: isDark,
            ),
            const SizedBox(height: 12),
            _buildRow(
              context,
              icon: Icons.dns,
              label: 'Server',
              value: status.serverEndpoint ?? 'N/A',
              isDark: isDark,
            ),
            if (status.connectedAt != null) ...[
              const SizedBox(height: 12),
              _buildRow(
                context,
                icon: Icons.access_time,
                label: 'Connected',
                value: status.connectedAt!,
                isDark: isDark,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required bool isDark,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: isDark ? Colors.white54 : Colors.black45,
        ),
        const SizedBox(width: 8),
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Colors.black87,
            ),
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
