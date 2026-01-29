import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure credential storage service
///
/// Provides platform-specific secure storage:
/// - macOS: Keychain
/// - Windows: Windows Credential Store (WinCrypt)
/// - Linux: libsecret (GNOME Keyring/KWallet)
class CredentialStorage {
  static const _keyPrefix = 'secureguard_';

  // Key names
  static const _deviceTokenKey = '${_keyPrefix}device_token';
  static const _accessTokenKey = '${_keyPrefix}access_token';
  static const _refreshTokenKey = '${_keyPrefix}refresh_token';
  static const _ssoProviderKey = '${_keyPrefix}sso_provider';
  static const _vpnConfigKey = '${_keyPrefix}vpn_config';
  static const _configVersionKey = '${_keyPrefix}config_version';

  final FlutterSecureStorage _storage;

  static final CredentialStorage _instance = CredentialStorage._();
  static CredentialStorage get instance => _instance;

  CredentialStorage._()
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
          ),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
          mOptions: MacOsOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
            // Use the app's keychain group
            groupId: 'com.secureguard.vpn',
          ),
          lOptions: LinuxOptions(
            // Use a specific collection name for better organization
          ),
          wOptions: WindowsOptions(
            // Use DPAPI for encryption on Windows
          ),
        );

  // ═══════════════════════════════════════════════════════════════════
  // DEVICE CREDENTIALS
  // ═══════════════════════════════════════════════════════════════════

  /// Get stored device token
  Future<String?> getDeviceToken() async {
    return _storage.read(key: _deviceTokenKey);
  }

  /// Store device token securely
  Future<void> setDeviceToken(String token) async {
    await _storage.write(key: _deviceTokenKey, value: token);
  }

  /// Check if device is enrolled (has device token)
  Future<bool> isDeviceEnrolled() async {
    final token = await getDeviceToken();
    return token != null && token.isNotEmpty;
  }

  // ═══════════════════════════════════════════════════════════════════
  // SSO / AUTH TOKENS
  // ═══════════════════════════════════════════════════════════════════

  /// Get all stored auth tokens
  Future<AuthTokens?> getAuthTokens() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    final provider = await _storage.read(key: _ssoProviderKey);

    if (accessToken == null) return null;

    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      provider: provider,
    );
  }

  /// Store auth tokens securely
  Future<void> setAuthTokens(AuthTokens tokens) async {
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: tokens.accessToken),
      if (tokens.refreshToken != null)
        _storage.write(key: _refreshTokenKey, value: tokens.refreshToken),
      if (tokens.provider != null)
        _storage.write(key: _ssoProviderKey, value: tokens.provider),
    ]);
  }

  /// Clear auth tokens (on logout)
  Future<void> clearAuthTokens() async {
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _ssoProviderKey),
    ]);
  }

  /// Check if user has valid auth tokens
  Future<bool> hasAuthTokens() async {
    final token = await _storage.read(key: _accessTokenKey);
    return token != null && token.isNotEmpty;
  }

  // ═══════════════════════════════════════════════════════════════════
  // VPN CONFIGURATION
  // ═══════════════════════════════════════════════════════════════════

  /// Get stored VPN config
  Future<StoredVpnConfig?> getVpnConfig() async {
    final config = await _storage.read(key: _vpnConfigKey);
    final version = await _storage.read(key: _configVersionKey);

    if (config == null) return null;

    return StoredVpnConfig(
      config: config,
      version: version ?? '',
    );
  }

  /// Store VPN config securely
  Future<void> setVpnConfig(String config, String version) async {
    await Future.wait([
      _storage.write(key: _vpnConfigKey, value: config),
      _storage.write(key: _configVersionKey, value: version),
    ]);
  }

  /// Get config version for update checking
  Future<String?> getConfigVersion() async {
    return _storage.read(key: _configVersionKey);
  }

  /// Clear VPN config
  Future<void> clearVpnConfig() async {
    await Future.wait([
      _storage.delete(key: _vpnConfigKey),
      _storage.delete(key: _configVersionKey),
    ]);
  }

  // ═══════════════════════════════════════════════════════════════════
  // CUSTOM KEY-VALUE STORAGE
  // ═══════════════════════════════════════════════════════════════════

  /// Store a custom value securely
  Future<void> setSecure(String key, String value) async {
    await _storage.write(key: '$_keyPrefix$key', value: value);
  }

  /// Get a custom secure value
  Future<String?> getSecure(String key) async {
    return _storage.read(key: '$_keyPrefix$key');
  }

  /// Delete a custom secure value
  Future<void> deleteSecure(String key) async {
    await _storage.delete(key: '$_keyPrefix$key');
  }

  /// Store JSON data securely
  Future<void> setSecureJson(String key, Map<String, dynamic> data) async {
    await setSecure(key, jsonEncode(data));
  }

  /// Get JSON data from secure storage
  Future<Map<String, dynamic>?> getSecureJson(String key) async {
    final value = await getSecure(key);
    if (value == null) return null;
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // CLEANUP
  // ═══════════════════════════════════════════════════════════════════

  /// Clear all stored credentials (complete logout/reset)
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  /// Check if storage is accessible
  Future<bool> isAccessible() async {
    try {
      // Try a simple read/write operation
      const testKey = '${_keyPrefix}_test';
      await _storage.write(key: testKey, value: 'test');
      await _storage.delete(key: testKey);
      return true;
    } catch (e) {
      return false;
    }
  }
}

/// Container for auth tokens
class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  final String? provider;

  AuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.provider,
  });

  /// Check if refresh token is available
  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  /// Create from JSON map
  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      provider: json['provider'] as String?,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'provider': provider,
      };
}

/// Container for stored VPN config
class StoredVpnConfig {
  final String config;
  final String version;

  StoredVpnConfig({
    required this.config,
    required this.version,
  });
}
