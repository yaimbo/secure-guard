import 'dart:io';

/// Result of an uninstall operation
class UninstallResult {
  final bool success;
  final String? error;

  UninstallResult.success() : success = true, error = null;
  UninstallResult.failure(this.error) : success = false;
}

/// Service to handle platform-specific uninstallation of SecureGuard
class UninstallService {
  /// Platform-specific uninstall script paths
  static const _macOSScriptPath =
      '/Library/Application Support/SecureGuard/uninstall.sh';
  static const _windowsScriptPath =
      r'C:\Program Files\SecureGuard\uninstall.ps1';
  static const _linuxScriptPath = '/opt/secureguard/uninstall.sh';

  /// Check if the uninstall script exists for the current platform
  static Future<bool> isUninstallAvailable() async {
    final scriptPath = _getScriptPath();
    if (scriptPath == null) return false;
    return File(scriptPath).exists();
  }

  /// Get the uninstall script path for the current platform
  static String? _getScriptPath() {
    if (Platform.isMacOS) {
      return _macOSScriptPath;
    } else if (Platform.isWindows) {
      return _windowsScriptPath;
    } else if (Platform.isLinux) {
      return _linuxScriptPath;
    }
    return null;
  }

  /// Perform the uninstall with platform-specific elevation
  /// Returns true if uninstall was successful
  static Future<UninstallResult> uninstall() async {
    if (Platform.isMacOS) {
      return _uninstallMacOS();
    } else if (Platform.isWindows) {
      return _uninstallWindows();
    } else if (Platform.isLinux) {
      return _uninstallLinux();
    }
    return UninstallResult.failure('Unsupported platform');
  }

  /// macOS: Use osascript with administrator privileges for elevation
  static Future<UninstallResult> _uninstallMacOS() async {
    final scriptPath = _macOSScriptPath;

    // Check if script exists
    if (!await File(scriptPath).exists()) {
      return UninstallResult.failure(
        'Uninstall script not found. Please reinstall MinnowVPN or manually remove it.',
      );
    }

    // Use osascript to run with administrator privileges
    // This will show the macOS password prompt
    final appleScript = '''
do shell script "'\$scriptPath' --all" with administrator privileges
''';

    try {
      final result = await Process.run(
        'osascript',
        ['-e', appleScript.replaceAll('\$scriptPath', scriptPath)],
      );

      if (result.exitCode == 0) {
        return UninstallResult.success();
      } else {
        // Exit code -128 means user cancelled the auth dialog
        if (result.exitCode == -128 ||
            result.stderr.toString().contains('User canceled')) {
          return UninstallResult.failure('Uninstall cancelled by user');
        }
        return UninstallResult.failure(
          result.stderr.toString().isNotEmpty
              ? result.stderr.toString()
              : 'Uninstall failed with exit code ${result.exitCode}',
        );
      }
    } catch (e) {
      return UninstallResult.failure('Failed to run uninstall: $e');
    }
  }

  /// Windows: Use PowerShell Start-Process with RunAs for UAC elevation
  static Future<UninstallResult> _uninstallWindows() async {
    final scriptPath = _windowsScriptPath;

    // Check if script exists
    if (!await File(scriptPath).exists()) {
      return UninstallResult.failure(
        'Uninstall script not found. Please use Windows Settings > Apps to uninstall MinnowVPN.',
      );
    }

    try {
      // Start elevated PowerShell process and wait for it
      // The -Wait flag ensures we wait for completion
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          '''
Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "$scriptPath"' -Verb RunAs -Wait
'''.replaceAll('\$scriptPath', scriptPath),
        ],
      );

      if (result.exitCode == 0) {
        return UninstallResult.success();
      } else {
        // Check for UAC cancellation
        if (result.stderr.toString().contains('canceled') ||
            result.stderr.toString().contains('cancelled')) {
          return UninstallResult.failure('Uninstall cancelled by user');
        }
        return UninstallResult.failure(
          result.stderr.toString().isNotEmpty
              ? result.stderr.toString()
              : 'Uninstall failed with exit code ${result.exitCode}',
        );
      }
    } catch (e) {
      return UninstallResult.failure('Failed to run uninstall: $e');
    }
  }

  /// Linux: Use pkexec (PolicyKit) for graphical sudo elevation
  static Future<UninstallResult> _uninstallLinux() async {
    final scriptPath = _linuxScriptPath;

    // Check if script exists
    if (!await File(scriptPath).exists()) {
      return UninstallResult.failure(
        'Uninstall script not found. Please run: sudo $scriptPath --all',
      );
    }

    try {
      // pkexec provides a graphical authentication dialog
      final result = await Process.run(
        'pkexec',
        [scriptPath, '--all'],
      );

      if (result.exitCode == 0) {
        return UninstallResult.success();
      } else {
        // Exit code 126 means user dismissed the auth dialog
        if (result.exitCode == 126) {
          return UninstallResult.failure('Uninstall cancelled by user');
        }
        return UninstallResult.failure(
          result.stderr.toString().isNotEmpty
              ? result.stderr.toString()
              : 'Uninstall failed with exit code ${result.exitCode}',
        );
      }
    } catch (e) {
      return UninstallResult.failure('Failed to run uninstall: $e');
    }
  }
}
