import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../services/api_service.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Server Configuration
            _buildSection(
              context,
              title: 'Server Configuration',
              icon: Icons.dns,
              child: _ServerConfigSection(),
            ),
            const SizedBox(height: 24),

            // Admin Users
            _buildSection(
              context,
              title: 'Admin Users',
              icon: Icons.admin_panel_settings,
              child: _AdminUsersSection(),
            ),
            const SizedBox(height: 24),

            // SSO Configuration
            _buildSection(
              context,
              title: 'Single Sign-On (SSO)',
              icon: Icons.security,
              child: _SSOConfigSection(),
            ),
            const SizedBox(height: 24),

            // API Keys
            _buildSection(
              context,
              title: 'API Keys',
              icon: Icons.key,
              child: _ApiKeysSection(),
            ),
            const SizedBox(height: 24),

            // About
            _buildSection(
              context,
              title: 'About',
              icon: Icons.info_outline,
              child: _AboutSection(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 24, color: AppTheme.primary),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const Divider(height: 32),
            child,
          ],
        ),
      ),
    );
  }
}

class _ServerConfigSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ServerConfigSection> createState() => _ServerConfigSectionState();
}

class _ServerConfigSectionState extends ConsumerState<_ServerConfigSection> {
  final _formKey = GlobalKey<FormState>();
  final _endpointController = TextEditingController();
  final _portController = TextEditingController();
  final _subnetController = TextEditingController();
  final _dnsController = TextEditingController();
  final _mtuController = TextEditingController();
  bool _isLoading = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _loadConfig() {
    // In a real app, load from server
    _endpointController.text = 'vpn.example.com';
    _portController.text = '51820';
    _subnetController.text = '10.0.0.0/24';
    _dnsController.text = '1.1.1.1, 8.8.8.8';
    _mtuController.text = '1420';
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _portController.dispose();
    _subnetController.dispose();
    _dnsController.dispose();
    _mtuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      onChanged: () => setState(() => _hasChanges = true),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _endpointController,
                  decoration: const InputDecoration(
                    labelText: 'Endpoint',
                    hintText: 'vpn.example.com',
                    helperText: 'Public hostname or IP for VPN server',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Endpoint is required';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _portController,
                  decoration: const InputDecoration(
                    labelText: 'Listen Port',
                    hintText: '51820',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Port is required';
                    }
                    final port = int.tryParse(value);
                    if (port == null || port < 1 || port > 65535) {
                      return 'Invalid port';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _subnetController,
                  decoration: const InputDecoration(
                    labelText: 'IP Subnet',
                    hintText: '10.0.0.0/24',
                    helperText: 'CIDR notation for VPN network',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Subnet is required';
                    }
                    if (!value.contains('/')) {
                      return 'Use CIDR notation (e.g., 10.0.0.0/24)';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _mtuController,
                  decoration: const InputDecoration(
                    labelText: 'MTU',
                    hintText: '1420',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _dnsController,
            decoration: const InputDecoration(
              labelText: 'DNS Servers',
              hintText: '1.1.1.1, 8.8.8.8',
              helperText: 'Comma-separated list of DNS servers',
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _hasChanges ? _loadConfig : null,
                child: const Text('Reset'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _hasChanges && !_isLoading ? _saveConfig : null,
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save Changes'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      // Save config via API
      await Future.delayed(const Duration(seconds: 1)); // Simulate API call
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasChanges = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuration saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving configuration: $e')),
        );
      }
    }
  }
}

class _AdminUsersSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mock data - in real app, fetch from API
    final admins = [
      {'email': 'admin@example.com', 'role': 'Super Admin', 'lastLogin': '2h ago'},
      {'email': 'ops@example.com', 'role': 'Admin', 'lastLogin': '1d ago'},
    ];

    return Column(
      children: [
        ...admins.map((admin) => ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(admin['email']!),
              subtitle: Text(admin['role']!),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Last login: ${admin['lastLogin']}',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit',
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                    onPressed: () {},
                  ),
                ],
              ),
            )),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _showAddAdminDialog(context),
          icon: const Icon(Icons.add),
          label: const Text('Add Admin'),
        ),
      ],
    );
  }

  void _showAddAdminDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Admin User'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'admin@example.com',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Password',
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Role'),
                value: 'admin',
                items: const [
                  DropdownMenuItem(value: 'admin', child: Text('Admin')),
                  DropdownMenuItem(value: 'viewer', child: Text('Viewer')),
                ],
                onChanged: (value) {},
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Admin user created')),
              );
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class _SSOConfigSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SSOConfigSection> createState() => _SSOConfigSectionState();
}

