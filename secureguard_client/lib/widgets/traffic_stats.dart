import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/bandwidth_provider.dart';

class TrafficStats extends ConsumerWidget {
  const TrafficStats({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bandwidthState = ref.watch(bandwidthProvider);
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
                label: 'Upload',
                totalBytes: bandwidthState.totalBytesSent,
                speed: bandwidthState.currentUploadSpeed,
                color: const Color(0xFF6366F1),
                isDark: isDark,
              ),
            ),
            Container(
              width: 1,
              height: 56,
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            Expanded(
              child: _buildStat(
                context,
                icon: Icons.arrow_downward,
                label: 'Download',
                totalBytes: bandwidthState.totalBytesReceived,
                speed: bandwidthState.currentDownloadSpeed,
                color: const Color(0xFF10B981),
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
    required int totalBytes,
    required double speed,
    required Color color,
    required bool isDark,
  }) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(icon, size: 14, color: color),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _formatBytes(totalBytes),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        const SizedBox(height: 2),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            _formatSpeed(speed),
            key: ValueKey(speed.toInt()),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
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

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toInt()} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }
}
