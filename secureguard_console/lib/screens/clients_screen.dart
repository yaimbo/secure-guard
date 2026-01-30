import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:data_table_2/data_table_2.dart';

import '../config/theme.dart';
import '../providers/clients_provider.dart';

class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({super.key});

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends ConsumerState<ClientsScreen> {
  final _searchController = TextEditingController();
  String _statusFilter = 'all';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clientsAsync = ref.watch(clientsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clients'),
        actions: [
          FilledButton.icon(
            onPressed: () => _showCreateClientDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Add Client'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Filters row
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'Search clients...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      ref.read(clientsProvider.notifier).search(value);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 200,
                  child: DropdownButtonFormField<String>(
                    value: _statusFilter,
                    decoration: const InputDecoration(
                      labelText: 'Status',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All')),
                      DropdownMenuItem(value: 'active', child: Text('Active')),
                      DropdownMenuItem(value: 'disabled', child: Text('Disabled')),
                      DropdownMenuItem(value: 'pending', child: Text('Pending')),
                    ],
                    onChanged: (value) {
                      setState(() => _statusFilter = value ?? 'all');
                      ref.read(clientsProvider.notifier).filterByStatus(value);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: () {
                    ref.read(clientsProvider.notifier).refresh();
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Data table
            Expanded(
              child: Card(
                child: clientsAsync.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, stack) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                        const SizedBox(height: 16),
                        Text('Error loading clients: $error'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => ref.read(clientsProvider.notifier).refresh(),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (clients) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: DataTable2(
                    columnSpacing: 12,
                    horizontalMargin: 12,
                    minWidth: 800,
                    dataRowColor: WidgetStateProperty.resolveWith<Color?>((states) {
                      if (states.contains(WidgetState.hovered)) {
                        return Theme.of(context).colorScheme.primary.withValues(alpha: 0.08);
                      }
                      return null;
                    }),
                    columns: const [
                      DataColumn2(label: Text('Status'), size: ColumnSize.S),
                      DataColumn2(label: Text('Name'), size: ColumnSize.L),
                      DataColumn2(label: Text('User'), size: ColumnSize.M),
                      DataColumn2(label: Text('IP Address'), size: ColumnSize.M),
                      DataColumn2(label: Text('Last Seen'), size: ColumnSize.M),
                      DataColumn2(label: Text('Actions'), size: ColumnSize.M),
                    ],
                    rows: clients.map((client) {
                      return DataRow2(
                        onTap: () => context.go('/clients/${client.id}'),
                        cells: [
                          DataCell(
                            _StatusWithAlertIndicator(
                              clientId: client.id,
                              statusColor: _getStatusColor(client.status),
                            ),
                          ),
                          DataCell(
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(client.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                                if (client.description != null)
                                  Text(
                                    client.description!,
                                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          DataCell(Text(client.userEmail ?? '-')),
                          DataCell(Text(client.assignedIp)),
                          DataCell(Text(_formatLastSeen(client.lastSeenAt))),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 20),
                                  tooltip: 'Edit',
                                  onPressed: () => _showEditClientDialog(context, client),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.download, size: 20),
                                  tooltip: 'Download Config',
                                  onPressed: () => _downloadConfig(client.id),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.qr_code, size: 20),
                                  tooltip: 'Show QR Code',
                                  onPressed: () => _showQrCode(context, client.id),
                                ),
                                IconButton(
                                  icon: Icon(
                                    client.status == 'active' ? Icons.block : Icons.check_circle,
                                    size: 20,
                                  ),
                                  tooltip: client.status == 'active' ? 'Disable' : 'Enable',
                                  onPressed: () => _toggleClientStatus(client),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  tooltip: 'Delete',
                                  onPressed: () => _confirmDelete(context, client),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                  ),
                ),
              ),
            ),
          ],
        ),
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

  String _formatLastSeen(DateTime? lastSeen) {
    if (lastSeen == null) return 'Never';

    final now = DateTime.now();
    final diff = now.difference(lastSeen);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return '${lastSeen.month}/${lastSeen.day}/${lastSeen.year}';
  }

  void _showCreateClientDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const CreateClientDialog(),
    );
  }

  void _showEditClientDialog(BuildContext context, Client client) {
    showDialog(
      context: context,
      builder: (context) => EditClientDialog(client: client),
    );
  }

  void _downloadConfig(String clientId) {
    ref.read(clientsProvider.notifier).downloadConfig(clientId);
  }

  void _showQrCode(BuildContext context, String clientId) {
    showDialog(
      context: context,
      builder: (context) => QrCodeDialog(clientId: clientId),
    );
  }

  void _toggleClientStatus(Client client) {
    if (client.status == 'active') {
      ref.read(clientsProvider.notifier).disableClient(client.id);
    } else {
      ref.read(clientsProvider.notifier).enableClient(client.id);
    }
  }

  void _confirmDelete(BuildContext context, Client client) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Client'),
        content: Text('Are you sure you want to delete "${client.name}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(clientsProvider.notifier).deleteClient(client.id);
              Navigator.of(context).pop();
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// Create Client Dialog
class CreateClientDialog extends ConsumerStatefulWidget {
  const CreateClientDialog({super.key});

  @override
  ConsumerState<CreateClientDialog> createState() => _CreateClientDialogState();
}

class _CreateClientDialogState extends ConsumerState<CreateClientDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _userEmailController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _userEmailController.dispose();
    super.dispose();
  }

  Future<void> _createClient() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await ref.read(clientsProvider.notifier).createClient(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        userEmail: _userEmailController.text.trim().isEmpty
            ? null
            : _userEmailController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating client: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create New Client'),
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
          onPressed: _isLoading ? null : _createClient,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}

// Edit Client Dialog
class EditClientDialog extends ConsumerStatefulWidget {
  final Client client;

  const EditClientDialog({super.key, required this.client});

  @override
  ConsumerState<EditClientDialog> createState() => _EditClientDialogState();
}

class _EditClientDialogState extends ConsumerState<EditClientDialog> {
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

// QR Code Dialog
class QrCodeDialog extends ConsumerWidget {
  final String clientId;

  const QrCodeDialog({super.key, required this.clientId});

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

// Status indicator with security alert icon
class _StatusWithAlertIndicator extends ConsumerWidget {
  final String clientId;
  final Color statusColor;

  const _StatusWithAlertIndicator({
    required this.clientId,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(clientSecurityAlertsProvider(clientId));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
          ),
        ),
        alertsAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (alerts) {
            if (!alerts.hasAlerts) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Tooltip(
                message: '${alerts.alertCount} security alert${alerts.alertCount > 1 ? 's' : ''} - Click to view',
                child: InkWell(
                  onTap: () {
                    // Navigate to logs filtered by this client's security alerts
                    context.go('/logs?tab=audit&resource_type=client&resource_id=$clientId&event_type=HOSTNAME_MISMATCH');
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: AppTheme.warning,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
