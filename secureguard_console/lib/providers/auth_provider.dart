import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api_service.dart';

// Auth state
class AuthState {
  final bool isAuthenticated;
  final bool needsSetup;
  final bool serverUnavailable;
  final String? userId;
  final String? email;
  final String? role;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.isAuthenticated = false,
    this.needsSetup = false,
    this.serverUnavailable = false,
    this.userId,
    this.email,
    this.role,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    bool? needsSetup,
    bool? serverUnavailable,
    String? userId,
    String? email,
    String? role,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      needsSetup: needsSetup ?? this.needsSetup,
      serverUnavailable: serverUnavailable ?? this.serverUnavailable,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      role: role ?? this.role,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

// Auth notifier
class AuthNotifier extends StateNotifier<AuthState> {
  final ApiService _api;
  final FlutterSecureStorage _storage;

  AuthNotifier(this._api)
      : _storage = const FlutterSecureStorage(),
        super(const AuthState()) {
    _init();
  }

  Future<void> _init() async {
    state = state.copyWith(isLoading: true);

    try {
      // First check if setup is needed
      final setupNeeded = await _api.checkNeedsSetup();
      if (setupNeeded) {
        state = state.copyWith(isLoading: false, needsSetup: true);
        return;
      }

      final accessToken = await _storage.read(key: 'access_token');
      final refreshToken = await _storage.read(key: 'refresh_token');

      if (accessToken != null) {
        _api.setAccessToken(accessToken);

        // Try to refresh the token to validate
        if (refreshToken != null) {
          try {
            final result = await _api.refreshToken(refreshToken);
            await _saveTokens(result);
            state = state.copyWith(
              isAuthenticated: true,
              needsSetup: false,
              userId: result['user']?['id'],
              email: result['user']?['email'],
              role: result['user']?['role'],
              isLoading: false,
            );
            return;
          } catch (e) {
            // Token refresh failed - clear and require login
            await _clearTokens();
          }
        }
      }
    } on ServerUnavailableException {
      state = state.copyWith(
        isLoading: false,
        serverUnavailable: true,
        error: 'Cannot connect to server. Please ensure the server is running.',
      );
      return;
    } catch (e) {
      // Storage access failed
    }

    state = state.copyWith(isLoading: false);
  }

  /// Retry connecting to the server
  Future<void> retry() async {
    state = state.copyWith(serverUnavailable: false, error: null);
    await _init();
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final result = await _api.login(email, password);
      await _saveTokens(result);

      state = state.copyWith(
        isAuthenticated: true,
        userId: result['user']['id'],
        email: result['user']['email'],
        role: result['user']['role'],
        isLoading: false,
      );
      return true;
    } catch (e) {
      String errorMsg = 'Login failed';
      if (e.toString().contains('401')) {
        errorMsg = 'Invalid email or password';
      } else if (e.toString().contains('network')) {
        errorMsg = 'Network error - check your connection';
      }

      state = state.copyWith(
        isLoading: false,
        error: errorMsg,
      );
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (e) {
      // Ignore logout errors
    }

    await _clearTokens();
    state = const AuthState();
  }

  Future<bool> setupAdmin(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _api.setupAdmin(email: email, password: password);
      state = state.copyWith(
        isLoading: false,
        needsSetup: false,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to create admin account: ${e.toString()}',
      );
      return false;
    }
  }

  Future<void> _saveTokens(Map<String, dynamic> result) async {
    final accessToken = result['access_token'] as String;
    final refreshToken = result['refresh_token'] as String;

    await _storage.write(key: 'access_token', value: accessToken);
    await _storage.write(key: 'refresh_token', value: refreshToken);

    _api.setAccessToken(accessToken);
  }

  Future<void> _clearTokens() async {
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
    _api.setAccessToken(null);
  }
}

// Providers
final authStateProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final api = ref.watch(apiServiceProvider);
  return AuthNotifier(api);
});
