import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/vpn_provider.dart';
import '../services/enrollment_service.dart';
import '../widgets/animated_shield_logo.dart';
import 'home_screen.dart';
import 'manual_config_screen.dart';

/// Screen for device enrollment via enrollment code
///
/// Supports two modes:
/// 1. Deep link: Server URL and code pre-filled from secureguard:// URL
/// 2. Manual: User enters server domain and enrollment code
class EnrollmentScreen extends ConsumerStatefulWidget {
  final String? initialServerUrl;
  final String? initialCode;

  const EnrollmentScreen({
    super.key,
    this.initialServerUrl,
    this.initialCode,
  });

  @override
  ConsumerState<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends ConsumerState<EnrollmentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _codeController = TextEditingController();

  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();

    // Pre-fill from deep link if provided
    if (widget.initialServerUrl != null) {
      // Extract domain from full URL
      var url = widget.initialServerUrl!;
      url = url.replaceAll(RegExp(r'^https?://'), '');
      url = url.replaceAll(RegExp(r'/.*$'), '');
      _serverController.text = url;
    }

    if (widget.initialCode != null) {
      _codeController.text = widget.initialCode!;
    }

    // Auto-enroll if both fields are pre-filled from deep link
    if (widget.initialServerUrl != null && widget.initialCode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _enroll();
      });
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _enroll() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final enrollmentService = EnrollmentService.instance;
      final result = await enrollmentService.redeemEnrollmentCode(
        serverUrl: _serverController.text.trim(),
        code: _codeController.text.trim(),
      );

      if (!mounted) return;

      // Enrollment successful - connect to VPN
      final vpnNotifier = ref.read(vpnProvider.notifier);
      await vpnNotifier.connect(result.config);

      if (!mounted) return;

      // Navigate to home screen
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } on EnrollmentException catch (e) {
      setState(() {
        _error = e.message;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Enrollment failed: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
      body: Column(
        children: [
          // Custom title bar
          _buildTitleBar(context, isDark),

          // Main content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
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
                      'Enroll Your Device',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enter your server domain and enrollment code provided by your administrator.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),

                    // Server domain field
                    TextFormField(
                      controller: _serverController,
                      decoration: InputDecoration(
                        labelText: 'Server Domain',
                        hintText: 'vpn.company.com',
                        prefixIcon: const Icon(Icons.dns),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enabled: !_isLoading,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter the server domain';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Enrollment code field
                    TextFormField(
                      controller: _codeController,
                      decoration: InputDecoration(
                        labelText: 'Enrollment Code',
                        hintText: 'ABCD-1234',
                        prefixIcon: const Icon(Icons.confirmation_number),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      ),
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.characters,
                      autocorrect: false,
                      enabled: !_isLoading,
                      inputFormatters: [
                        _EnrollmentCodeFormatter(),
                        LengthLimitingTextInputFormatter(9), // XXXX-XXXX
                      ],
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter the enrollment code';
                        }
                        final normalized = value.replaceAll('-', '').replaceAll(' ', '');
                        if (normalized.length != 8) {
                          return 'Code should be 8 characters (XXXX-XXXX)';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _enroll(),
                    ),
                    const SizedBox(height: 24),

                    // Error message
                    if (_error != null) ...[
                      _buildErrorCard(_error!, theme),
                      const SizedBox(height: 16),
                    ],

                    // Enroll button
                    SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _enroll,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF3B82F6),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text(
                                'Enroll Device',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Skip / Manual config link
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ManualConfigScreen(),
                                ),
                              );
                            },
                      child: Text(
                        'Skip and configure manually',
                        style: TextStyle(
                          color: isDark ? Colors.white54 : Colors.black45,
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

  Widget _buildErrorCard(String error, ThemeData theme) {
    return Card(
      color: const Color(0xFFFEE2E2),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() => _error = null),
              color: const Color(0xFF991B1B),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Input formatter for enrollment codes (XXXX-XXXX format)
class _EnrollmentCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Remove all non-alphanumeric characters and uppercase
    var text = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

    // Limit to 8 characters
    if (text.length > 8) {
      text = text.substring(0, 8);
    }

    // Add hyphen after 4 characters
    if (text.length > 4) {
      text = '${text.substring(0, 4)}-${text.substring(4)}';
    }

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
