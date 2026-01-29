import 'package:flutter/material.dart';

import '../services/ipc_client.dart';

class TrafficStats extends StatelessWidget {
  final VpnStatus status;

  const TrafficStats({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _buildStat(
                context,
                icon: Icons.arrow_upward,
                label: 'Sent',
                value: _formatBytes(status.bytesSent),
                color: const Color(0xFF3B82F6),
                isDark: isDark,
              ),
            ),
            Container(
              width: 1,
              height: 40,
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            Expanded(
              child: _buildStat(
                context,
                icon: Icons.arrow_downward,
                label: 'Received',
                value: _formatBytes(status.bytesReceived),
                color: const Color(0xFF22C55E),
                isDark: isDark,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStat(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : Colors.black45,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
