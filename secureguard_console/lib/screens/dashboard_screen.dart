import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../widgets/stat_card.dart';
import '../config/theme.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stats row
            Row(
              children: [
                Expanded(
                  child: StatCard(
                    title: 'Active Connections',
                    value: '47',
                    subtitle: '+3 from 1h ago',
                    icon: Icons.wifi,
                    iconColor: AppTheme.connected,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: StatCard(
                    title: 'Total Clients',
                    value: '156',
                    subtitle: '142 active',
                    icon: Icons.devices,
                    iconColor: AppTheme.primary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: StatCard(
                    title: 'Upload Rate',
                    value: '2.4 Gbps',
                    subtitle: '+12% from 1h ago',
                    icon: Icons.upload,
                    iconColor: AppTheme.primary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: StatCard(
                    title: 'Download Rate',
                    value: '8.1 Gbps',
                    subtitle: '+8% from 1h ago',
                    icon: Icons.download,
                    iconColor: AppTheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Charts row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Connections chart
                Expanded(
                  flex: 2,
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
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 200,
                            child: LineChart(
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
                                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                ),
                                borderData: FlBorderData(show: false),
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: const [
                                      FlSpot(0, 30),
                                      FlSpot(1, 45),
                                      FlSpot(2, 38),
                                      FlSpot(3, 52),
                                      FlSpot(4, 47),
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
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),

                // Active clients list
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Active Clients',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 16),
                          _buildClientItem(context, 'laptop-john', '10.0.0.2', true),
                          _buildClientItem(context, 'server-prod', '10.0.0.3', true),
                          _buildClientItem(context, 'phone-mary', '10.0.0.4', true),
                          _buildClientItem(context, 'desktop-bob', '10.0.0.5', true),
                          _buildClientItem(context, 'tablet-alice', '10.0.0.6', false),
                          const SizedBox(height: 8),
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
            ),
            const SizedBox(height: 24),

            // Recent activity and errors row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Recent activity
                Expanded(
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
                          _buildActivityItem(
                            context,
                            Icons.login,
                            AppTheme.connected,
                            'laptop-john connected',
                            '2m ago',
                          ),
                          _buildActivityItem(
                            context,
                            Icons.logout,
                            AppTheme.disconnected,
                            'phone-mary disconnected',
                            '5m ago',
                          ),
                          _buildActivityItem(
                            context,
                            Icons.refresh,
                            AppTheme.primary,
                            'server-prod rekeyed',
                            '10m ago',
                          ),
                          _buildActivityItem(
                            context,
                            Icons.settings,
                            AppTheme.warning,
                            'Config updated (3 clients)',
                            '15m ago',
                          ),
                          const SizedBox(height: 8),
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
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Errors (last 24h)',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 16),
                          _buildErrorBar(context, 'Handshake', 3, 10),
                          const SizedBox(height: 12),
                          _buildErrorBar(context, 'Timeout', 1, 10),
                          const SizedBox(height: 12),
                          _buildErrorBar(context, 'Auth', 0, 10),
                          const SizedBox(height: 16),
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClientItem(BuildContext context, String name, String ip, bool online) {
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
