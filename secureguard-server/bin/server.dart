import 'dart:io';

import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';
import 'package:secureguard_server/server.dart';

Future<void> main(List<String> args) async {
  // Parse command line arguments
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'Port to listen on')
    ..addOption('host', abbr: 'h', defaultsTo: '0.0.0.0', help: 'Host to bind to')
    ..addFlag('help', negatable: false, help: 'Show usage information');

  final results = parser.parse(args);

  if (results['help'] as bool) {
    print('SecureGuard API Server\n');
    print('Usage: dart run bin/server.dart [options]\n');
    print(parser.usage);
    exit(0);
  }

  // Load environment variables
  final env = DotEnv(includePlatformEnvironment: true)..load();

  // Set up logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String().substring(11, 23);
    print('$time [${record.level.name}] ${record.loggerName}: ${record.message}');
  });

  final log = Logger('main');

  // Get configuration from env vars and CLI args
  final host = results['host'] as String;
  final port = int.parse(results['port'] as String);

  final config = ServerConfig(
    host: host,
    port: port,
    dbHost: env['DB_HOST'] ?? 'localhost',
    dbPort: int.parse(env['DB_PORT'] ?? '5432'),
    dbName: env['DB_NAME'] ?? 'secureguard',
    dbUser: env['DB_USER'] ?? 'postgres',
    dbPassword: env['DB_PASSWORD'] ?? '',
    redisHost: env['REDIS_HOST'] ?? 'localhost',
    redisPort: int.parse(env['REDIS_PORT'] ?? '6379'),
    jwtSecret: env['JWT_SECRET'] ?? 'development-secret-change-in-production',
    encryptionKey: env['ENCRYPTION_KEY'],
    corsOrigins: env['CORS_ORIGINS']?.split(',') ?? ['http://localhost:3000'],
    serverDomain: env['SERVER_DOMAIN'] ?? 'localhost:8080',
  );

  log.info('Starting SecureGuard API Server...');
  log.info('Host: ${config.host}:${config.port}');
  log.info('Database: ${config.dbHost}:${config.dbPort}/${config.dbName}');

  try {
    final server = SecureGuardServer(config);
    await server.start();

    log.info('Server running at http://${config.host}:${config.port}');
    log.info('Press Ctrl+C to stop');

    // Handle shutdown
    ProcessSignal.sigint.watch().listen((_) async {
      log.info('Shutting down...');
      await server.stop();
      exit(0);
    });
  } catch (e, stackTrace) {
    log.severe('Failed to start server: $e', e, stackTrace);
    exit(1);
  }
}
