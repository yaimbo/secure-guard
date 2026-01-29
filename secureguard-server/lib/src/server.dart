import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'api/routes/auth_routes.dart';
import 'api/routes/client_routes.dart';
import 'api/routes/dashboard_routes.dart';
import 'api/routes/enrollment_routes.dart';
import 'api/routes/log_routes.dart';
import 'api/routes/settings_routes.dart';
import 'api/routes/sso_routes.dart';
import 'api/routes/update_routes.dart';
import 'api/routes/health_routes.dart';
import 'api/routes/websocket_routes.dart';
import 'services/redis_service.dart';
import 'api/middleware/logging_middleware.dart';
import 'api/middleware/auth_middleware.dart';
import 'database/database.dart';
import 'services/client_service.dart';
import 'services/config_generator_service.dart';
import 'services/email_service.dart';
import 'services/email_queue_service.dart';
import 'services/key_service.dart';
import 'services/sso/sso_manager.dart';
import 'repositories/client_repository.dart';
import 'repositories/admin_repository.dart';
import 'repositories/api_key_repository.dart';
import 'repositories/email_settings_repository.dart';
import 'repositories/log_repository.dart';
import 'repositories/server_config_repository.dart';

class SecureGuardServer {
  final ServerConfig config;
  final _log = Logger('SecureGuardServer');

  HttpServer? _server;
  Database? _database;
  RedisService? _redis;
  WebSocketRoutes? _wsRoutes;
  EmailService? _emailService;
  EmailQueueService? _emailQueueService;

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
    final apiKeyRepo = ApiKeyRepository(_database!);
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
      db: _database!,
      serverDomain: config.serverDomain,
    );

    // Initialize SSO manager
    final ssoManager = SSOManager(_database!);
    await ssoManager.init();
    _log.info('SSO manager initialized');

    // Initialize Redis for pub/sub and caching
    _redis = RedisService(
      host: config.redisHost,
      port: config.redisPort,
      password: config.redisPassword,
    );
    await _redis!.init();
    _log.info('Redis service initialized');

    // Initialize email service
    _emailService = EmailService(encryptionKey: config.encryptionKey);
    final emailSettingsRepo = EmailSettingsRepository(_database!);

    // Configure email service from database settings
    final emailSettings = await emailSettingsRepo.get();
    if (emailSettings != null && emailSettings.enabled) {
      String? password;
      if (emailSettings.smtpPasswordEnc != null) {
        password = await _emailService!.decryptPassword(emailSettings.smtpPasswordEnc!);
      }
      await _emailService!.configure(emailSettings.toSmtpConfig(decryptedPassword: password));
      _log.info('Email service configured');
    }

    // Initialize email queue service
    _emailQueueService = EmailQueueService(
      redis: _redis!,
      emailService: _emailService!,
    );
    _emailQueueService!.startProcessor();
    _log.info('Email queue processor started');

    // Initialize WebSocket routes for real-time updates
    _wsRoutes = WebSocketRoutes(
      redis: _redis!,
      clientRepo: clientRepo,
      logRepo: logRepo,
      jwtSecret: config.jwtSecret,
    );
    _log.info('WebSocket routes initialized');

    // Initialize middleware
    final authMiddleware = AuthMiddleware(config.jwtSecret, adminRepo, apiKeyRepo: apiKeyRepo);

    // Set up routes
    final router = Router();

    // Health check (no auth)
    final healthRoutes = HealthRoutes();
    router.mount('/api/v1/health', healthRoutes.router.call);

    // Auth routes (no auth for login)
    final authRoutes = AuthRoutes(
      adminRepo,
      config.jwtSecret,
      logRepo,
      serverConfigRepo: serverConfigRepo,
      keyService: keyService,
    );
    router.mount('/api/v1/auth', authRoutes.router.call);

    // SSO routes - public endpoints (authorization flow)
    final ssoRoutes = SSORoutes(
      ssoManager: ssoManager,
      adminRepo: adminRepo,
      clientRepo: clientRepo,
      logRepo: logRepo,
      jwtSecret: config.jwtSecret,
    );
    router.mount('/api/v1/auth/sso', ssoRoutes.router.call);

    // SSO routes - admin endpoints (configuration management)
    router.mount(
      '/api/v1/admin/sso',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(ssoRoutes.adminRouter.call),
    );

    // Client routes (admin auth required)
    final clientRoutes = ClientRoutes(
      clientService,
      logRepo,
      emailQueueService: _emailQueueService,
      serverDomain: config.serverDomain,
    );
    router.mount(
      '/api/v1/clients',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(clientRoutes.router.call),
    );

    // Settings routes (admin auth required)
    final settingsRoutes = SettingsRoutes(
      adminRepo: adminRepo,
      apiKeyRepo: apiKeyRepo,
      emailSettingsRepo: emailSettingsRepo,
      serverConfigRepo: serverConfigRepo,
      emailService: _emailService!,
      emailQueueService: _emailQueueService!,
      keyService: keyService,
      logRepo: logRepo,
    );
    router.mount(
      '/api/v1/admin/settings',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(settingsRoutes.router.call),
    );

    // Enrollment routes (some require device auth)
    final enrollmentRoutes = EnrollmentRoutes(
      clientService,
      logRepo,
      redis: _redis,
      jwtSecret: config.jwtSecret,
      clientRepo: clientRepo,
    );
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

    // Dashboard routes (admin auth required)
    final dashboardRoutes = DashboardRoutes(
      clientRepo: clientRepo,
      logRepo: logRepo,
      redis: _redis!,
    );
    router.mount(
      '/api/v1/dashboard',
      Pipeline()
          .addMiddleware(authMiddleware.requireAdmin())
          .addHandler(dashboardRoutes.router.call),
    );

    // WebSocket routes for real-time dashboard updates
    // Note: WebSocket upgrades bypass normal middleware, so auth is handled in the handler
    router.mount('/api/v1/ws', _wsRoutes!.router.call);

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
    _emailQueueService?.stopProcessor();
    _wsRoutes?.dispose();
    await _redis?.close();
    await _server?.close();
    await _database?.close();
    _log.info('Server stopped');
  }
}
