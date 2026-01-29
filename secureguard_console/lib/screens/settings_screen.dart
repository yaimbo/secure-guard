import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../providers/settings_provider.dart';
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

            // Email Settings
            _buildSection(
              context,
              title: 'Email Settings',
              icon: Icons.email,
              child: _EmailSettingsSection(),
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

  bool _isLoading = true;
  bool _isSaving = false;
  bool _hasChanges = false;
  String? _error;
  String? _publicKey;
  bool _configured = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final settings = await api.getVpnSettings();
      if (mounted) {
        setState(() {
          _configured = settings.configured;
          _endpointController.text = settings.endpoint ?? '';
          _portController.text = settings.listenPort.toString();
          _subnetController.text = settings.ipSubnet;
          _dnsController.text = settings.dnsServers?.join(', ') ?? '';
          _mtuController.text = settings.mtu.toString();
          _publicKey = settings.publicKey;
          _isLoading = false;
          _hasChanges = false;
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
          Text('Failed to load VPN settings: $_error'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadConfig,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Form(
      key: _formKey,
      onChanged: () => setState(() => _hasChanges = true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show status banner
          if (_configured && _publicKey != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('VPN Server Configured',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        SelectableText('Public Key: $_publicKey',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.amber, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('VPN server not configured. Configure settings below to enable client creation.'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _endpointController,
                  decoration: const InputDecoration(
                    labelText: 'Endpoint',
                    hintText: 'vpn.example.com:51820',
                    helperText: 'Public hostname:port for VPN server',
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
                onPressed: _hasChanges && !_isSaving ? _saveConfig : null,
                child: _isSaving
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

    setState(() => _isSaving = true);
    try {
      final api = ref.read(apiServiceProvider);

      // Parse DNS servers
      final dnsText = _dnsController.text.trim();
      final dnsServers = dnsText.isNotEmpty
          ? dnsText.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
          : null;

      final settings = VpnSettings(
        endpoint: _endpointController.text.trim(),
        listenPort: int.tryParse(_portController.text) ?? 51820,
        ipSubnet: _subnetController.text.trim(),
        dnsServers: dnsServers,
        mtu: int.tryParse(_mtuController.text) ?? 1420,
      );

      await api.updateVpnSettings(settings);
      await _loadConfig(); // Reload to get updated public key

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('VPN configuration saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving configuration: $e')),
        );
      }
    }
  }
}

class _AdminUsersSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AdminUsersSection> createState() => _AdminUsersSectionState();
}

class _AdminUsersSectionState extends ConsumerState<_AdminUsersSection> {
  List<AdminUser> _admins = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAdmins();
  }

  Future<void> _loadAdmins() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final admins = await api.getAdminUsers();
      if (mounted) {
        setState(() {
          _admins = admins;
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

  String _formatLastLogin(DateTime? lastLogin) {
    if (lastLogin == null) return 'Never';
    final diff = DateTime.now().difference(lastLogin);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
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
          Text('Failed to load admin users: $_error'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadAdmins,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Column(
      children: [
        ..._admins.map((admin) => ListTile(
              leading: CircleAvatar(
                backgroundColor: admin.isActive ? AppTheme.primary : Colors.grey,
                child: const Icon(Icons.person, color: Colors.white),
              ),
              title: Text(admin.email),
              subtitle: Text(admin.role == 'super_admin' ? 'Super Admin' : 'Admin'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Last login: ${_formatLastLogin(admin.lastLoginAt)}',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                    onPressed: () => _confirmDelete(admin),
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

  Future<void> _confirmDelete(AdminUser admin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Admin'),
        content: Text('Are you sure you want to delete ${admin.email}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        final api = ref.read(apiServiceProvider);
        await api.deleteAdminUser(admin.id);
        await _loadAdmins();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Admin deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete admin: $e')),
          );
        }
      }
    }
  }

  void _showAddAdminDialog(BuildContext context) {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    String role = 'admin';
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Admin User'),
          content: SizedBox(
            width: 400,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      hintText: 'admin@example.com',
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Email is required';
                      }
                      if (!value.contains('@')) {
                        return 'Invalid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                    ),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.length < 8) {
                        return 'Password must be at least 8 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Role'),
                    value: role,
                    items: const [
                      DropdownMenuItem(value: 'admin', child: Text('Admin')),
                      DropdownMenuItem(value: 'super_admin', child: Text('Super Admin')),
                    ],
                    onChanged: (value) => setDialogState(() => role = value!),
                  ),
                ],
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
                  await api.createAdminUser(
                    email: emailController.text,
                    password: passwordController.text,
                    role: role,
                  );
                  await _loadAdmins();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Admin user created')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to create admin: $e')),
                    );
                  }
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
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

class _EmailSettingsSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_EmailSettingsSection> createState() => _EmailSettingsSectionState();
}

class _EmailSettingsSectionState extends ConsumerState<_EmailSettingsSection> {
  final _formKey = GlobalKey<FormState>();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _fromEmailController = TextEditingController();
  final _fromNameController = TextEditingController();
  final _testEmailController = TextEditingController();

  bool _enabled = false;
  bool _useSsl = false;
  bool _useStarttls = true;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isTesting = false;
  bool _hasChanges = false;
  String? _error;
  EmailSettings? _originalSettings;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final settings = await api.getEmailSettings();
      if (mounted) {
        setState(() {
          _originalSettings = settings;
          _enabled = settings.enabled;
          _hostController.text = settings.smtpHost ?? '';
          _portController.text = settings.smtpPort.toString();
          _usernameController.text = settings.smtpUsername ?? '';
          _passwordController.text = ''; // Don't populate password
          _fromEmailController.text = settings.fromEmail ?? '';
          _fromNameController.text = settings.fromName;
          _useSsl = settings.useSsl;
          _useStarttls = settings.useStarttls;
          _isLoading = false;
          _hasChanges = false;
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
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _fromEmailController.dispose();
    _fromNameController.dispose();
    _testEmailController.dispose();
    super.dispose();
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
          Text('Failed to load email settings: $_error'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadSettings,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Form(
      key: _formKey,
      onChanged: () => setState(() => _hasChanges = true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Configure SMTP settings to send enrollment emails directly from the console.',
            style: TextStyle(color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),

          // Enable/disable toggle
          SwitchListTile(
            title: const Text('Enable SMTP Email'),
            subtitle: const Text('Send enrollment emails to users'),
            value: _enabled,
            onChanged: (value) => setState(() {
              _enabled = value;
              _hasChanges = true;
            }),
          ),
          const Divider(height: 32),

          // SMTP Server settings
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _hostController,
                  decoration: const InputDecoration(
                    labelText: 'SMTP Server',
                    hintText: 'smtp.example.com',
                  ),
                  enabled: _enabled,
                  validator: (value) {
                    if (_enabled && (value == null || value.isEmpty)) {
                      return 'SMTP server is required';
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
                    labelText: 'Port',
                    hintText: '587',
                  ),
                  enabled: _enabled,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) {
                    if (_enabled && (value == null || value.isEmpty)) {
                      return 'Port required';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Authentication
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    hintText: 'noreply@example.com',
                  ),
                  enabled: _enabled,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: _originalSettings?.hasPassword == true
                        ? '(unchanged)'
                        : 'SMTP password',
                  ),
                  enabled: _enabled,
                  obscureText: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Security options
          Text(
            'Security',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('STARTTLS'),
                  subtitle: const Text('Recommended'),
                  value: 'starttls',
                  groupValue: _useSsl ? 'ssl' : (_useStarttls ? 'starttls' : 'none'),
                  onChanged: _enabled ? (value) => setState(() {
                    _useSsl = false;
                    _useStarttls = true;
                    _hasChanges = true;
                  }) : null,
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('SSL/TLS'),
                  subtitle: const Text('Port 465'),
                  value: 'ssl',
                  groupValue: _useSsl ? 'ssl' : (_useStarttls ? 'starttls' : 'none'),
                  onChanged: _enabled ? (value) => setState(() {
                    _useSsl = true;
                    _useStarttls = false;
                    _hasChanges = true;
                  }) : null,
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('None'),
                  subtitle: const Text('Not recommended'),
                  value: 'none',
                  groupValue: _useSsl ? 'ssl' : (_useStarttls ? 'starttls' : 'none'),
                  onChanged: _enabled ? (value) => setState(() {
                    _useSsl = false;
                    _useStarttls = false;
                    _hasChanges = true;
                  }) : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // From address
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _fromEmailController,
                  decoration: const InputDecoration(
                    labelText: 'From Email',
                    hintText: 'vpn@example.com',
                  ),
                  enabled: _enabled,
                  validator: (value) {
                    if (_enabled && (value == null || value.isEmpty)) {
                      return 'From email is required';
                    }
                    if (_enabled && value != null && !value.contains('@')) {
                      return 'Invalid email address';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  controller: _fromNameController,
                  decoration: const InputDecoration(
                    labelText: 'From Name',
                    hintText: 'SecureGuard VPN',
                  ),
                  enabled: _enabled,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Test connection
          if (_enabled) ...[
            Text(
              'Test Email',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _testEmailController,
                    decoration: const InputDecoration(
                      labelText: 'Test Recipient',
                      hintText: 'your@email.com',
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _isTesting ? null : _testEmail,
                  icon: _isTesting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: const Text('Send Test'),
                ),
              ],
            ),

            // Last test status
            if (_originalSettings?.lastTestAt != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _originalSettings!.lastTestSuccess == true
                        ? Icons.check_circle
                        : Icons.error,
                    size: 16,
                    color: _originalSettings!.lastTestSuccess == true
                        ? Colors.green
                        : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _originalSettings!.lastTestSuccess == true
                        ? 'Last test successful'
                        : 'Last test failed',
                    style: TextStyle(
                      color: _originalSettings!.lastTestSuccess == true
                          ? Colors.green
                          : Colors.red,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '(${_formatTimeAgo(_originalSettings!.lastTestAt!)})',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
          ],

          // Save button
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _hasChanges ? _loadSettings : null,
                child: const Text('Reset'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _hasChanges && !_isSaving ? _saveSettings : null,
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save Settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final api = ref.read(apiServiceProvider);
      final settings = EmailSettings(
        enabled: _enabled,
        smtpHost: _hostController.text.isNotEmpty ? _hostController.text : null,
        smtpPort: int.tryParse(_portController.text) ?? 587,
        smtpUsername: _usernameController.text.isNotEmpty ? _usernameController.text : null,
        smtpPassword: _passwordController.text.isNotEmpty ? _passwordController.text : null,
        useSsl: _useSsl,
        useStarttls: _useStarttls,
        fromEmail: _fromEmailController.text.isNotEmpty ? _fromEmailController.text : null,
        fromName: _fromNameController.text.isNotEmpty ? _fromNameController.text : 'SecureGuard VPN',
      );

      await api.updateEmailSettings(settings);
      await _loadSettings();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email settings saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save settings: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _testEmail() async {
    final testEmail = _testEmailController.text.trim();
    if (testEmail.isEmpty || !testEmail.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid test email address')),
      );
      return;
    }

    setState(() => _isTesting = true);

    try {
      final api = ref.read(apiServiceProvider);
      final result = await api.testEmailSettings(testEmail);

      if (mounted) {
        if (result.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Test email sent successfully'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Test failed: ${result.error ?? result.message ?? "Unknown error"}'),
              backgroundColor: Colors.red,
            ),
          );
        }
        // Reload to get updated test status
        await _loadSettings();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Test failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }
  }
}

class _ApiKeysSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ApiKeysSection> createState() => _ApiKeysSectionState();
}

class _ApiKeysSectionState extends ConsumerState<_ApiKeysSection> {
  List<ApiKeyInfo> _apiKeys = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadApiKeys();
  }

  Future<void> _loadApiKeys() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final keys = await api.getApiKeys();
      if (mounted) {
        setState(() {
          _apiKeys = keys;
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

  String _formatCreated(DateTime created) {
    final diff = DateTime.now().difference(created);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
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
          Text('Failed to load API keys: $_error'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadApiKeys,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    return Column(
      children: [
        ..._apiKeys.map((key) => ListTile(
              leading: Icon(
                Icons.vpn_key,
                color: key.isValid ? AppTheme.primary : Colors.grey,
              ),
              title: Text(key.name),
              subtitle: Text('${key.keyPrefix} • ${key.permissions}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Created: ${_formatCreated(key.createdAt)}',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Revoke',
                    onPressed: key.isActive ? () => _confirmRevoke(key) : null,
                  ),
                ],
              ),
            )),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _showCreateKeyDialog,
          icon: const Icon(Icons.add),
          label: const Text('Create API Key'),
        ),
      ],
    );
  }

  Future<void> _confirmRevoke(ApiKeyInfo key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke API Key'),
        content: Text('Are you sure you want to revoke "${key.name}"? This cannot be undone.'),
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

    if (confirmed == true && mounted) {
      try {
        final api = ref.read(apiServiceProvider);
        await api.revokeApiKey(key.id);
        await _loadApiKeys();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('API key revoked')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to revoke API key: $e')),
          );
        }
      }
    }
  }

  void _showCreateKeyDialog() {
    final nameController = TextEditingController();
    String permissions = 'read';
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Create API Key'),
          content: SizedBox(
            width: 400,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g., CI/CD Pipeline',
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Name is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Permissions'),
                    value: permissions,
                    items: const [
                      DropdownMenuItem(value: 'read', child: Text('Read Only')),
                      DropdownMenuItem(value: 'write', child: Text('Read/Write')),
                      DropdownMenuItem(value: 'admin', child: Text('Full Access')),
                    ],
                    onChanged: (value) => setDialogState(() => permissions = value!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;

                Navigator.of(dialogContext).pop();

                try {
                  final api = ref.read(apiServiceProvider);
                  final result = await api.createApiKey(
                    name: nameController.text,
                    permissions: permissions,
                  );

                  // Show the generated key
                  if (mounted) {
                    _showKeyCreatedDialog(result.key);
                  }
                  await _loadApiKeys();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to create API key: $e')),
                    );
                  }
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  void _showKeyCreatedDialog(String key) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
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
                  Expanded(
                    child: SelectableText(
                      key,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: key));
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
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
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
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
