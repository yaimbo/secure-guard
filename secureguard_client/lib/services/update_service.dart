import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Service for handling config and binary updates
class UpdateService {
  static const String _configVersionKey = 'config_version';
  static const Duration _configCheckInterval = Duration(minutes: 5);
  static const Duration _updateCheckInterval = Duration(hours: 1);

  static final UpdateService _instance = UpdateService._();
  static UpdateService get instance => _instance;

  UpdateService._();

  Timer? _configCheckTimer;
  Timer? _updateCheckTimer;
  String? _currentConfigVersion;
  final String _clientVersion = '1.0.0';

  /// Callbacks for update events
  void Function(String newConfig)? onConfigUpdated;
  void Function(UpdateInfo updateInfo)? onUpdateAvailable;

  /// Initialize the update service
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _currentConfigVersion = prefs.getString(_configVersionKey);

    // Start periodic checks
    _startPeriodicChecks();
  }

  /// Start periodic config and update checks
  void _startPeriodicChecks() {
    // Check config version every 5 minutes
    _configCheckTimer = Timer.periodic(_configCheckInterval, (_) {
      checkConfigVersion();
    });

    // Check for binary updates every hour
    _updateCheckTimer = Timer.periodic(_updateCheckInterval, (_) {
      checkForUpdates();
    });
  }

  /// Stop periodic checks
  void stopPeriodicChecks() {
    _configCheckTimer?.cancel();
    _updateCheckTimer?.cancel();
  }

  /// Check if config has been updated on the server
  Future<ConfigVersionResult> checkConfigVersion() async {
    if (!ApiClient.instance.isEnrolled) {
      return ConfigVersionResult.notEnrolled();
    }

    final response = await ApiClient.instance.get('/api/v1/enrollment/config/version');

    if (!response.isSuccess) {
      return ConfigVersionResult.error(response.error ?? 'Unknown error');
    }

    final data = response.data as Map<String, dynamic>;
    final serverVersion = data['version'] as String;
    final status = data['status'] as String?;

    // Check if client is disabled
    if (status == 'disabled') {
      return ConfigVersionResult.disabled();
    }

    // Check if version changed
    if (_currentConfigVersion != null && _currentConfigVersion != serverVersion) {
      // Config has been updated, fetch new config
      final configResult = await fetchConfig();
      if (configResult.isSuccess) {
        _currentConfigVersion = serverVersion;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_configVersionKey, serverVersion);

        onConfigUpdated?.call(configResult.config!);
        return ConfigVersionResult.updated(configResult.config!);
      }
      return ConfigVersionResult.error(configResult.error ?? 'Failed to fetch config');
    }

    // Store version if first check
    if (_currentConfigVersion == null) {
      _currentConfigVersion = serverVersion;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configVersionKey, serverVersion);
    }

    return ConfigVersionResult.unchanged();
  }

  /// Fetch the full config from server
  Future<ConfigFetchResult> fetchConfig() async {
    if (!ApiClient.instance.isEnrolled) {
      return ConfigFetchResult.error('Not enrolled');
    }

    final response = await ApiClient.instance.get('/api/v1/enrollment/config');

    if (!response.isSuccess) {
      return ConfigFetchResult.error(response.error ?? 'Failed to fetch config');
    }

    // Config is returned as plain text
    final config = response.data as String;
    return ConfigFetchResult.success(config);
  }

  /// Check for binary updates
  Future<UpdateCheckResult> checkForUpdates() async {
    final platform = _getPlatformName();
    final arch = _getArchitecture();

    final response = await ApiClient.instance.get(
      '/api/v1/updates/check',
      queryParams: {
        'platform': platform,
        'arch': arch,
        'version': _clientVersion,
      },
    );

    if (!response.isSuccess) {
      return UpdateCheckResult.error(response.error ?? 'Failed to check for updates');
    }

    final data = response.data as Map<String, dynamic>;
    final updateAvailable = data['update_available'] as bool;

    if (!updateAvailable) {
      return UpdateCheckResult.noUpdate();
    }

    final updateInfo = UpdateInfo(
      version: data['version'] as String,
      downloadUrl: data['download_url'] as String,
      signature: data['signature'] as String,
      sha256: data['sha256'] as String,
      fileSize: data['file_size'] as int,
      releaseNotes: data['release_notes'] as String?,
      mandatory: data['mandatory'] as bool? ?? false,
    );

    onUpdateAvailable?.call(updateInfo);
    return UpdateCheckResult.available(updateInfo);
  }

  /// Download and verify an update
  Future<DownloadResult> downloadUpdate(UpdateInfo updateInfo) async {
    try {
      // Create temp directory for download
      final tempDir = await Directory.systemTemp.createTemp('secureguard_update_');
      final downloadPath = '${tempDir.path}/secureguard_update';
      final downloadFile = File(downloadPath);

      // Download the file
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(updateInfo.downloadUrl));
      final response = await request.close();

      if (response.statusCode != 200) {
        await tempDir.delete(recursive: true);
        return DownloadResult.error('Download failed: HTTP ${response.statusCode}');
      }

      final sink = downloadFile.openWrite();
      await response.pipe(sink);
      await sink.close();
      httpClient.close();

      // Verify SHA256 hash
      final bytes = await downloadFile.readAsBytes();
      final actualHash = sha256.convert(bytes).toString();

      if (actualHash != updateInfo.sha256) {
        await tempDir.delete(recursive: true);
        return DownloadResult.error('Hash verification failed');
      }

      // Verify Ed25519 signature
      if (!_verifySignature(bytes, updateInfo.signature)) {
        await tempDir.delete(recursive: true);
        return DownloadResult.error('Signature verification failed');
      }

      return DownloadResult.success(downloadPath);
    } catch (e) {
      return DownloadResult.error('Download failed: $e');
    }
  }

  /// Send heartbeat to server
  Future<void> sendHeartbeat() async {
    if (!ApiClient.instance.isEnrolled) return;

    await ApiClient.instance.post('/api/v1/enrollment/heartbeat', body: {
      'client_version': _clientVersion,
      'platform_version': Platform.operatingSystemVersion,
    });
  }

  String _getPlatformName() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  String _getArchitecture() {
    // Dart doesn't provide direct architecture info
    // On Apple Silicon Macs, we return arm64
    if (Platform.isMacOS) {
      // Check if running on ARM
      final result = Process.runSync('uname', ['-m']);
      final arch = result.stdout.toString().trim();
      return arch == 'arm64' ? 'arm64' : 'x64';
    }
    return 'x64';
  }

  /// Verify Ed25519 signature of update binary
  ///
  /// The signature is expected to be base64-encoded Ed25519 signature.
  /// The public key is embedded at build time via UPDATE_SIGNING_PUBLIC_KEY.
  bool _verifySignature(Uint8List data, String signatureBase64) {
    try {
      // The update signing public key (embedded in client at build time)
      const publicKeyBase64 = String.fromEnvironment(
        'UPDATE_SIGNING_PUBLIC_KEY',
        defaultValue: '',
      );

      // If no public key is configured, skip signature verification
      // This allows development builds without signing
      if (publicKeyBase64.isEmpty) {
        return true;
      }

      // Decode the signature and public key
      final signature = base64Decode(signatureBase64);
      final publicKey = base64Decode(publicKeyBase64);

      // Verify Ed25519 signature
      // Note: This requires a native implementation or FFI binding
      // For production, integrate with the Rust crypto library via FFI
      // or use a platform channel to call native Ed25519 verification
      return _verifyEd25519Native(data, signature, publicKey);
    } catch (e) {
      // Signature verification failed
      return false;
    }
  }

  /// Native Ed25519 verification
  ///
  /// In production, this should call native code via FFI or platform channel.
  /// The Rust daemon already has Ed25519 support that can be exposed.
  bool _verifyEd25519Native(
    Uint8List message,
    Uint8List signature,
    Uint8List publicKey,
  ) {
    // Placeholder: In production, call native verification
    // For now, we rely on SHA256 hash verification and HTTPS transport
    //
    // To implement properly:
    // 1. Use flutter_rust_bridge to call Rust Ed25519 verification
    // 2. Or use platform channels to call native crypto APIs
    // 3. Or use dart:ffi with libsodium

    // Validate signature length (Ed25519 signatures are 64 bytes)
    if (signature.length != 64) {
      return false;
    }

    // Validate public key length (Ed25519 public keys are 32 bytes)
    if (publicKey.length != 32) {
      return false;
    }

    // For development, return true if lengths are valid
    // Production builds must implement actual verification
    return true;
  }

  void dispose() {
    stopPeriodicChecks();
  }
}

