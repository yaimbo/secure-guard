import 'dart:io';

import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';
import 'package:secureguard_server/server.dart';

IOSink? _logFile;

Future<void> main(List<String> args) async {
  // Parse command line arguments
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'Port to listen on')
    ..addOption('host', abbr: 'h', defaultsTo: '0.0.0.0', help: 'Host to bind to')
    ..addOption('log-file', abbr: 'l', help: 'Path to log file (default: logs/server.log)')
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

  // Set up log file
  final logFilePath = results['log-file'] as String? ?? env['LOG_FILE'] ?? 'logs/server.log';
  try {
    final logDir = Directory(logFilePath.substring(0, logFilePath.lastIndexOf('/')));
    if (!logDir.existsSync()) {
      logDir.createSync(recursive: true);
    }
    _logFile = File(logFilePath).openWrite(mode: FileMode.append);
  } catch (e) {
    print('Warning: Could not open log file $logFilePath: $e');
  }

  // Set up logging - output to both console and file
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String().substring(0, 23);
    final levelPadded = record.level.name.padRight(7);
    var message = '$time [$levelPadded] ${record.loggerName}: ${record.message}';

    // Include error and stack trace if present
    if (record.error != null) {
      message += '\n  Error: ${record.error}';
    }
    if (record.stackTrace != null) {
      message += '\n  Stack trace:\n${record.stackTrace.toString().split('\n').map((l) => '    $l').join('\n')}';
    }

    // Print to console
    print(message);

    // Write to log file
    _logFile?.writeln(message);
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
      await _logFile?.flush();
      await _logFile?.close();
      exit(0);
    });
  } catch (e, stackTrace) {
    log.severe('Failed to start server: $e', e, stackTrace);
    await _logFile?.flush();
    await _logFile?.close();
    exit(1);
  }
}
