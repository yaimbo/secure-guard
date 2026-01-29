import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/setup_screen.dart';
import '../screens/login_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/clients_screen.dart';
import '../screens/client_detail_screen.dart';
import '../screens/logs_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/app_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final isLoggedIn = authState.isAuthenticated;
      final needsSetup = authState.needsSetup;
      final isLoading = authState.isLoading;
      final currentPath = state.matchedLocation;

      // Don't redirect while loading
      if (isLoading) {
        return null;
      }

      // If setup is needed, redirect to setup page
      if (needsSetup && currentPath != '/setup') {
        return '/setup';
      }

      // If setup is complete but on setup page, go to login
      if (!needsSetup && currentPath == '/setup') {
        return '/login';
      }

      // If not logged in and not on login/setup, go to login
      if (!isLoggedIn && currentPath != '/login' && currentPath != '/setup') {
        return '/login';
      }

      // If logged in and on login page, go to dashboard
      if (isLoggedIn && currentPath == '/login') {
        return '/dashboard';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/setup',
        builder: (context, state) => const SetupScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/clients',
            builder: (context, state) => const ClientsScreen(),
          ),
          GoRoute(
            path: '/clients/:id',
            builder: (context, state) {
              final id = state.pathParameters['id']!;
              return ClientDetailScreen(clientId: id);
            },
          ),
          GoRoute(
            path: '/logs',
            builder: (context, state) => const LogsScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),
    ],
  );
});