/// Result of config version check
class ConfigVersionResult {
  final bool isSuccess;
  final bool isUpdated;
  final bool isDisabled;
  final bool isNotEnrolled;
  final String? newConfig;
  final String? error;

  ConfigVersionResult._({
    required this.isSuccess,
    this.isUpdated = false,
    this.isDisabled = false,
    this.isNotEnrolled = false,
    this.newConfig,
    this.error,
  });

  factory ConfigVersionResult.unchanged() => ConfigVersionResult._(
        isSuccess: true,
      );

  factory ConfigVersionResult.updated(String config) => ConfigVersionResult._(
        isSuccess: true,
        isUpdated: true,
        newConfig: config,
      );

  factory ConfigVersionResult.disabled() => ConfigVersionResult._(
        isSuccess: false,
        isDisabled: true,
        error: 'Client has been disabled',
      );

  factory ConfigVersionResult.notEnrolled() => ConfigVersionResult._(
        isSuccess: false,
        isNotEnrolled: true,
        error: 'Device not enrolled',
      );

  factory ConfigVersionResult.error(String error) => ConfigVersionResult._(
        isSuccess: false,
        error: error,
      );
}

/// Result of config fetch
class ConfigFetchResult {
  final bool isSuccess;
  final String? config;
  final String? error;

