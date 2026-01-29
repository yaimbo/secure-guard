import 'package:flutter/material.dart';

class AppTheme {
  // Color palette - Professional business colors
  static const _primaryColor = Color(0xFF2563EB); // Blue 600 - slightly deeper
  static const _secondaryColor = Color(0xFF475569); // Slate 600 - neutral
  static const _connectedColor = Color(0xFF16A34A); // Green 600 - status only
  static const _disconnectedColor = Color(0xFF6B7280); // Gray 500
  static const _warningColor = Color(0xFFD97706); // Amber 600
  static const _errorColor = Color(0xFFDC2626); // Red 600

  // Dark theme background colors
  static const _darkBg = Color(0xFF0F172A); // Slate 900
  static const _darkSurface = Color(0xFF1E293B); // Slate 800
  static const _darkCard = Color(0xFF334155); // Slate 700

  // Light theme background colors
  static const _lightBg = Color(0xFFF8FAFC); // Slate 50
  static const _lightSurface = Color(0xFFFFFFFF); // White
  static const _lightCard = Color(0xFFF1F5F9); // Slate 100

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: _primaryColor,
          secondary: _secondaryColor,
          tertiary: _primaryColor,
          error: _errorColor,
          surface: _darkSurface,
          onSurface: Colors.white,
          secondaryContainer: Color(0xFF1E3A5F), // Subtle blue for selections
          onSecondaryContainer: Colors.white,
        ),
        scaffoldBackgroundColor: _darkBg,
        cardTheme: CardThemeData(
          color: _darkCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _darkSurface,
          elevation: 0,
          centerTitle: false,
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: _darkSurface,
          selectedIconTheme: const IconThemeData(color: Colors.white),
          unselectedIconTheme: const IconThemeData(color: Colors.white54),
          selectedLabelTextStyle: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
          unselectedLabelTextStyle: const TextStyle(
            color: Colors.white54,
          ),
          indicatorColor: _primaryColor.withValues(alpha: 0.2),
        ),
        dataTableTheme: DataTableThemeData(
          headingRowColor: WidgetStateProperty.all(_darkCard),
          dataRowColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) {
              return _darkCard.withOpacity(0.5);
            }
            return Colors.transparent;
          }),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _darkCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _primaryColor),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: _primaryColor,
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: _darkCard,
          thickness: 1,
        ),
      );

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: const ColorScheme.light(
          primary: _primaryColor,
          secondary: _secondaryColor,
          tertiary: _primaryColor,
          error: _errorColor,
          surface: _lightSurface,
          onSurface: Color(0xFF1E293B),
          secondaryContainer: Color(0xFFDBEAFE), // Light blue for selections
          onSecondaryContainer: Color(0xFF1E3A8A),
        ),
        scaffoldBackgroundColor: _lightBg,
        cardTheme: CardThemeData(
          color: _lightCard,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _lightSurface,
          elevation: 0,
          centerTitle: false,
          foregroundColor: Color(0xFF1E293B),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: _lightSurface,
          selectedIconTheme: const IconThemeData(color: _primaryColor),
          unselectedIconTheme: const IconThemeData(color: Colors.black54),
          selectedLabelTextStyle: const TextStyle(
            color: _primaryColor,
            fontWeight: FontWeight.w500,
          ),
          unselectedLabelTextStyle: const TextStyle(
            color: Colors.black54,
          ),
          indicatorColor: _primaryColor.withValues(alpha: 0.12),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _lightCard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _primaryColor),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _primaryColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      );

  // Semantic colors for use throughout the app
  static const connected = _connectedColor;
  static const disconnected = _disconnectedColor;
  static const warning = _warningColor;
  static const error = _errorColor;
  static const primary = _primaryColor;
}
