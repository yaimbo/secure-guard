import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/vpn_provider.dart';
import '../widgets/animated_shield_logo.dart';
import 'home_screen.dart';

/// Screen for manually entering or loading WireGuard configuration
class ManualConfigScreen extends ConsumerStatefulWidget {
  final String? initialConfig;

  const ManualConfigScreen({super.key, this.initialConfig});

  @override
  ConsumerState<ManualConfigScreen> createState() => _ManualConfigScreenState();
}

class _ManualConfigScreenState extends ConsumerState<ManualConfigScreen> {
  late final TextEditingController _controller;
  String? _error;
  bool _isSaving = false;

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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
      body: Column(
        children: [
          // Title bar
          _buildTitleBar(context, isDark),

          // Main content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header with animated shield
                  const AnimatedShieldLogo(
                    color: Color(0xFF3B82F6),
                    size: 100,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Manual Configuration',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Paste your WireGuard configuration or load from a file.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),

                  // Config text area
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      border: Border.all(
                        color: _error != null
                            ? const Color(0xFFEF4444)
                            : (isDark ? Colors.white24 : Colors.black26),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      decoration: InputDecoration(
                        hintText:
                            '[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\nPublicKey = ...\nEndpoint = ...\nAllowedIPs = ...',
                        hintStyle: TextStyle(
                          color: isDark ? Colors.white24 : Colors.black26,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(16),
                      ),
                      onChanged: (_) {
                        if (_error != null) {
                          setState(() => _error = null);
                        }
                      },
                    ),
                  ),

                  // Error message
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 14,
                          color: Color(0xFFEF4444),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Color(0xFFEF4444),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Load from file button
                  OutlinedButton.icon(
                    onPressed: _isSaving ? null : _loadFromFile,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Load from file'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _isSaving ? null : _saveConfig,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF3B82F6),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isSaving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor:
                                        AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                )
                              : const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context, bool isDark) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 48,
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        child: Center(
          child: Text(
            'SecureGuard VPN',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['conf'],
        dialogTitle: 'Select WireGuard Configuration',
      );

      if (result != null && result.files.single.path != null) {
        final content = await File(result.files.single.path!).readAsString();
        _controller.text = content;
        setState(() => _error = null);
      }
    } catch (e) {
      setState(() => _error = 'Failed to load file: $e');
    }
  }

  Future<void> _saveConfig() async {
    final config = _controller.text.trim();

    // Validation
    if (config.isEmpty) {
      setState(() => _error = 'Configuration cannot be empty');
      return;
    }

    if (!config.contains('[Interface]')) {
      setState(() => _error = 'Missing [Interface] section');
      return;
    }

    if (!config.toLowerCase().contains('privatekey')) {
      setState(() => _error = 'Missing PrivateKey in configuration');
      return;
    }

    if (!config.contains('[Peer]')) {
      setState(() => _error = 'Missing [Peer] section');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    // Save config to provider (persists to SharedPreferences)
    await ref.read(vpnProvider.notifier).saveConfig(config);

    if (!mounted) return;

    // Navigate to home screen (clear stack)
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }
}
