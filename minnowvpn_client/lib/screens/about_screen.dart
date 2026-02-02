import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../version.dart';
import '../widgets/animated_shield_logo.dart';

/// About screen displaying version information
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5),
      body: Column(
        children: [
          // Custom title bar with back button
          _buildTitleBar(context, isDark),

          // Main content
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // App icon (shield logo)
                    const AnimatedShieldLogo(
                      color: Color(0xFF3B82F6),
                      size: 80,
                      showPulsingRings: false,
                      showRotatingRing: false,
                    ),
                    const SizedBox(height: 16),

                    // App name
                    Text(
                      'MinnowVPN',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Version info
                    Text(
                      'Version ${AppVersion.version}',
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                    Text(
                      'Build ${AppVersion.buildNumber}',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.grey[500] : Colors.grey[600],
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Build info card
                    Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Card(
                        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              _buildInfoRow(
                                'Git Commit',
                                AppVersion.gitCommit,
                                isDark,
                              ),
                              Divider(
                                color: isDark ? Colors.white12 : Colors.black12,
                              ),
                              _buildInfoRow(
                                'Build Date',
                                _formatBuildDate(AppVersion.buildDate),
                                isDark,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Copyright
                    Text(
                      '© 2024-${DateTime.now().year} MinnowVPN',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.grey[600] : Colors.grey[500],
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
        child: Row(
          children: [
            // Back button
            IconButton(
              icon: Icon(
                Icons.arrow_back,
                size: 20,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
              onPressed: () => Navigator.pop(context),
              tooltip: 'Back',
            ),
            const Spacer(),
            Text(
              'About',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const Spacer(),
            // Spacer for visual balance (matches back button width)
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDark ? Colors.grey[400] : Colors.grey[600],
            ),
          ),
          SelectableText(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  String _formatBuildDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDate;
    }
  }
}
