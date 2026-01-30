import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:data_table_2/data_table_2.dart';

import '../config/theme.dart';
import '../providers/logs_provider.dart';

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateTime? _startDate;
  DateTime? _endDate;
  String? _selectedSeverity = 'ALERT'; // Default to ALERT only

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Audit Log'),
            Tab(text: 'Errors'),
            Tab(text: 'Connections'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export',
            onPressed: _exportLogs,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Filters
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Date range picker
                OutlinedButton.icon(
                  onPressed: () => _selectDateRange(context),
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(_formatDateRange()),
                ),
                const SizedBox(width: 16),
                // Severity filter (for Audit tab)
                DropdownButton<String?>(
                  value: _selectedSeverity,
                  hint: const Text('Severity'),
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All Severities')),
                    DropdownMenuItem(value: 'ALERT', child: Text('Alerts Only')),
                    DropdownMenuItem(value: 'WARNING', child: Text('Warning & Above')),
                    DropdownMenuItem(value: 'INFO', child: Text('All (Info+)')),
                  ],
                  onChanged: (value) {
                    setState(() => _selectedSeverity = value);
                    _refreshLogs();
                  },
                ),
                const SizedBox(width: 16),
                // Refresh
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _refreshLogs,
                ),
                const Spacer(),
                // Search
                SizedBox(
                  width: 300,
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'Search logs...',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (value) {
                      // Search implementation
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildAuditLogTab(),
                _buildErrorLogTab(),
                _buildConnectionLogTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditLogTab() {
    final filter = LogsFilter(
      startDate: _startDate,
      endDate: _endDate,
      severity: _selectedSeverity,
    );
    final logsAsync = ref.watch(filteredAuditLogsProvider(filter));

    return logsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => _buildErrorState(error, () => ref.invalidate(filteredAuditLogsProvider(filter))),
      data: (logs) => logs.isEmpty
          ? _buildEmptyState('No audit logs found')
          : DataTable2(
              columnSpacing: 12,
              horizontalMargin: 12,
              minWidth: 1100,
              columns: const [
                DataColumn2(label: Text('Timestamp'), size: ColumnSize.M),
                DataColumn2(label: Text('Severity'), size: ColumnSize.S),
                DataColumn2(label: Text('Actor'), size: ColumnSize.M),
                DataColumn2(label: Text('Event'), size: ColumnSize.M),
                DataColumn2(label: Text('Resource'), size: ColumnSize.M),
                DataColumn2(label: Text('Details'), size: ColumnSize.L),
                DataColumn2(label: Text('IP'), size: ColumnSize.S),
              ],
              rows: logs.map((log) {
                return DataRow2(
                  cells: [
                    DataCell(Text(_formatTimestamp(log.timestamp))),
                    DataCell(_buildAuditSeverityChip(log.severity)),
                    DataCell(
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(log.actorName ?? log.actorId ?? '-'),
                          Text(
                            log.actorType,
                            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                    ),
                    DataCell(_buildEventChip(log.eventType)),
                    DataCell(
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(log.resourceName ?? log.resourceId ?? '-'),
                          if (log.resourceType != null)
                            Text(
                              log.resourceType!,
                              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                            ),
                        ],
                      ),
                    ),
                    DataCell(
                      Text(
                        log.details?.toString() ?? '-',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DataCell(Text(log.ipAddress ?? '-')),
                  ],
                );
              }).toList(),
            ),
    );
  }

  Widget _buildErrorLogTab() {
    final logsAsync = ref.watch(errorLogsProvider);

    return logsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => _buildErrorState(error, () => ref.refresh(errorLogsProvider)),
      data: (logs) => logs.isEmpty
          ? _buildEmptyState('No errors found')
          : DataTable2(
              columnSpacing: 12,
              horizontalMargin: 12,
              minWidth: 800,
              columns: const [
                DataColumn2(label: Text('Timestamp'), size: ColumnSize.M),
                DataColumn2(label: Text('Severity'), size: ColumnSize.S),
                DataColumn2(label: Text('Component'), size: ColumnSize.M),
                DataColumn2(label: Text('Client'), size: ColumnSize.M),
                DataColumn2(label: Text('Message'), size: ColumnSize.L),
              ],
              rows: logs.map((log) {
                return DataRow2(
                  onTap: () => _showErrorDetails(context, log),
                  cells: [
                    DataCell(Text(_formatTimestamp(log.timestamp))),
                    DataCell(_buildSeverityChip(log.severity)),
                    DataCell(Text(log.component)),
                    DataCell(Text(log.clientName ?? log.clientId ?? '-')),
                    DataCell(
                      Text(
                        log.message,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
    );
  }

  Widget _buildConnectionLogTab() {
    final logsAsync = ref.watch(connectionLogsProvider);

    return logsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => _buildErrorState(error, () => ref.refresh(connectionLogsProvider)),
      data: (logs) => logs.isEmpty
          ? _buildEmptyState('No connection logs found')
          : DataTable2(
              columnSpacing: 12,
              horizontalMargin: 12,
              minWidth: 900,
              columns: const [
                DataColumn2(label: Text('Client'), size: ColumnSize.M),
                DataColumn2(label: Text('Connected'), size: ColumnSize.M),
                DataColumn2(label: Text('Disconnected'), size: ColumnSize.M),
                DataColumn2(label: Text('Duration'), size: ColumnSize.S),
                DataColumn2(label: Text('Source IP'), size: ColumnSize.M),
                DataColumn2(label: Text('Traffic'), size: ColumnSize.M),
                DataColumn2(label: Text('Reason'), size: ColumnSize.M),
              ],
              rows: logs.map((log) {
                return DataRow2(
                  cells: [
                    DataCell(Text(log.clientName ?? log.clientId)),
                    DataCell(Text(_formatTimestamp(log.connectedAt))),
                    DataCell(Text(log.disconnectedAt != null ? _formatTimestamp(log.disconnectedAt!) : '-')),
                    DataCell(Text(_formatDuration(log.durationSecs))),
                    DataCell(Text(log.sourceIp ?? '-')),
                    DataCell(Text(_formatTraffic(log.bytesSent, log.bytesReceived))),
                    DataCell(Text(log.disconnectReason ?? '-')),
                  ],
                );
              }).toList(),
            ),
    );
  }

  Widget _buildEventChip(String eventType) {
    Color color;
    if (eventType.contains('create') || eventType.contains('connect')) {
      color = AppTheme.connected;
    } else if (eventType.contains('delete') || eventType.contains('disconnect')) {
      color = AppTheme.error;
    } else if (eventType.contains('update') || eventType.contains('modify')) {
      color = AppTheme.warning;
    } else {
      color = AppTheme.primary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        eventType,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }

  Widget _buildAuditSeverityChip(String severity) {
    Color color;
    switch (severity.toUpperCase()) {
      case 'ALERT':
        color = AppTheme.error;
        break;
      case 'WARNING':
        color = AppTheme.warning;
        break;
      case 'INFO':
      default:
        color = AppTheme.primary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        severity.toUpperCase(),
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildSeverityChip(String severity) {
    Color color;
    switch (severity.toUpperCase()) {
      case 'ERROR':
        color = AppTheme.error;
        break;
      case 'WARN':
      case 'WARNING':
        color = AppTheme.warning;
        break;
      case 'INFO':
        color = AppTheme.primary;
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        severity.toUpperCase(),
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildErrorState(Object error, VoidCallback onRetry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: AppTheme.error),
          const SizedBox(height: 16),
          Text('Error loading logs: $error'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: Colors.grey[500])),
        ],
      ),
    );
  }

  void _showErrorDetails(BuildContext context, ErrorLog log) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            _buildSeverityChip(log.severity),
            const SizedBox(width: 12),
            Expanded(child: Text(log.component)),
          ],
        ),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Timestamp: ${_formatTimestamp(log.timestamp)}',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                const SizedBox(height: 16),
                const Text('Message:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SelectableText(log.message),
                if (log.stackTrace != null) ...[
                  const SizedBox(height: 16),
                  const Text('Stack Trace:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      log.stackTrace!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  String _formatDuration(int? seconds) {
    if (seconds == null) return '-';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    return '${hours}h ${mins}m';
  }

  String _formatTraffic(int sent, int received) {
    return '↑${_formatBytes(sent)} ↓${_formatBytes(received)}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _formatDateRange() {
    if (_startDate == null && _endDate == null) {
      return 'Last 24 hours';
    }
    final start = _startDate != null ? '${_startDate!.month}/${_startDate!.day}' : '';
    final end = _endDate != null ? '${_endDate!.month}/${_endDate!.day}' : '';
    return '$start - $end';
  }

  Future<void> _selectDateRange(BuildContext context) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _refreshLogs();
    }
  }

  void _refreshLogs() {
    ref.invalidate(auditLogsProvider);
    ref.invalidate(errorLogsProvider);
    ref.invalidate(connectionLogsProvider);
  }

  void _exportLogs() {
    // TODO: Implement export
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Export functionality coming soon')),
    );
  }
}
