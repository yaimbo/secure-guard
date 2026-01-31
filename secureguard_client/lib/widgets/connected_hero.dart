import 'package:flutter/material.dart';

import 'animated_shield_logo.dart';

/// Animated connected state hero widget with green animated shield
class ConnectedHero extends StatelessWidget {
  const ConnectedHero({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const greenColor = Color(0xFF22C55E);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const AnimatedShieldLogo(
          color: greenColor,
          size: 200,
        ),
        const SizedBox(height: 24),
        const Text(
          'Protected',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: greenColor,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Your connection is secure',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
        ),
      ],
    );
  }
}
