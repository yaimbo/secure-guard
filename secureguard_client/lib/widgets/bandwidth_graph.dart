import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/bandwidth_provider.dart';

class BandwidthGraph extends ConsumerWidget {
  const BandwidthGraph({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bandwidthState = ref.watch(bandwidthProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Legend
            Row(
              children: [
                _buildLegendItem(
                  color: const Color(0xFF6366F1),
                  label: 'Upload',
                  isDark: isDark,
                ),
                const SizedBox(width: 16),
                _buildLegendItem(
                  color: const Color(0xFF10B981),
                  label: 'Download',
                  isDark: isDark,
                ),
                const Spacer(),
                Text(
                  'Last 60s',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Chart
            SizedBox(
              height: 120,
              child: bandwidthState.dataPoints.isEmpty
                  ? Center(
                      child: Text(
                        'Waiting for data...',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                      ),
                    )
                  : _buildChart(bandwidthState, isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem({
    required Color color,
    required String label,
    required bool isDark,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
      ],
    );
  }

  Widget _buildChart(BandwidthState state, bool isDark) {
    final uploadSpots = <FlSpot>[];
    final downloadSpots = <FlSpot>[];

    for (var i = 0; i < state.dataPoints.length; i++) {
      final point = state.dataPoints[i];
      uploadSpots.add(FlSpot(i.toDouble(), point.uploadSpeed));
      downloadSpots.add(FlSpot(i.toDouble(), point.downloadSpeed));
    }

    final maxY = state.maxSpeed;
    final gridColor = isDark ? Colors.white10 : Colors.black12;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: 59,
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (value) => FlLine(
            color: gridColor,
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                if (value == 0) return const SizedBox.shrink();
                return Text(
                  _formatSpeed(value),
                  style: TextStyle(
                    fontSize: 9,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          // Upload line (blue/indigo)
          LineChartBarData(
            spots: uploadSpots,
            isCurved: true,
            curveSmoothness: 0.3,
            color: const Color(0xFF6366F1),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF6366F1).withValues(alpha: 0.3),
                  const Color(0xFF6366F1).withValues(alpha: 0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          // Download line (green)
          LineChartBarData(
            spots: downloadSpots,
            isCurved: true,
            curveSmoothness: 0.3,
            color: const Color(0xFF10B981),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF10B981).withValues(alpha: 0.3),
                  const Color(0xFF10B981).withValues(alpha: 0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) =>
                isDark ? const Color(0xFF2D2D2D) : Colors.white,
            tooltipRoundedRadius: 8,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final isUpload = spot.barIndex == 0;
                return LineTooltipItem(
                  '${isUpload ? '↑' : '↓'} ${_formatSpeed(spot.y)}',
                  TextStyle(
                    color: isUpload
                        ? const Color(0xFF6366F1)
                        : const Color(0xFF10B981),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeInOut,
    );
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toInt()} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    } else {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
  }
}
