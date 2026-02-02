import 'dart:io';

/// Server configuration
class ServerConfig {
  final String host;
  final int port;

  // Database
  final String dbHost;
  final int dbPort;
  final String dbName;
  final String dbUser;
  final String dbPassword;

  // Redis
  final String redisHost;
  final int redisPort;
  final String? redisPassword;

  // Security
  final String jwtSecret;
  final String? encryptionKey; // For encrypting private keys at rest

  // CORS
  final List<String> corsOrigins;

  // Server domain for deep links (e.g., vpn.company.com)
  final String serverDomain;

  const ServerConfig({
    required this.host,
    required this.port,
    required this.dbHost,
    required this.dbPort,
    required this.dbName,
    required this.dbUser,
    required this.dbPassword,
    required this.redisHost,
    required this.redisPort,
    this.redisPassword,
    required this.jwtSecret,
    this.encryptionKey,
    required this.corsOrigins,
    required this.serverDomain,
  });

  /// Create config from environment variables
  /// Supports Docker secrets via _FILE suffix (e.g., DB_PASSWORD_FILE)
  factory ServerConfig.fromEnv() {
    return ServerConfig(
      host: _env('HOST', '0.0.0.0'),
      port: int.parse(_env('PORT', '8080')),
      dbHost: _env('DB_HOST', 'localhost'),
      dbPort: int.parse(_env('DB_PORT', '5432')),
      dbName: _env('DB_NAME', 'minnowvpn'),
      dbUser: _env('DB_USER', 'postgres'),
      dbPassword: _envOrSecret('DB_PASSWORD', ''),
      redisHost: _env('REDIS_HOST', 'localhost'),
      redisPort: int.parse(_env('REDIS_PORT', '6379')),
      redisPassword: _envOrSecretOrNull('REDIS_PASSWORD'),
      jwtSecret: _envOrSecret('JWT_SECRET', 'change-me-in-production'),
      encryptionKey: _envOrSecretOrNull('ENCRYPTION_KEY'),
      corsOrigins: _env('CORS_ORIGINS', 'http://localhost:3000').split(','),
      serverDomain: _env('SERVER_DOMAIN', 'localhost:8080'),
    );
  }
}

/// Get environment variable with default value
String _env(String key, String defaultValue) {
  return Platform.environment[key] ?? defaultValue;
}

/// Get environment variable or Docker secret (via _FILE suffix)
/// Docker secrets pattern: if KEY_FILE is set, read value from that file
/// This allows secure secret management in Docker Swarm/Compose
String _envOrSecret(String key, String defaultValue) {
  // First check for direct environment variable
  final directValue = Platform.environment[key];
  if (directValue != null && directValue.isNotEmpty) {
    return directValue;
  }

  // Check for _FILE variant (Docker secrets)
  final fileKey = '${key}_FILE';
  final filePath = Platform.environment[fileKey];
  if (filePath != null && filePath.isNotEmpty) {
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        final content = file.readAsStringSync().trim();
        if (content.isNotEmpty) {
          return content;
        }
      }
    } catch (e) {
      // Log error but don't fail - fall through to default
      stderr.writeln('Warning: Failed to read secret from $filePath: $e');
    }
  }

  return defaultValue;
}

/// Get environment variable or Docker secret, returning null if not set
String? _envOrSecretOrNull(String key) {
  // First check for direct environment variable
  final directValue = Platform.environment[key];
  if (directValue != null && directValue.isNotEmpty) {
    return directValue;
  }

  // Check for _FILE variant (Docker secrets)
  final fileKey = '${key}_FILE';
  final filePath = Platform.environment[fileKey];
  if (filePath != null && filePath.isNotEmpty) {
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        final content = file.readAsStringSync().trim();
        if (content.isNotEmpty) {
          return content;
        }
      }
    } catch (e) {
      // Log error but don't fail
      stderr.writeln('Warning: Failed to read secret from $filePath: $e');
    }
  }

  return null;
}
