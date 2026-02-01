import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated shield logo used throughout the app as consistent branding.
///
/// Features:
/// - Rotating dashed outer circle
/// - Pulsing expanding rings
/// - Inner static ring
/// - Pulsing shield icon with gradient
///
/// Color scheme:
/// - Green (#22C55E) - Connected state
/// - Blue (#3B82F6) - Disconnected, welcome, etc.
/// - Amber (#F59E0B) - Connecting/disconnecting
/// - Red (#EF4444) - Error state
class AnimatedShieldLogo extends StatefulWidget {
  final Color color;
  final double size;
  final bool showPulsingRings;
  final bool showRotatingRing;

  const AnimatedShieldLogo({
    super.key,
    required this.color,
    this.size = 200,
    this.showPulsingRings = true,
    this.showRotatingRing = true,
  });

  @override
  State<AnimatedShieldLogo> createState() => _AnimatedShieldLogoState();
}

class _AnimatedShieldLogoState extends State<AnimatedShieldLogo>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();

    // Slow pulse for the shield
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    // Rotating dashed circle
    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    // Wave animation for rings
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotateController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtleColor = widget.color.withValues(alpha: 0.3);

    // Calculate sizes based on the overall size
    final outerRingSize = widget.size * 0.9;
    final pulsingRingsSize = widget.size * 0.8;
    final innerRingSize = widget.size * 0.6;
    final shieldSize = widget.size * 0.35;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer rotating dashed ring
          if (widget.showRotatingRing)
            AnimatedBuilder(
              animation: _rotateController,
              builder: (context, child) {
                return Transform.rotate(
                  angle: _rotateController.value * 2 * math.pi,
                  child: CustomPaint(
                    size: Size(outerRingSize, outerRingSize),
                    painter: _DashedCirclePainter(
                      color: subtleColor,
                      dashWidth: 8,
                      gapWidth: 12,
                      strokeWidth: 2,
                    ),
                  ),
                );
              },
            ),

          // Pulsing rings
          if (widget.showPulsingRings)
            AnimatedBuilder(
              animation: _waveController,
              builder: (context, child) {
                return CustomPaint(
                  size: Size(pulsingRingsSize, pulsingRingsSize),
                  painter: _PulsingRingsPainter(
                    color: widget.color,
                    progress: _waveController.value,
                  ),
                );
              },
            ),

          // Inner static ring
          Container(
            width: innerRingSize,
            height: innerRingSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: subtleColor,
                width: 1,
              ),
            ),
          ),

          // Shield icon with pulse
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final scale = 1.0 + (_pulseController.value * 0.05);
              final opacity = 0.6 + (_pulseController.value * 0.4);

              return Transform.scale(
                scale: scale,
                child: ShaderMask(
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        widget.color.withValues(alpha: opacity),
                        widget.color.withValues(alpha: opacity * 0.7),
                      ],
                    ).createShader(bounds);
                  },
                  child: Icon(
                    Icons.shield_outlined,
                    size: shieldSize,
                    color: Colors.white,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Paints a dashed circle
class _DashedCirclePainter extends CustomPainter {
  final Color color;
  final double dashWidth;
  final double gapWidth;
  final double strokeWidth;

  _DashedCirclePainter({
    required this.color,
    required this.dashWidth,
    required this.gapWidth,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final radius = size.width / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final circumference = 2 * math.pi * radius;
    final dashCount = (circumference / (dashWidth + gapWidth)).floor();
    final dashAngle = (dashWidth / circumference) * 2 * math.pi;
    final gapAngle = (gapWidth / circumference) * 2 * math.pi;

    for (int i = 0; i < dashCount; i++) {
      final startAngle = i * (dashAngle + gapAngle);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        dashAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) {
    return color != oldDelegate.color;
  }
}

/// Paints expanding/fading rings
class _PulsingRingsPainter extends CustomPainter {
  final Color color;
  final double progress;

  _PulsingRingsPainter({
    required this.color,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Draw 3 rings at different phases
    for (int i = 0; i < 3; i++) {
      final phase = (progress + (i / 3)) % 1.0;
      final radius = maxRadius * 0.4 + (maxRadius * 0.6 * phase);
      final opacity = (1.0 - phase) * 0.3;

      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PulsingRingsPainter oldDelegate) {
    return progress != oldDelegate.progress;
  }
}
