import 'dart:io';

import 'package:flutter/material.dart';

import '../services/uninstall_service.dart';

/// Shows a confirmation dialog for uninstalling SecureGuard
/// Returns true if uninstall was successful, false otherwise
Future<bool> showUninstallDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const _UninstallDialog(),
  );
  return result ?? false;
}

class _UninstallDialog extends StatefulWidget {
  const _UninstallDialog();

  @override
  State<_UninstallDialog> createState() => _UninstallDialogState();
}

class _UninstallDialogState extends State<_UninstallDialog> {
  bool _isUninstalling = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange.shade700,
            size: 28,
          ),
          const SizedBox(width: 12),
          const Text('Uninstall SecureGuard'),
        ],
      ),
      content: _isUninstalling
          ? _buildProgressContent()
          : _buildConfirmationContent(),
      actions: _isUninstalling ? null : _buildActions(context),
    );
  }

  Widget _buildConfirmationContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'This will completely remove SecureGuard from your computer, including:',
        ),
        const SizedBox(height: 16),
        _buildRemovalItem(Icons.shield, 'VPN service and daemon'),
        const SizedBox(height: 8),
        _buildRemovalItem(Icons.apps, 'SecureGuard application'),
        const SizedBox(height: 8),
        _buildRemovalItem(Icons.storage, 'Configuration and connection data'),
        const SizedBox(height: 8),
        _buildRemovalItem(Icons.description, 'Log files'),
        const SizedBox(height: 16),
        Text(
          _getPlatformNote(),
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
            fontStyle: FontStyle.italic,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Colors.red.shade900,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRemovalItem(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 14)),
      ],
    );
  }

  String _getPlatformNote() {
    if (Platform.isMacOS) {
      return 'You will be prompted for your administrator password.';
    } else if (Platform.isWindows) {
      return 'You will be prompted by User Account Control (UAC).';
    } else if (Platform.isLinux) {
      return 'You will be prompted for your password.';
    }
    return '';
  }

  Widget _buildProgressContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        const Text(
          'Uninstalling SecureGuard...',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          'Please complete the authentication prompt if shown.',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      ElevatedButton(
        onPressed: _performUninstall,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red.shade600,
          foregroundColor: Colors.white,
        ),
        child: const Text('Uninstall'),
      ),
    ];
  }

  Future<void> _performUninstall() async {
    setState(() {
      _isUninstalling = true;
      _error = null;
    });

    final result = await UninstallService.uninstall();

    if (!mounted) return;

    if (result.success) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _isUninstalling = false;
        _error = result.error ?? 'Uninstall failed';
      });
    }
  }
}
