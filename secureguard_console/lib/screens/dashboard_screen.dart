import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/dashboard_provider.dart';
import '../services/api_service.dart';
import '../widgets/stat_card.dart';
import '../config/theme.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final dashboardState = ref.watch(dashboardProvider);
    final stats = dashboardState.stats;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Dashboard'),
            const SizedBox(width: 12),
            // WebSocket connection indicator
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dashboardState.isConnected
                    ? AppTheme.connected
                    : AppTheme.disconnected,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        actions: [
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: dashboardState.isLoading
                ? null
                : () => ref.read(dashboardProvider.notifier).refresh(),
            tooltip: 'Refresh',
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                const Icon(Icons.person_outline, size: 20),
                const SizedBox(width: 8),
                Text(authState.email ?? 'Admin'),
              ],
            ),
          ),
        ],
      ),
      body: dashboardState.isLoading && stats == null
          ? const Center(child: CircularProgressIndicator())
          : dashboardState.error != null && stats == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline,
                          size: 48, color: AppTheme.error),
                      const SizedBox(height: 16),
                      Text(dashboardState.error!),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () =>
                            ref.read(dashboardProvider.notifier).refresh(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Stats row
                      _buildStatsRow(context, stats),
                      const SizedBox(height: 24),

                      // Charts row
                      _buildChartsRow(context, ref, dashboardState),
                      const SizedBox(height: 24),

                      // Recent activity and errors row
                      _buildActivityRow(context, dashboardState),
                    ],
                  ),
                ),
    );
  }

  Widget _buildStatsRow(BuildContext context, DashboardStats? stats) {
    return Row(
      children: [
        Expanded(
          child: StatCard(
            title: 'Active Connections',
            value: stats?.activeConnections.toString() ?? '0',
            subtitle: stats != null ? 'Real-time' : 'Loading...',
            icon: Icons.wifi,
            iconColor: AppTheme.connected,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: StatCard(
            title: 'Total Clients',
            value: stats?.totalClients.toString() ?? '0',
            subtitle: stats != null
                ? '${stats.activeClients} active'
                : 'Loading...',
            icon: Icons.devices,
            iconColor: AppTheme.primary,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: StatCard(
            title: 'Upload Rate',
            value: stats != null
                ? DashboardStats.formatRate(stats.uploadRate)
                : '0 bps',
            subtitle: stats != null
                ? DashboardStats.formatBytes(stats.totalBytesSent)
                : 'Loading...',
            icon: Icons.upload,
            iconColor: AppTheme.primary,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: StatCard(
            title: 'Download Rate',
            value: stats != null
                ? DashboardStats.formatRate(stats.downloadRate)
                : '0 bps',
            subtitle: stats != null
                ? DashboardStats.formatBytes(stats.totalBytesReceived)
                : 'Loading...',
            icon: Icons.download,
            iconColor: AppTheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildChartsRow(
      BuildContext context, WidgetRef ref, DashboardState state) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Connections chart
        Expanded(
          flex: 3,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connections (24h)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 160,
                    child: _buildConnectionChart(state.connectionHistory),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),

        // Active clients list
        Expanded(
          flex: 2,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Active Clients',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (state.activeClients.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.connected.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${state.activeClients.length}',
                            style: TextStyle(
                              color: AppTheme.connected,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (state.activeClients.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.devices, size: 32, color: Colors.grey[700]),
                            const SizedBox(height: 8),
                            Text(
                              'No active clients',
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ...state.activeClients.take(5).map((client) =>
                        _buildClientItem(
                            context, client.name, client.assignedIp, client.isOnline)),
                  if (state.activeClients.isNotEmpty) const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.go('/clients'),
                    child: const Text('View all clients...'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionChart(List<ConnectionDataPoint> data) {
    if (data.isEmpty) {
      // Show placeholder chart with sample data
      return LineChart(
        LineChartData(
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 10,
            getDrawingHorizontalLine: (value) {
              return FlLine(
                color: Colors.white10,
                strokeWidth: 1,
              );
            },
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) {
                  return Text(
                    value.toInt().toString(),
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white54,
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final hours = ['00:00', '06:00', '12:00', '18:00', 'Now'];
                  if (value.toInt() < hours.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        hours[value.toInt()],
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white54,
                        ),
                      ),
                    );
                  }
                  return const SizedBox();
                },
              ),
            ),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: const [
                FlSpot(0, 0),
                FlSpot(1, 0),
                FlSpot(2, 0),
                FlSpot(3, 0),
                FlSpot(4, 0),
              ],
              isCurved: true,
              color: AppTheme.primary,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: AppTheme.primary.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
      );
    }

    // Build chart from actual data
    final spots = data.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value.activeConnections.toDouble());
    }).toList();

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 10,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.white10,
              strokeWidth: 1,
            );
          },
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white54,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (data.length / 5).ceilToDouble(),
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index >= 0 && index < data.length) {
                  final time = data[index].timestamp;
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white54,
                      ),
                    ),
                  );
                }
                return const SizedBox();
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: AppTheme.primary,
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: AppTheme.primary.withValues(alpha: 0.1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityRow(BuildContext context, DashboardState state) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Recent activity
        Expanded(
          flex: 3,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recent Activity',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  if (state.recentActivity.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.history, size: 32, color: Colors.grey[700]),
                            const SizedBox(height: 8),
                            Text(
                              'No recent activity',
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ...state.recentActivity.take(5).map((event) =>
                        _buildActivityItem(
                          context,
                          _getEventIcon(event.type),
                          _getEventColor(event.type),
                          event.title,
                          event.relativeTime,
                        )),
                  if (state.recentActivity.isNotEmpty) const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.go('/logs'),
                    child: const Text('View all activity...'),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),

        // Errors
        Expanded(
          flex: 2,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Errors (last 24h)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (state.errorSummary.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${state.errorSummary.values.fold(0, (a, b) => a + b)}',
                            style: TextStyle(
                              color: AppTheme.error,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (state.errorSummary.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.check_circle_outline, size: 32, color: AppTheme.connected),
                            const SizedBox(height: 8),
                            Text(
                              'No errors',
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ...state.errorSummary.entries.take(5).map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child:
                              _buildErrorBar(context, e.key, e.value, _getMaxErrors(state.errorSummary)),
                        )),
                  if (state.errorSummary.isNotEmpty) const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.go('/logs'),
                    child: const Text('View all errors...'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  int _getMaxErrors(Map<String, int> errors) {
    if (errors.isEmpty) return 10;
    final max = errors.values.reduce((a, b) => a > b ? a : b);
    return max > 0 ? max : 10;
  }

  IconData _getEventIcon(String type) {
    switch (type) {
      case 'connected':
        return Icons.login;
      case 'disconnected':
        return Icons.logout;
      case 'rekeyed':
        return Icons.refresh;
      case 'config_updated':
        return Icons.settings;
      case 'error':
        return Icons.error_outline;
      case 'audit':
        return Icons.history;
      default:
        return Icons.info_outline;
    }
  }

  Color _getEventColor(String type) {
    switch (type) {
      case 'connected':
        return AppTheme.connected;
      case 'disconnected':
        return AppTheme.disconnected;
      case 'rekeyed':
        return AppTheme.primary;
      case 'config_updated':
        return AppTheme.warning;
      case 'error':
        return AppTheme.error;
      default:
        return AppTheme.primary;
    }
  }

  Widget _buildClientItem(
      BuildContext context, String name, String ip, bool online) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: online ? AppTheme.connected : AppTheme.disconnected,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name),
          ),
          Text(
            ip,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityItem(
    BuildContext context,
    IconData icon,
    Color iconColor,
    String text,
    String time,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
          Text(
            time,
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBar(BuildContext context, String label, int count, int max) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: count / max,
            backgroundColor: Colors.white10,
            valueColor: AlwaysStoppedAnimation(
              count > 5 ? AppTheme.error : AppTheme.warning,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 24,
          child: Text(
            count.toString(),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}
