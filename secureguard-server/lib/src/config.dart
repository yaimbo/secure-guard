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

  // Security
  final String jwtSecret;
  final String? encryptionKey; // For encrypting private keys at rest

  // CORS
  final List<String> corsOrigins;

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
    required this.jwtSecret,
    this.encryptionKey,
    required this.corsOrigins,
  });

  /// Create config from environment variables
  factory ServerConfig.fromEnv() {
    return ServerConfig(
      host: _env('HOST', '0.0.0.0'),
      port: int.parse(_env('PORT', '8080')),
      dbHost: _env('DB_HOST', 'localhost'),
      dbPort: int.parse(_env('DB_PORT', '5432')),
      dbName: _env('DB_NAME', 'secureguard'),
      dbUser: _env('DB_USER', 'postgres'),
      dbPassword: _env('DB_PASSWORD', ''),
      redisHost: _env('REDIS_HOST', 'localhost'),
      redisPort: int.parse(_env('REDIS_PORT', '6379')),
      jwtSecret: _env('JWT_SECRET', 'change-me-in-production'),
      encryptionKey: _envOrNull('ENCRYPTION_KEY'),
      corsOrigins: _env('CORS_ORIGINS', 'http://localhost:3000').split(','),
    );
  }
}

String _env(String key, String defaultValue) {
  return Platform.environment[key] ?? defaultValue;
}

String? _envOrNull(String key) {
  final value = Platform.environment[key];
  return (value != null && value.isNotEmpty) ? value : null;
}
