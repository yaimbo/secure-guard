import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'credential_storage.dart';

/// Device enrollment and SSO authentication service
///
/// Handles:
/// - SSO provider discovery
/// - Device code flow authentication
/// - Device registration
/// - VPN config fetching and updates
/// - Token refresh
class EnrollmentService {
  final ApiClient _api;
  final CredentialStorage _credentials;

  // Polling state for device code flow
  Timer? _pollTimer;
  String? _pendingDeviceCode;
  int _pollInterval = 5;
  DateTime? _deviceCodeExpiry;

  static final EnrollmentService _instance = EnrollmentService._();
  static EnrollmentService get instance => _instance;

  EnrollmentService._()
      : _api = ApiClient.instance,
        _credentials = CredentialStorage.instance;

  // ═══════════════════════════════════════════════════════════════════
  // SSO PROVIDER DISCOVERY
  // ═══════════════════════════════════════════════════════════════════

  /// Get available SSO providers from server
  Future<List<SSOProviderInfo>> getAvailableProviders() async {
    final response = await _api.get('/api/v1/auth/sso/providers');

    if (!response.isSuccess) {
      throw EnrollmentException('Failed to get SSO providers: ${response.error}');
    }

    final data = response.data as Map<String, dynamic>;
    final providers = data['providers'] as List<dynamic>;

    return providers
        .map((p) => SSOProviderInfo.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  // ═══════════════════════════════════════════════════════════════════
  // DEVICE CODE FLOW (for Desktop Apps)
  // ═══════════════════════════════════════════════════════════════════

  /// Start device code flow for SSO authentication
  ///
  /// Returns device authorization info that should be shown to the user.
  /// The user needs to visit the verification URL and enter the code.
  Future<DeviceAuthInfo> startDeviceCodeFlow(String providerId) async {
    final response = await _api.post('/api/v1/auth/sso/$providerId/device');

    if (!response.isSuccess) {
      throw EnrollmentException('Failed to start device auth: ${response.error}');
    }

    final data = response.data as Map<String, dynamic>;

    _pendingDeviceCode = data['device_code'] as String;
    _pollInterval = data['interval'] as int? ?? 5;
    _deviceCodeExpiry = DateTime.now().add(
      Duration(seconds: data['expires_in'] as int? ?? 900),
    );

    return DeviceAuthInfo(
      deviceCode: _pendingDeviceCode!,
      userCode: data['user_code'] as String,
      verificationUri: data['verification_uri'] as String,
      verificationUriComplete: data['verification_uri_complete'] as String?,
      expiresIn: data['expires_in'] as int? ?? 900,
      interval: _pollInterval,
    );
  }

  /// Poll for device code flow completion
  ///
  /// Returns true when authentication is complete, false if still pending.
  /// Throws [EnrollmentException] on errors or expiry.
  Future<DeviceCodePollResult> pollDeviceCodeFlow(String providerId) async {
    if (_pendingDeviceCode == null) {
      throw EnrollmentException('No pending device code flow');
    }

    // Check if device code has expired
    if (_deviceCodeExpiry != null && DateTime.now().isAfter(_deviceCodeExpiry!)) {
      _clearPendingDeviceCode();
      throw EnrollmentException('Device code has expired');
    }

    final response = await _api.post(
      '/api/v1/auth/sso/$providerId/device/poll',
      body: {'device_code': _pendingDeviceCode},
    );

    if (!response.isSuccess) {
      final error = response.error ?? '';
      final statusCode = response.statusCode;

      // Handle standard device code flow errors
      if (error.contains('authorization_pending') ||
          (statusCode == 400 && error.contains('pending'))) {
        return DeviceCodePollResult.pending;
      }

      if (error.contains('slow_down')) {
        // Increase polling interval
        _pollInterval = (_pollInterval * 1.5).ceil();
        return DeviceCodePollResult.slowDown;
      }

      if (error.contains('expired')) {
        _clearPendingDeviceCode();
        throw EnrollmentException('Device code has expired');
      }

      if (error.contains('access_denied')) {
        _clearPendingDeviceCode();
        throw EnrollmentException('User denied authorization');
      }

      throw EnrollmentException('Poll failed: $error');
    }

    // Success - we got tokens
    final data = response.data as Map<String, dynamic>;

    // Store tokens
    await _credentials.setAuthTokens(AuthTokens(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
      provider: providerId,
    ));

    _clearPendingDeviceCode();
    return DeviceCodePollResult.success;
  }

  /// Start automatic polling for device code completion
  ///
  /// Calls [onComplete] when authentication succeeds.
  /// Calls [onError] on failures.
  /// Calls [onPending] on each pending poll (optional).
  void startPolling({
    required String providerId,
    required void Function() onComplete,
    required void Function(String error) onError,
    void Function()? onPending,
  }) {
    _pollTimer?.cancel();

    _pollTimer = Timer.periodic(
      Duration(seconds: _pollInterval),
      (_) async {
        try {
          final result = await pollDeviceCodeFlow(providerId);

          switch (result) {
            case DeviceCodePollResult.success:
              _pollTimer?.cancel();
              onComplete();
            case DeviceCodePollResult.pending:
              onPending?.call();
            case DeviceCodePollResult.slowDown:
              // Timer will use updated interval on next creation
              _pollTimer?.cancel();
              startPolling(
                providerId: providerId,
                onComplete: onComplete,
                onError: onError,
                onPending: onPending,
              );
          }
        } catch (e) {
          _pollTimer?.cancel();
          onError(e.toString());
        }
      },
    );
  }

  /// Stop polling
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _clearPendingDeviceCode();
  }

  void _clearPendingDeviceCode() {
    _pendingDeviceCode = null;
    _deviceCodeExpiry = null;
    _pollInterval = 5;
  }

  // ═══════════════════════════════════════════════════════════════════
  // DEVICE REGISTRATION
  // ═══════════════════════════════════════════════════════════════════

  /// Register this device with the server
  ///
  /// Should be called after successful SSO authentication.
  Future<void> registerDevice() async {
    final deviceInfo = await _collectDeviceInfo();

    final response = await _api.post(
      '/api/v1/enrollment/register',
      body: deviceInfo,
    );

    if (!response.isSuccess) {
      throw EnrollmentException('Device registration failed: ${response.error}');
    }

    final data = response.data as Map<String, dynamic>;

    // Store device token
    final deviceToken = data['device_token'] as String?;
    if (deviceToken != null) {
      await _credentials.setDeviceToken(deviceToken);
    }

    // Store initial config if provided
    final config = data['config'] as String?;
    final configVersion = data['config_version'] as String?;
    if (config != null && configVersion != null) {
      await _credentials.setVpnConfig(config, configVersion);
    }
  }

  /// Collect device information for registration
  Future<Map<String, dynamic>> _collectDeviceInfo() async {
    return {
      'machine_name': Platform.localHostname,
      'platform': _getPlatform(),
      'platform_version': Platform.operatingSystemVersion,
      'hardware_id': await _getHardwareId(),
      'client_version': '1.0.0', // TODO: Get from package info
    };
  }

  String _getPlatform() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Get a unique hardware identifier
  ///
  /// This is used to uniquely identify the device for enrollment.
  Future<String> _getHardwareId() async {
    // Try to get a stable hardware ID
    // On macOS: Use IOPlatformUUID
    // On Windows: Use MachineGuid from registry
    // On Linux: Use machine-id

    try {
      if (Platform.isMacOS) {
        final result = await Process.run('ioreg', [
          '-rd1',
          '-c',
          'IOPlatformExpertDevice',
        ]);
        final output = result.stdout as String;
        final match = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch(output);
        if (match != null) {
          return match.group(1)!;
        }
      } else if (Platform.isLinux) {
        final file = File('/etc/machine-id');
        if (await file.exists()) {
          return (await file.readAsString()).trim();
        }
      } else if (Platform.isWindows) {
        final result = await Process.run('reg', [
          'query',
          r'HKLM\SOFTWARE\Microsoft\Cryptography',
          '/v',
          'MachineGuid',
        ]);
        final output = result.stdout as String;
        final match = RegExp(r'MachineGuid\s+REG_SZ\s+(.+)').firstMatch(output);
        if (match != null) {
          return match.group(1)!.trim();
        }
      }
    } catch (e) {
      debugPrint('Failed to get hardware ID: $e');
    }

    // Fallback: Generate and store a UUID
    var fallbackId = await _credentials.getSecure('fallback_hardware_id');
    if (fallbackId == null) {
      fallbackId = _generateUuid();
      await _credentials.setSecure('fallback_hardware_id', fallbackId);
    }
    return fallbackId;
  }

  String _generateUuid() {
    // Simple UUID v4 generation
    final random = DateTime.now().millisecondsSinceEpoch;
    return '${random.toRadixString(16)}-${(random ~/ 1000).toRadixString(16)}'
        '-${Platform.localHostname.hashCode.toRadixString(16)}';
  }

  // ═══════════════════════════════════════════════════════════════════
  // CONFIG MANAGEMENT
  // ═══════════════════════════════════════════════════════════════════

  /// Fetch latest VPN configuration from server
  Future<String?> fetchConfig() async {
    final response = await _api.get('/api/v1/enrollment/config');

    if (!response.isSuccess) {
      if (response.statusCode == 401) {
        throw EnrollmentException('Not authenticated');
      }
      throw EnrollmentException('Failed to fetch config: ${response.error}');
    }

    if (response.data is String) {
      // Plain text config
      final config = response.data as String;
      await _credentials.setVpnConfig(config, DateTime.now().toIso8601String());
      return config;
    }

    final data = response.data as Map<String, dynamic>;
    final config = data['config'] as String?;
    final version = data['version'] as String?;

    if (config != null && version != null) {
      await _credentials.setVpnConfig(config, version);
    }

    return config;
  }

  /// Check if config update is available
  Future<bool> checkConfigUpdate() async {
    final currentVersion = await _credentials.getConfigVersion();

    final response = await _api.get('/api/v1/enrollment/config/version');

    if (!response.isSuccess) {
      return false;
    }

    final data = response.data as Map<String, dynamic>;
    final serverVersion = data['version'] as String?;

    return serverVersion != null && serverVersion != currentVersion;
  }

  /// Get locally stored VPN config
  Future<String?> getStoredConfig() async {
    final stored = await _credentials.getVpnConfig();
    return stored?.config;
  }

  // ═══════════════════════════════════════════════════════════════════
  // TOKEN REFRESH
  // ═══════════════════════════════════════════════════════════════════

  /// Refresh auth tokens if needed
  Future<bool> refreshTokens() async {
    final tokens = await _credentials.getAuthTokens();

    if (tokens == null || !tokens.canRefresh) {
      return false;
    }

    final response = await _api.post(
      '/api/v1/auth/refresh',
      body: {'refresh_token': tokens.refreshToken},
    );

    if (!response.isSuccess) {
      // Refresh failed - clear tokens
      await _credentials.clearAuthTokens();
      return false;
    }

    final data = response.data as Map<String, dynamic>;

    await _credentials.setAuthTokens(AuthTokens(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String? ?? tokens.refreshToken,
      provider: tokens.provider,
    ));

    return true;
  }

  // ═══════════════════════════════════════════════════════════════════
  // STATUS & HEARTBEAT
  // ═══════════════════════════════════════════════════════════════════

  /// Send heartbeat to server with device status
  Future<void> sendHeartbeat({
    required bool isConnected,
    String? vpnIp,
    int? bytesSent,
    int? bytesReceived,
  }) async {
    await _api.post(
      '/api/v1/enrollment/heartbeat',
      body: {
        'connected': isConnected,
        'vpn_ip': vpnIp,
        'bytes_sent': bytesSent,
        'bytes_received': bytesReceived,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  /// Check enrollment status
  Future<EnrollmentStatus> checkEnrollmentStatus() async {
    final hasDeviceToken = await _credentials.isDeviceEnrolled();
    final hasAuthTokens = await _credentials.hasAuthTokens();
    final hasConfig = (await _credentials.getVpnConfig()) != null;

    if (!hasAuthTokens) {
      return EnrollmentStatus.notAuthenticated;
    }

    if (!hasDeviceToken) {
      return EnrollmentStatus.notEnrolled;
    }

    if (!hasConfig) {
      return EnrollmentStatus.noConfig;
    }

    return EnrollmentStatus.ready;
  }

  // ═══════════════════════════════════════════════════════════════════
  // LOGOUT / RESET
  // ═══════════════════════════════════════════════════════════════════

  /// Log out and clear all credentials
  Future<void> logout() async {
    stopPolling();
    await _credentials.clearAll();
  }

  void dispose() {
    stopPolling();
  }
}

/// Enrollment status
enum EnrollmentStatus {
  notAuthenticated,
  notEnrolled,
  noConfig,
  ready,
}

/// SSO provider info from server
class SSOProviderInfo {
  final String id;
  final String name;
  final bool enabled;

  SSOProviderInfo({
    required this.id,
    required this.name,
    required this.enabled,
  });

  factory SSOProviderInfo.fromJson(Map<String, dynamic> json) {
    return SSOProviderInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

/// Device authorization info for device code flow
class DeviceAuthInfo {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String? verificationUriComplete;
  final int expiresIn;
  final int interval;

  DeviceAuthInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });
}

/// Result of device code polling
enum DeviceCodePollResult {
  success,
  pending,
  slowDown,
}

/// Enrollment exception
class EnrollmentException implements Exception {
  final String message;

  EnrollmentException(this.message);

  @override
  String toString() => 'EnrollmentException: $message';
}
