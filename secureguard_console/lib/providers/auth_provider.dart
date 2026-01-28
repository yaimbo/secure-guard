import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api_service.dart';

// Auth state
class AuthState {
  final bool isAuthenticated;
  final String? userId;
  final String? email;
  final String? role;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.isAuthenticated = false,
    this.userId,
    this.email,
    this.role,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? userId,
    String? email,
    String? role,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
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
    } catch (e) {
      // Storage access failed
    }

    state = state.copyWith(isLoading: false);
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
