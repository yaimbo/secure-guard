import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'ipc_client.dart';

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

  /// IPC client for direct daemon communication (optional)
  /// If set, config updates will use the daemon's update_config method
  /// for seamless reconnection instead of just calling the callback.
  IpcClient? ipcClient;

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

        // If IPC client is available and connected, use update_config for seamless reconnection
        if (ipcClient != null && ipcClient!.isConnectedToDaemon) {
          try {
            await _applyConfigUpdate(configResult.config!);
          } catch (e) {
            // Log error but continue - callback will still be called
          }
        }

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

  /// Apply config update via IPC daemon
  ///
  /// Uses the daemon's update_config method for seamless reconnection.
  /// If connected, the daemon will disconnect and reconnect with new config.
  Future<void> _applyConfigUpdate(String newConfig) async {
    if (ipcClient == null || !ipcClient!.isConnectedToDaemon) {
      return;
    }

    try {
      final result = await ipcClient!.updateConfig(newConfig);
      if (result.updated) {
        // Config update successful - daemon handled reconnection
      }
    } catch (e) {
      // Config update failed - error will be reported via configUpdateFailedStream
      rethrow;
    }
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
      if (!await _verifySignature(bytes, updateInfo.signature)) {
        await tempDir.delete(recursive: true);
        return DownloadResult.error('Signature verification failed');
      }

      return DownloadResult.success(downloadPath);
    } catch (e) {
      return DownloadResult.error('Download failed: $e');
    }
  }

  /// Install downloaded update and restart the service
  ///
  /// This method:
  /// 1. Disconnects the VPN
  /// 2. Copies the new binary with elevated privileges
  /// 3. Restarts the daemon service
  /// 4. Reconnects the VPN (if previously connected)
  Future<InstallResult> installUpdate(String downloadPath, {IpcClient? ipcClient}) async {
    try {
      if (Platform.isMacOS) {
        return await _installMacOS(downloadPath, ipcClient);
      } else if (Platform.isLinux) {
        return await _installLinux(downloadPath, ipcClient);
      } else if (Platform.isWindows) {
        return await _installWindows(downloadPath, ipcClient);
      }
      return InstallResult.error('Unsupported platform');
    } catch (e) {
      return InstallResult.error('Install failed: $e');
    }
  }

  /// Install update on macOS
  Future<InstallResult> _installMacOS(String downloadPath, IpcClient? ipcClient) async {
    // 1. Disconnect VPN if connected
    if (ipcClient != null && ipcClient.isConnectedToDaemon) {
      try {
        await ipcClient.disconnectVpn();
      } catch (_) {
        // Ignore - may already be disconnected
      }
    }

    // 2. Copy binary with admin privileges using osascript
    final targetPath = '/Library/PrivilegedHelperTools/secureguard-service';
    final script = '''
      do shell script "cp '$downloadPath' '$targetPath' && chmod 755 '$targetPath'" with administrator privileges
    ''';

    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) {
      return InstallResult.error('Failed to copy binary: ${result.stderr}');
    }

    // 3. Restart the daemon using launchctl
    await Process.run('launchctl', ['kickstart', '-k', 'system/com.secureguard.vpn-service']);

    // 4. Wait for daemon to restart
    await Future.delayed(const Duration(seconds: 2));

    // 5. Reconnect IPC client
    if (ipcClient != null) {
      await ipcClient.connect();
    }

    return InstallResult.success();
  }

  /// Install update on Linux
  Future<InstallResult> _installLinux(String downloadPath, IpcClient? ipcClient) async {
    // 1. Disconnect VPN if connected
    if (ipcClient != null && ipcClient.isConnectedToDaemon) {
      try {
        await ipcClient.disconnectVpn();
      } catch (_) {
        // Ignore - may already be disconnected
      }
    }

    // 2. Copy binary and restart service with pkexec
    final targetPath = '/usr/local/bin/secureguard-service';
    final result = await Process.run('pkexec', [
      'sh',
      '-c',
      "cp '$downloadPath' '$targetPath' && chmod 755 '$targetPath' && systemctl restart secureguard",
    ]);

    if (result.exitCode != 0) {
      return InstallResult.error('Failed to install update: ${result.stderr}');
    }

    // 3. Wait for daemon to restart
    await Future.delayed(const Duration(seconds: 2));

    // 4. Reconnect IPC client
    if (ipcClient != null) {
      await ipcClient.connect();
    }

    return InstallResult.success();
  }

  /// Install update on Windows
  Future<InstallResult> _installWindows(String downloadPath, IpcClient? ipcClient) async {
    // 1. Disconnect VPN if connected
    if (ipcClient != null && ipcClient.isConnectedToDaemon) {
      try {
        await ipcClient.disconnectVpn();
      } catch (_) {
        // Ignore - may already be disconnected
      }
    }

    // 2. Stop service, copy binary, start service using elevated PowerShell
    final targetPath = r'C:\Program Files\SecureGuard\secureguard-service.exe';
    final psScript = '''
      Stop-Service SecureGuardVPN -ErrorAction SilentlyContinue;
      Copy-Item '$downloadPath' '$targetPath' -Force;
      Start-Service SecureGuardVPN
    ''';

    final result = await Process.run('powershell', [
      '-Command',
      'Start-Process powershell -Verb RunAs -Wait -ArgumentList "-Command $psScript"',
    ]);

    if (result.exitCode != 0) {
      return InstallResult.error('Failed to install update: ${result.stderr}');
    }

    // 3. Wait for service to restart
    await Future.delayed(const Duration(seconds: 3));

    // 4. Reconnect IPC client
    if (ipcClient != null) {
      await ipcClient.connect();
    }

    return InstallResult.success();
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
  Future<bool> _verifySignature(Uint8List data, String signatureBase64) async {
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

      // Verify Ed25519 signature using the cryptography package
      return await _verifyEd25519Native(data, signature, publicKey);
    } catch (e) {
      // Signature verification failed
      return false;
    }
  }

  /// Ed25519 signature verification using the cryptography package.
  ///
  /// Verifies that the given message was signed with the private key
  /// corresponding to the provided public key.
  Future<bool> _verifyEd25519Native(
    Uint8List message,
    Uint8List signature,
    Uint8List publicKey,
  ) async {
    // Validate signature length (Ed25519 signatures are 64 bytes)
    if (signature.length != 64) {
      return false;
    }

    // Validate public key length (Ed25519 public keys are 32 bytes)
    if (publicKey.length != 32) {
      return false;
    }

    try {
      final algorithm = Ed25519();

      // Create the public key object
      final pubKey = SimplePublicKey(
        List<int>.from(publicKey),
        type: KeyPairType.ed25519,
      );

      // Create the signature object
      final sig = Signature(
        List<int>.from(signature),
        publicKey: pubKey,
      );

      // Verify the signature
      return await algorithm.verify(
        List<int>.from(message),
        signature: sig,
      );
    } catch (e) {
      // Verification failed due to invalid key format or other error
      return false;
    }
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

/// Result of update installation
class InstallResult {
  final bool isSuccess;
  final String? error;

  InstallResult._({
    required this.isSuccess,
    this.error,
  });

  factory InstallResult.success() => InstallResult._(
        isSuccess: true,
      );

  factory InstallResult.error(String error) => InstallResult._(
        isSuccess: false,
        error: error,
      );
}
