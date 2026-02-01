import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'animated_shield_logo.dart';

/// Beautiful animated welcome hero for first-time users
class WelcomeHero extends StatefulWidget {
  final VoidCallback onEnroll;

  const WelcomeHero({super.key, required this.onEnroll});

  @override
  State<WelcomeHero> createState() => _WelcomeHeroState();
}

class _WelcomeHeroState extends State<WelcomeHero>
    with TickerProviderStateMixin {
  late AnimationController _floatController;
  late AnimationController _particleController;
  late AnimationController _shimmerController;

  late Animation<double> _floatAnimation;
  late Animation<double> _shimmerAnimation;

  final List<_Particle> _particles = [];
  final _random = math.Random();

  @override
  void initState() {
    super.initState();

    // Float animation for subtle up/down movement
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);

    _floatAnimation = Tween<double>(begin: -8, end: 8).animate(
      CurvedAnimation(parent: _floatController, curve: Curves.easeInOut),
    );

    // Particle animation
    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
    )..repeat();

    _particleController.addListener(_updateParticles);

    // Shimmer animation for the button
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();

    _shimmerAnimation = Tween<double>(begin: -1, end: 2).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    // Initialize particles
    _initParticles();
  }

  void _initParticles() {
    for (var i = 0; i < 20; i++) {
      _particles.add(_Particle(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        size: _random.nextDouble() * 3 + 1,
        speed: _random.nextDouble() * 0.002 + 0.001,
        opacity: _random.nextDouble() * 0.5 + 0.1,
      ));
    }
  }

  void _updateParticles() {
    if (!mounted) return;
    setState(() {
      for (var particle in _particles) {
        particle.y -= particle.speed;
        if (particle.y < -0.1) {
          particle.y = 1.1;
          particle.x = _random.nextDouble();
        }
      }
    });
  }

  @override
  void dispose() {
    _floatController.dispose();
    _particleController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = const Color(0xFF3B82F6);

    return Stack(
      children: [
        // Animated particles background
        Positioned.fill(
          child: CustomPaint(
            painter: _ParticlePainter(
              particles: _particles,
              color: primaryColor.withValues(alpha: 0.3),
            ),
          ),
        ),

        // Main content
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 40),

            // Animated shield with float effect
            AnimatedBuilder(
              animation: _floatAnimation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _floatAnimation.value),
                  child: _buildShieldWithGlow(primaryColor, isDark),
                );
              },
            ),

            const SizedBox(height: 32),

            // Welcome text with fade-in effect
            Text(
              'Welcome to MinnowVPN',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
                letterSpacing: -0.5,
              ),
            ),

            const SizedBox(height: 12),

            // Subtitle
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Secure your connection with enterprise-grade VPN protection',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white60 : Colors.black54,
                  height: 1.5,
                ),
              ),
            ),

            const SizedBox(height: 48),

            // Feature highlights
            _buildFeatures(isDark),

            const Spacer(),

            // Animated CTA button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildEnrollButton(primaryColor, isDark),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ],
    );
  }

  Widget _buildShieldWithGlow(Color primaryColor, bool isDark) {
    // Use AnimatedShieldLogo with floating animation wrapper
    return AnimatedShieldLogo(
      color: primaryColor,
      size: 140,
    );
  }

  Widget _buildFeatures(bool isDark) {
    final features = [
      (Icons.lock_outline, 'End-to-end encryption'),
      (Icons.speed, 'Fast & reliable'),
      (Icons.devices, 'Multi-device support'),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: features.map((feature) {
          return _FeatureItem(
            icon: feature.$1,
            label: feature.$2,
            isDark: isDark,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEnrollButton(Color primaryColor, bool isDark) {
    return AnimatedBuilder(
      animation: _shimmerAnimation,
      builder: (context, child) {
        return Container(
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: [
                primaryColor,
                const Color(0xFF8B5CF6), // Purple accent
                primaryColor,
              ],
              stops: const [0.0, 0.5, 1.0],
              begin: Alignment(-1.0 + _shimmerAnimation.value, 0),
              end: Alignment(1.0 + _shimmerAnimation.value, 0),
            ),
            boxShadow: [
              BoxShadow(
                color: primaryColor.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onEnroll,
              borderRadius: BorderRadius.circular(16),
              child: const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.rocket_launch,
                      color: Colors.white,
                      size: 22,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Get Started',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDark;

  const _FeatureItem({
    required this.icon,
    required this.label,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF3B82F6).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: const Color(0xFF3B82F6),
            size: 22,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 80,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white54 : Colors.black54,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// Particle for background animation
class _Particle {
  double x;
  double y;
  final double size;
  final double speed;
  final double opacity;

  _Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.opacity,
  });
}

/// Custom painter for floating particles
class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final Color color;

  _ParticlePainter({required this.particles, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    for (var particle in particles) {
      final paint = Paint()
        ..color = color.withValues(alpha: particle.opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(
        Offset(particle.x * size.width, particle.y * size.height),
        particle.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}