  ConfigFetchResult._({
    required this.isSuccess,
    this.config,
    this.error,
  });

  factory ConfigFetchResult.success(String config) => ConfigFetchResult._(
        isSuccess: true,
        config: config,
      );

  factory ConfigFetchResult.error(String error) => ConfigFetchResult._(
        isSuccess: false,
        error: error,
      );
}

/// Result of update check
class UpdateCheckResult {
  final bool isSuccess;
  final bool updateAvailable;
  final UpdateInfo? updateInfo;
  final String? error;

  UpdateCheckResult._({
    required this.isSuccess,
    this.updateAvailable = false,
    this.updateInfo,
    this.error,
  });

  factory UpdateCheckResult.noUpdate() => UpdateCheckResult._(
        isSuccess: true,
        updateAvailable: false,
      );

  factory UpdateCheckResult.available(UpdateInfo info) => UpdateCheckResult._(
        isSuccess: true,
        updateAvailable: true,
        updateInfo: info,
      );

  factory UpdateCheckResult.error(String error) => UpdateCheckResult._(
        isSuccess: false,
        error: error,
      );
}

/// Information about an available update
class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String signature;
  final String sha256;
  final int fileSize;
  final String? releaseNotes;
  final bool mandatory;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.signature,
    required this.sha256,
    required this.fileSize,
    this.releaseNotes,
    this.mandatory = false,
  });
}

/// Result of update download
class DownloadResult {
  final bool isSuccess;
  final String? filePath;
  final String? error;

  DownloadResult._({
    required this.isSuccess,
    this.filePath,
    this.error,
  });

  factory DownloadResult.success(String path) => DownloadResult._(
        isSuccess: true,
        filePath: path,
      );

  factory DownloadResult.error(String error) => DownloadResult._(
        isSuccess: false,
        error: error,
      );
}
