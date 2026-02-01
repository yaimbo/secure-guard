import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/home_screen.dart';
import 'screens/enrollment_screen.dart';
import 'services/api_client.dart';
import 'services/tray_service.dart';
import 'services/update_service.dart';
import 'widgets/uninstall_dialog.dart';

/// Global navigator key for navigation from anywhere
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Enrollment data from deep link
class EnrollmentData {
  final String serverUrl;
  final String code;

  EnrollmentData({required this.serverUrl, required this.code});
}

/// Parse a secureguard:// deep link URL
EnrollmentData? parseEnrollmentDeepLink(Uri uri) {
  if (uri.scheme != 'secureguard' || uri.host != 'enroll') {
    return null;
  }

  final server = uri.queryParameters['server'];
  final code = uri.queryParameters['code'];

  if (server == null || code == null) {
    return null;
  }

  return EnrollmentData(serverUrl: server, code: code);
}

/// App links handler for deep link support
late AppLinks _appLinks;
StreamSubscription<Uri>? _linkSubscription;

/// Handle uninstall request from tray menu
Future<void> _handleUninstallRequest() async {
  // Show the window first so user can see the dialog
  await windowManager.show();
  await windowManager.focus();

  // Show uninstall dialog using the navigator key
  final context = navigatorKey.currentContext;
  if (context == null) return;

  final success = await showUninstallDialog(context);
  if (success) {
    // Uninstall succeeded, exit the app
    _linkSubscription?.cancel();
    UpdateService.instance.dispose();
    await TrayService.instance.dispose();
    exit(0);
  }
}

/// Handle incoming deep link
void _handleDeepLink(Uri uri) {
  debugPrint('Received deep link: $uri');

  final enrollmentData = parseEnrollmentDeepLink(uri);
  if (enrollmentData != null) {
    // Navigate to enrollment screen with pre-filled data
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => EnrollmentScreen(
          initialServerUrl: enrollmentData.serverUrl,
          initialCode: enrollmentData.code,
        ),
      ),
    );

    // Bring window to front when handling deep link
    windowManager.show();
    windowManager.focus();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize window manager for desktop
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(400, 780),
    minimumSize: Size(350, 650),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'SecureGuard VPN',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    // Intercept close to minimize to tray instead of quitting
    await windowManager.setPreventClose(true);
  });

  // Initialize deep link handling
  _appLinks = AppLinks();

  // Handle initial link (app launched from deep link)
  final initialUri = await _appLinks.getInitialLink();
  EnrollmentData? initialEnrollment;
  if (initialUri != null) {
    initialEnrollment = parseEnrollmentDeepLink(initialUri);
  }

  // Listen for subsequent deep links while app is running
  _linkSubscription = _appLinks.uriLinkStream.listen(_handleDeepLink);

  // Initialize API client
  await ApiClient.instance.init();

  // Initialize update service (starts periodic checks)
  await UpdateService.instance.init();

  // Initialize system tray
  await TrayService.instance.init();

  // Handle uninstall from tray
  TrayService.instance.onUninstallRequested = () {
    _handleUninstallRequest();
  };

  // Handle quit from tray
  TrayService.instance.onQuitRequested = () async {
    _linkSubscription?.cancel();
    UpdateService.instance.dispose();
    await TrayService.instance.dispose();
    exit(0);
  };

  runApp(ProviderScope(
    child: SecureGuardApp(initialEnrollment: initialEnrollment),
  ));
}

class SecureGuardApp extends StatefulWidget {
  final EnrollmentData? initialEnrollment;

  const SecureGuardApp({super.key, this.initialEnrollment});

  @override
  State<SecureGuardApp> createState() => _SecureGuardAppState();
}

class _SecureGuardAppState extends State<SecureGuardApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Hide to tray instead of quitting
    await windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'SecureGuard VPN',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: widget.initialEnrollment != null
          ? EnrollmentScreen(
              initialServerUrl: widget.initialEnrollment!.serverUrl,
              initialCode: widget.initialEnrollment!.code,
            )
          : const HomeScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B82F6), // Blue
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black87,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? Colors.white10 : Colors.black12,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