class _SSOConfigSectionState extends ConsumerState<_SSOConfigSection> {
  List<SSOConfig> _configs = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final configs = await api.getSSOConfigs();
      if (mounted) {
        setState(() {
          _configs = configs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Column(
        children: [
          Text('Failed to load SSO configs: $_error'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadConfigs,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Configure SSO providers to allow users to authenticate with their corporate identity.',
          style: TextStyle(color: Colors.grey[600]),
        ),
        const SizedBox(height: 16),

        // List existing configs
        if (_configs.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.grey[500]),
                const SizedBox(width: 12),
                const Text('No SSO providers configured'),
              ],
            ),
          )
        else
          ..._configs.map((config) => _buildProviderCard(config)),

        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _showAddProviderDialog(context),
          icon: const Icon(Icons.add),
          label: const Text('Add SSO Provider'),
        ),
      ],
    );
  }

  Widget _buildProviderCard(SSOConfig config) {
    final providerName = _getProviderDisplayName(config.providerId);
    final providerIcon = _getProviderIcon(config.providerId);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(providerIcon, size: 32, color: AppTheme.primary),
        title: Text(providerName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Client ID: ${_maskString(config.clientId)}'),
            if (config.tenantId != null)
              Text('Tenant: ${config.tenantId}', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: config.enabled,
              onChanged: (enabled) => _toggleProvider(config, enabled),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () => _showEditProviderDialog(context, config),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: () => _confirmDelete(context, config),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  String _getProviderDisplayName(String providerId) {
    switch (providerId) {
      case 'azure':
        return 'Microsoft Entra ID (Azure AD)';
      case 'okta':
        return 'Okta';
      case 'google':
        return 'Google Workspace';
      default:
        return providerId.toUpperCase();
    }
  }

  IconData _getProviderIcon(String providerId) {
    switch (providerId) {
      case 'azure':
        return Icons.window;
      case 'okta':
        return Icons.shield;
      case 'google':
        return Icons.g_mobiledata;
      default:
        return Icons.security;
    }
  }

  String _maskString(String value) {
    if (value.length <= 8) return '****';
    return '${value.substring(0, 4)}...${value.substring(value.length - 4)}';
  }

  Future<void> _toggleProvider(SSOConfig config, bool enabled) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.saveSSOConfig(SSOConfig(
        providerId: config.providerId,
        clientId: config.clientId,
        clientSecret: config.clientSecret,
        tenantId: config.tenantId,
        domain: config.domain,
        scopes: config.scopes,
        enabled: enabled,
      ));
      await _loadConfigs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update provider: $e')),
        );
      }
    }
  }

  void _confirmDelete(BuildContext context, SSOConfig config) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete SSO Provider'),
        content: Text(
          'Are you sure you want to delete ${_getProviderDisplayName(config.providerId)}? '
          'Users will no longer be able to sign in with this provider.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                final api = ref.read(apiServiceProvider);
                await api.deleteSSOConfig(config.providerId);
                await _loadConfigs();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('SSO provider deleted')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to delete: $e')),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showAddProviderDialog(BuildContext context) {
    _showProviderDialog(context, null);
  }

  void _showEditProviderDialog(BuildContext context, SSOConfig config) {
    _showProviderDialog(context, config);
  }

  void _showProviderDialog(BuildContext context, SSOConfig? existingConfig) {
    final isEdit = existingConfig != null;
    String selectedProvider = existingConfig?.providerId ?? 'azure';
    final clientIdController = TextEditingController(text: existingConfig?.clientId);
    final clientSecretController = TextEditingController(text: existingConfig?.clientSecret);
    final tenantIdController = TextEditingController(text: existingConfig?.tenantId);
    final domainController = TextEditingController(text: existingConfig?.domain);
    bool enabled = existingConfig?.enabled ?? true;
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEdit ? 'Edit SSO Provider' : 'Add SSO Provider'),
          content: SizedBox(
            width: 500,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isEdit) ...[
                      DropdownButtonFormField<String>(
                        value: selectedProvider,
                        decoration: const InputDecoration(labelText: 'Provider'),
                        items: const [
                          DropdownMenuItem(value: 'azure', child: Text('Microsoft Entra ID (Azure AD)')),
                          DropdownMenuItem(value: 'okta', child: Text('Okta')),
                          DropdownMenuItem(value: 'google', child: Text('Google Workspace')),
                        ],
                        onChanged: (value) {
                          setDialogState(() => selectedProvider = value!);
                        },
                      ),
                      const SizedBox(height: 16),
                    ],

                    TextFormField(
                      controller: clientIdController,
                      decoration: const InputDecoration(
                        labelText: 'Client ID',
                        hintText: 'Application (client) ID',
                        helperText: 'Found in your identity provider\'s app registration',
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Client ID is required';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: clientSecretController,
                      decoration: InputDecoration(
                        labelText: 'Client Secret',
                        hintText: isEdit ? '(unchanged)' : 'Application secret',
                        helperText: 'Leave empty for public clients (PKCE only)',
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 16),

                    // Provider-specific fields
                    if (selectedProvider == 'azure') ...[
                      TextFormField(
                        controller: tenantIdController,
                        decoration: const InputDecoration(
                          labelText: 'Tenant ID',
                          hintText: 'Directory (tenant) ID or domain',
                          helperText: 'Use "common" for multi-tenant apps',
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Tenant ID is required for Azure AD';
                          }
                          return null;
                        },
                      ),
                    ],

                    if (selectedProvider == 'okta') ...[
                      TextFormField(
                        controller: domainController,
                        decoration: const InputDecoration(
                          labelText: 'Okta Domain',
                          hintText: 'your-org.okta.com',
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Domain is required for Okta';
                          }
                          return null;
                        },
                      ),
                    ],

                    if (selectedProvider == 'google') ...[
                      TextFormField(
                        controller: domainController,
                        decoration: const InputDecoration(
                          labelText: 'Hosted Domain (optional)',
                          hintText: 'example.com',
                          helperText: 'Restrict login to users from this Google Workspace domain',
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Enabled'),
                      subtitle: const Text('Allow users to sign in with this provider'),
                      value: enabled,
                      onChanged: (value) => setDialogState(() => enabled = value),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;

                Navigator.of(context).pop();

                try {
                  final api = ref.read(apiServiceProvider);
                  await api.saveSSOConfig(SSOConfig(
                    providerId: selectedProvider,
                    clientId: clientIdController.text,
                    clientSecret: clientSecretController.text.isNotEmpty
                        ? clientSecretController.text
                        : existingConfig?.clientSecret,
                    tenantId: tenantIdController.text.isNotEmpty ? tenantIdController.text : null,
                    domain: domainController.text.isNotEmpty ? domainController.text : null,
                    enabled: enabled,
                  ));
                  await _loadConfigs();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('SSO provider ${isEdit ? 'updated' : 'added'}')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to save: $e')),
                    );
                  }
                }
              },
              child: Text(isEdit ? 'Save' : 'Add'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApiKeysSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Mock data
    final apiKeys = [
      {'name': 'CI/CD Pipeline', 'prefix': 'sg_...abc123', 'created': '30d ago'},
      {'name': 'Monitoring', 'prefix': 'sg_...def456', 'created': '7d ago'},
    ];

    return Column(
      children: [
        ...apiKeys.map((key) => ListTile(
              leading: const Icon(Icons.vpn_key),
              title: Text(key['name']!),
              subtitle: Text(key['prefix']!),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Created: ${key['created']}',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Revoke',
                    onPressed: () => _confirmRevoke(context, key['name']!),
                  ),
                ],
              ),
            )),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _showCreateKeyDialog(context),
          icon: const Icon(Icons.add),
          label: const Text('Create API Key'),
        ),
      ],
    );
  }

  void _confirmRevoke(BuildContext context, String name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke API Key'),
        content: Text('Are you sure you want to revoke "$name"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('API key revoked')),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }

  void _showCreateKeyDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create API Key'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g., CI/CD Pipeline',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Permissions'),
                value: 'read',
                items: const [
                  DropdownMenuItem(value: 'read', child: Text('Read Only')),
                  DropdownMenuItem(value: 'write', child: Text('Read/Write')),
                  DropdownMenuItem(value: 'admin', child: Text('Full Access')),
                ],
                onChanged: (value) {},
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Show the generated key
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('API Key Created'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Copy this key now. You won\'t be able to see it again.',
                        style: TextStyle(color: Colors.amber),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: SelectableText(
                                'sg_live_AbCdEfGhIjKlMnOpQrStUvWxYz123456',
                                style: TextStyle(fontFamily: 'monospace'),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy),
                              onPressed: () {
                                Clipboard.setData(const ClipboardData(
                                  text: 'sg_live_AbCdEfGhIjKlMnOpQrStUvWxYz123456',
                                ));
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
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildInfoRow('Version', '1.0.0'),
        _buildInfoRow('Server Version', '1.0.0'),
        _buildInfoRow('Build', '2024.01.15'),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.description),
              label: const Text('Documentation'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.bug_report),
              label: const Text('Report Issue'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Text(value),
        ],
      ),
    );
  }
}
