import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/theme.dart';
import '../providers/clients_provider.dart';
import '../services/api_service.dart';

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
                            onPressed: () => _showEditDialog(context, ref, client),
                            icon: const Icon(Icons.edit),
                            label: const Text('Edit'),
                          ),
                          const SizedBox(width: 8),
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
                            _buildInfoRow(context, 'Hostname', client.hostname ?? 'Not connected yet'),
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

              // Enrollment code card
              _EnrollmentCodeCard(clientId: clientId),
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

  void _showEditDialog(BuildContext context, WidgetRef ref, Client client) {
    showDialog(
      context: context,
      builder: (context) => _EditClientDialog(
        client: client,
        onSaved: () => ref.invalidate(clientDetailProvider(client.id)),
      ),
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

/// Edit Client Dialog
class _EditClientDialog extends ConsumerStatefulWidget {
  final Client client;
  final VoidCallback onSaved;

  const _EditClientDialog({required this.client, required this.onSaved});

  @override
  ConsumerState<_EditClientDialog> createState() => _EditClientDialogState();
}

class _EditClientDialogState extends ConsumerState<_EditClientDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _userEmailController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.client.name);
    _descriptionController = TextEditingController(text: widget.client.description ?? '');
    _userEmailController = TextEditingController(text: widget.client.userEmail ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _userEmailController.dispose();
    super.dispose();
  }

  Future<void> _updateClient() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await ref.read(clientsProvider.notifier).updateClient(
        widget.client.id,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        userEmail: _userEmailController.text.trim().isEmpty
            ? null
            : _userEmailController.text.trim(),
      );
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Client updated successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating client: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Client'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  hintText: 'e.g., laptop-john',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Optional description',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _userEmailController,
                decoration: const InputDecoration(
                  labelText: 'User Email',
                  hintText: 'user@example.com',
                ),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _updateClient,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// Enrollment code card for easy device onboarding
class _EnrollmentCodeCard extends ConsumerStatefulWidget {
  final String clientId;

  const _EnrollmentCodeCard({required this.clientId});

  @override
  ConsumerState<_EnrollmentCodeCard> createState() => _EnrollmentCodeCardState();
}

class _EnrollmentCodeCardState extends ConsumerState<_EnrollmentCodeCard> {
  static const _autoSendPrefKey = 'enrollment_auto_send_email';

  Future<bool> _getAutoSendPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSendPrefKey) ?? true; // Default to ON
  }

  @override
  Widget build(BuildContext context) {
    final enrollmentAsync = ref.watch(enrollmentCodeProvider(widget.clientId));

    return Card(
      color: const Color(0xFF1E3A5F).withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.vpn_key, color: Color(0xFF3B82F6)),
                const SizedBox(width: 8),
                Text(
                  'Enrollment Code',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF3B82F6),
                      ),
                ),
                const Spacer(),
                enrollmentAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (code) => code != null
                      ? TextButton.icon(
                          onPressed: () => _regenerateCode(context),
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Regenerate'),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Share this code with the user to allow them to easily enroll their device.',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
            ),
            const SizedBox(height: 16),
            enrollmentAsync.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),
              error: (error, _) => _buildErrorState(context, error),
              data: (code) => code != null
                  ? _buildCodeDisplay(context, code)
                  : _buildNoCodeState(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeDisplay(BuildContext context, EnrollmentCode code) {
    final isExpired = code.isExpired;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Code display
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isExpired ? AppTheme.error : const Color(0xFF3B82F6),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Server:',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(width: 8),
                        SelectableText(
                          code.serverUrl,
                          style: const TextStyle(
                            fontSize: 14,
                            fontFamily: 'monospace',
                            color: Color(0xFF60A5FA),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16),
                          tooltip: 'Copy server URL',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: code.serverUrl));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Server URL copied to clipboard')),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          'Code:',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(width: 8),
                        SelectableText(
                          code.code,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: 'Copy code',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: code.code));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Code copied to clipboard')),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          isExpired ? Icons.error : Icons.schedule,
                          size: 14,
                          color: isExpired ? AppTheme.error : Colors.grey[500],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isExpired
                              ? 'Expired'
                              : 'Expires in ${code.remainingTimeFormatted}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isExpired ? AppTheme.error : Colors.grey[500],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Deep link
        Row(
          children: [
            Text(
              'Deep Link:',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                code.deepLink,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFF60A5FA),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: 'Copy deep link',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code.deepLink));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Deep link copied to clipboard')),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Action buttons
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => _sendEnrollmentEmail(context),
              icon: const Icon(Icons.send, size: 16),
              label: const Text('Send Email'),
            ),
            OutlinedButton.icon(
              onPressed: () => _copyEnrollmentEmail(context, code),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy Template'),
            ),
            if (isExpired)
              OutlinedButton.icon(
                onPressed: () => _regenerateCode(context),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Generate New Code'),
              )
            else
              OutlinedButton.icon(
                onPressed: () => _revokeCode(context),
                icon: const Icon(Icons.delete_outline, size: 16),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.error,
                ),
                label: const Text('Revoke'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildNoCodeState(BuildContext context) {
    return Center(
      child: Column(
        children: [
          Icon(Icons.vpn_key_off, size: 48, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            'No active enrollment code',
            style: TextStyle(color: Colors.grey[500]),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _generateCode(context),
            icon: const Icon(Icons.add),
            label: const Text('Generate Enrollment Code'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, Object error) {
    return Center(
      child: Column(
        children: [
          Icon(Icons.error_outline, size: 48, color: AppTheme.error),
          const SizedBox(height: 16),
          Text(
            'Error loading enrollment code',
            style: TextStyle(color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),
          Text(
            error.toString(),
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => ref.invalidate(enrollmentCodeProvider(widget.clientId)),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  void _generateCode(BuildContext context) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.generateEnrollmentCode(widget.clientId);
      ref.invalidate(enrollmentCodeProvider(widget.clientId));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enrollment code generated')),
        );
      }

      // Auto-send email if enabled in global settings
      final autoSend = await _getAutoSendPreference();
      if (autoSend && context.mounted) {
        await _sendEnrollmentEmailSilent(context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _regenerateCode(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Regenerate Code'),
        content: const Text(
          'This will invalidate the current enrollment code. '
          'Any user who has not yet redeemed the code will need the new one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _generateCode(context);
    }
  }

  void _revokeCode(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke Code'),
        content: const Text(
          'This will invalidate the enrollment code. '
          'The user will not be able to use it to enroll their device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final api = ref.read(apiServiceProvider);
        await api.revokeEnrollmentCode(widget.clientId);
        ref.invalidate(enrollmentCodeProvider(widget.clientId));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enrollment code revoked')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  void _copyEnrollmentEmail(BuildContext context, EnrollmentCode code) {
    // Extract domain from deep link
    final uri = Uri.parse(code.deepLink);
    final serverParam = uri.queryParameters['server'] ?? '';
    final domain = serverParam.replaceAll(RegExp(r'^https?://'), '');

    final emailTemplate = '''
Subject: Your SecureGuard VPN Access

Hi,

You've been granted VPN access. Click the link below to set up SecureGuard:

${code.deepLink}

If the link doesn't work, open the SecureGuard app and enter:
  - Domain: $domain
  - Code: ${code.code}

This enrollment expires in ${code.remainingTimeFormatted}.

Need help? Contact your IT administrator.
''';

    Clipboard.setData(ClipboardData(text: emailTemplate));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Email template copied to clipboard')),
    );
  }

  /// Send enrollment email with confirmation dialog
  void _sendEnrollmentEmail(BuildContext context) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Enrollment Email'),
        content: const Text(
          'This will send an enrollment email to the user\'s email address. '
          'Make sure email settings are configured in Settings > Email.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Send'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _sendEnrollmentEmailSilent(context);
  }

  /// Send enrollment email without confirmation (for auto-send)
  Future<void> _sendEnrollmentEmailSilent(BuildContext context) async {
    try {
      final api = ref.read(apiServiceProvider);
      final result = await api.sendEnrollmentEmail(widget.clientId);

      if (context.mounted) {
        final toEmail = result['to_email'] as String?;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              toEmail != null
                  ? 'Enrollment email queued for $toEmail'
                  : 'Enrollment email queued',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        String errorMessage = e.toString();

        // Check for specific error types
        if (errorMessage.contains('no_email')) {
          errorMessage = 'Client has no email address. Add an email in the client details.';
        } else if (errorMessage.contains('email_not_configured')) {
          errorMessage = 'Email service not configured. Configure SMTP in Settings > Email.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send email: $errorMessage'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}
