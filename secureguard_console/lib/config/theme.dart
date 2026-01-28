import 'package:flutter/material.dart';

class AppTheme {
  // Color palette
  static const _primaryColor = Color(0xFF3B82F6); // Blue
  static const _connectedColor = Color(0xFF22C55E); // Green
  static const _disconnectedColor = Color(0xFF6B7280); // Gray
  static const _warningColor = Color(0xFFF59E0B); // Amber
  static const _errorColor = Color(0xFFEF4444); // Red

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
          secondary: _connectedColor,
          error: _errorColor,
          surface: _darkSurface,
          onSurface: Colors.white,
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
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: _darkSurface,
          selectedIconTheme: IconThemeData(color: _primaryColor),
          unselectedIconTheme: IconThemeData(color: Colors.white54),
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
          secondary: _connectedColor,
          error: _errorColor,
          surface: _lightSurface,
          onSurface: Color(0xFF1E293B),
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
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: _lightSurface,
          selectedIconTheme: IconThemeData(color: _primaryColor),
          unselectedIconTheme: IconThemeData(color: Colors.black54),
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
