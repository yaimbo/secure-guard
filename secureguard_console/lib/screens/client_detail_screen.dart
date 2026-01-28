import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config/theme.dart';
import '../providers/clients_provider.dart';

class ClientDetailScreen extends ConsumerWidget {
  final String clientId;

  const ClientDetailScreen({super.key, required this.clientId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clientAsync = ref.watch(clientDetailProvider(clientId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/clients'),
        ),
        title: const Text('Client Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.refresh(clientDetailProvider(clientId)),
          ),
        ],
      ),
      body: clientAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: AppTheme.error),
              const SizedBox(height: 16),
              Text('Error loading client: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.refresh(clientDetailProvider(clientId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (client) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header card with status
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _getStatusColor(client.status).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.devices,
                          size: 48,
                          color: _getStatusColor(client.status),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  client.name,
                                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                                const SizedBox(width: 12),
                                _buildStatusChip(context, client.status),
                              ],
                            ),
                            if (client.description != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                client.description!,
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // Actions
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _downloadConfig(ref, client.id),
                            icon: const Icon(Icons.download),
                            label: const Text('Download Config'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _showQrCode(context, ref, client.id),
                            icon: const Icon(Icons.qr_code),
                            label: const Text('QR Code'),
                          ),
                          const SizedBox(width: 8),
                          if (client.status == 'active')
                            FilledButton.icon(
                              onPressed: () => _disableClient(ref, client.id),
                              icon: const Icon(Icons.block),
                              label: const Text('Disable'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.warning,
                              ),
                            )
                          else
                            FilledButton.icon(
                              onPressed: () => _enableClient(ref, client.id),
                              icon: const Icon(Icons.check_circle),
                              label: const Text('Enable'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.connected,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Info sections
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Client info
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Client Information',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            _buildInfoRow(context, 'ID', client.id, copyable: true),
                            _buildInfoRow(context, 'Name', client.name),
                            _buildInfoRow(context, 'Description', client.description ?? '-'),
                            _buildInfoRow(context, 'Status', client.status),
                            _buildInfoRow(context, 'Created', _formatDateTime(client.createdAt)),
                            _buildInfoRow(context, 'Updated', _formatDateTime(client.updatedAt)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // User info
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'User Information',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            _buildInfoRow(context, 'Email', client.userEmail ?? '-'),
                            _buildInfoRow(context, 'Name', client.userName ?? '-'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Network info
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Network Information',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            _buildInfoRow(context, 'Assigned IP', client.assignedIp, copyable: true),
                            _buildInfoRow(context, 'Last Seen', _formatLastSeen(client.lastSeenAt)),
                            _buildInfoRow(context, 'Last Config Fetch', _formatLastSeen(client.lastConfigFetch)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Device info
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Device Information',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            _buildInfoRow(context, 'Platform', client.platform ?? '-'),
                            _buildInfoRow(context, 'Client Version', client.clientVersion ?? '-'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
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
                                  'Recent Activity',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                TextButton(
                                  onPressed: () => context.go('/logs?client=$clientId'),
                                  child: const Text('View All'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Placeholder for recent activity
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                  'No recent activity',
                                  style: TextStyle(color: Colors.grey[500]),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Danger zone
              Card(
                color: AppTheme.error.withValues(alpha: 0.05),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Danger Zone',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: AppTheme.error,
                            ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Regenerate Keys'),
                                Text(
                                  'Generate new WireGuard keys. The client will need to download a new config.',
                                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                          OutlinedButton(
                            onPressed: () => _confirmRegenerateKeys(context, ref, client),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.warning,
                            ),
                            child: const Text('Regenerate'),
                          ),
                        ],
                      ),
                      const Divider(height: 32),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Delete Client'),
                                Text(
                                  'Permanently delete this client. This action cannot be undone.',
                                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            onPressed: () => _confirmDelete(context, ref, client),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.error,
                            ),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context, String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: _getStatusColor(status).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: _getStatusColor(status),
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value, {bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey[500]),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                if (copyable && value != '-')
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: 'Copy',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Copied to clipboard')),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'active':
        return AppTheme.connected;
      case 'disabled':
        return AppTheme.disconnected;
      case 'pending':
        return AppTheme.warning;
      default:
        return Colors.grey;
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatLastSeen(DateTime? lastSeen) {
    if (lastSeen == null) return 'Never';

    final now = DateTime.now();
    final diff = now.difference(lastSeen);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return _formatDateTime(lastSeen);
  }

  void _downloadConfig(WidgetRef ref, String id) {
    ref.read(clientsProvider.notifier).downloadConfig(id);
  }

  void _showQrCode(BuildContext context, WidgetRef ref, String id) {
    showDialog(
      context: context,
      builder: (context) => _QrCodeDialog(clientId: id),
    );
  }

  void _enableClient(WidgetRef ref, String id) async {
    await ref.read(clientsProvider.notifier).enableClient(id);
    ref.invalidate(clientDetailProvider(id));
  }

  void _disableClient(WidgetRef ref, String id) async {
    await ref.read(clientsProvider.notifier).disableClient(id);
    ref.invalidate(clientDetailProvider(id));
  }

  void _confirmRegenerateKeys(BuildContext context, WidgetRef ref, Client client) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Regenerate Keys'),
        content: Text(
          'Are you sure you want to regenerate keys for "${client.name}"? '
          'The client will need to download a new configuration.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              // TODO: Implement regenerate keys
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, Client client) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Client'),
        content: Text(
          'Are you sure you want to delete "${client.name}"? '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(clientsProvider.notifier).deleteClient(client.id);
              if (context.mounted) {
                context.go('/clients');
              }
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _QrCodeDialog extends ConsumerWidget {
  final String clientId;

  const _QrCodeDialog({required this.clientId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qrAsync = ref.watch(clientQrCodeProvider(clientId));

    return AlertDialog(
      title: const Text('Configuration QR Code'),
      content: SizedBox(
        width: 300,
        height: 300,
        child: qrAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: Text('Error loading QR code: $error'),
          ),
          data: (qrData) => Center(
            child: Image.memory(qrData),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
