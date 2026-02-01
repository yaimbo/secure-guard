import 'package:flutter/material.dart';

import 'animated_shield_logo.dart';

/// Animated disconnected state hero widget with blue animated shield
class DisconnectedHero extends StatelessWidget {
  const DisconnectedHero({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const blueColor = Color(0xFF3B82F6);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const AnimatedShieldLogo(
          color: blueColor,
          size: 200,
        ),
        const SizedBox(height: 24),
        const Text(
          'Not Protected',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: blueColor,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Your connection is not secure',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
        ),
      ],
    );
  }
}
