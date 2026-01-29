import 'dart:io';

import 'package:flutter/material.dart';

class ConfigDialog extends StatefulWidget {
  final String? initialConfig;
  final void Function(String config) onConnect;

  const ConfigDialog({
    super.key,
    this.initialConfig,
    required this.onConnect,
  });

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialConfig ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.settings, size: 24),
                const SizedBox(width: 12),
                const Text(
                  'VPN Configuration',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Paste your WireGuard configuration or load from file:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(
                  color: isDark ? Colors.white24 : Colors.black26,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  hintText: '[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\nPublicKey = ...',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _loadFromFile,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Load File'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _onConnect,
                  child: const Text('Connect'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _onConnect() {
    final config = _controller.text.trim();
    if (config.isEmpty) {
      setState(() => _error = 'Configuration cannot be empty');
      return;
    }

    if (!config.contains('[Interface]')) {
      setState(() => _error = 'Invalid WireGuard configuration');
      return;
    }

    Navigator.of(context).pop();
    widget.onConnect(config);
  }

  Future<void> _loadFromFile() async {
    // Simple file picker using stdin for now
    // In a real app, you'd use file_picker package
    try {
      // Try to read from common locations
      final homeDir = Platform.environment['HOME'] ?? '';
      final possiblePaths = [
        '$homeDir/.config/wireguard/',
        '$homeDir/wireguard/',
        '/etc/wireguard/',
      ];

      String? selectedPath;
      for (final path in possiblePaths) {
        final dir = Directory(path);
        if (await dir.exists()) {
          final files = await dir
              .list()
              .where((e) => e.path.endsWith('.conf'))
              .toList();
          if (files.isNotEmpty) {
            selectedPath = files.first.path;
            break;
          }
        }
      }

      if (selectedPath != null) {
        final content = await File(selectedPath).readAsString();
        _controller.text = content;
        setState(() => _error = null);
      } else {
        setState(() => _error = 'No .conf files found in common locations');
      }
    } catch (e) {
      setState(() => _error = 'Failed to load file: $e');
    }
  }
}
