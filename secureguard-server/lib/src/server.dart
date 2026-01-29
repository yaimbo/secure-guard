import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'api/routes/auth_routes.dart';
import 'api/routes/client_routes.dart';
import 'api/routes/enrollment_routes.dart';
import 'api/routes/log_routes.dart';
import 'api/routes/update_routes.dart';
import 'api/routes/health_routes.dart';
import 'api/middleware/logging_middleware.dart';
import 'api/middleware/auth_middleware.dart';
import 'database/database.dart';
import 'services/client_service.dart';
import 'services/config_generator_service.dart';
import 'services/key_service.dart';
import 'repositories/client_repository.dart';
import 'repositories/admin_repository.dart';
import 'repositories/log_repository.dart';
import 'repositories/server_config_repository.dart';

class SecureGuardServer {
  final ServerConfig config;
  final _log = Logger('SecureGuardServer');

  HttpServer? _server;
  Database? _database;

  SecureGuardServer(this.config);

  Future<void> start() async {
    // Initialize database
    _database = Database(
      host: config.dbHost,
      port: config.dbPort,
      database: config.dbName,
      username: config.dbUser,
      password: config.dbPassword,
    );

    // Run migrations
    await _database!.migrate();
    _log.info('Database initialized and migrated');

    // Initialize repositories
    final clientRepo = ClientRepository(_database!);
    final adminRepo = AdminRepository(_database!);
    final logRepo = LogRepository(_database!);
    final serverConfigRepo = ServerConfigRepository(_database!);

    // Initialize services
    final keyService = KeyService(encryptionKey: config.encryptionKey);
    final configGenerator = ConfigGeneratorService();
    final clientService = ClientService(
      clientRepo: clientRepo,
      serverConfigRepo: serverConfigRepo,
      keyService: keyService,
      configGenerator: configGenerator,
    );

    // Initialize middleware
    final authMiddleware = AuthMiddleware(config.jwtSecret, adminRepo);

    // Set up routes
    final router = Router();

    // Health check (no auth)
    final healthRoutes = HealthRoutes();
    router.mount('/api/v1/health', healthRoutes.router.call);

    // Auth routes (no auth for login)
    final authRoutes = AuthRoutes(adminRepo, config.jwtSecret, logRepo);
    router.mount('/api/v1/auth', authRoutes.router.call);

    // Client routes (admin auth required)
    final clientRoutes = ClientRoutes(clientService, logRepo);
    router.mount(
      '/api/v1/clients',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(clientRoutes.router.call),
    );

    // Enrollment routes (some require device auth)
    final enrollmentRoutes = EnrollmentRoutes(clientService, logRepo);
    router.mount('/api/v1/enrollment', enrollmentRoutes.router.call);

    // Update routes - public endpoints (check, manifest, download)
    final updateRoutes = UpdateRoutes(_database!);
    router.mount('/api/v1/updates', updateRoutes.router.call);

    // Update routes - admin endpoints (release management)
    router.mount(
      '/api/v1/updates/releases',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(updateRoutes.adminRouter.call),
    );

    // Log routes (admin auth required)
    final logRoutes = LogRoutes(logRepo);
    router.mount(
      '/api/v1/logs',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(logRoutes.router.call),
    );

    // Build handler with middleware
    // Use '*' for CORS in development - browsers don't support multiple origins
    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(corsHeaders(
          headers: {
            ACCESS_CONTROL_ALLOW_ORIGIN: '*',
            ACCESS_CONTROL_ALLOW_METHODS: 'GET, POST, PUT, DELETE, PATCH, OPTIONS',
            ACCESS_CONTROL_ALLOW_HEADERS: 'Origin, Content-Type, Authorization',
          },
        ))
        .addMiddleware(requestLogger())
        .addHandler(router.call);

    // Start server
    _server = await shelf_io.serve(
      handler,
      config.host,
      config.port,
    );

    _log.info('Server running on http://${config.host}:${config.port}');
  }

  Future<void> stop() async {
    await _server?.close();
    await _database?.close();
    _log.info('Server stopped');
  }
}
