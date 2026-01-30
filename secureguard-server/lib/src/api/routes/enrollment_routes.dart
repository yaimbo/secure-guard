import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../services/client_service.dart';
import '../../services/redis_service.dart';
import '../../repositories/log_repository.dart';
import '../../repositories/client_repository.dart';

/// Device enrollment routes (client-facing)
class EnrollmentRoutes {
  final ClientService clientService;
  final LogRepository logRepo;
  final RedisService? redis;
  final String jwtSecret;
  final ClientRepository clientRepo;

  /// Track active connection IDs for each client (to log disconnection properly)
  final _activeConnections = <String, int>{};

  EnrollmentRoutes(
    this.clientService,
    this.logRepo, {
    this.redis,
    required this.jwtSecret,
    required this.clientRepo,
  });

  Router get router {
    final router = Router();

    router.post('/register', _registerDevice);
    router.post('/redeem', _redeemEnrollmentCode);
    router.get('/config', _getConfig);
    router.get('/config/version', _getConfigVersion);
    router.post('/heartbeat', _heartbeat);

    return router;
  }

  /// Register a new device
  /// POST /api/v1/enrollment/register
  Future<Response> _registerDevice(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      // Required fields
      final hardwareId = data['hardware_id'] as String?;
      final platform = data['platform'] as String?;
      final deviceName = data['device_name'] as String?;

      if (hardwareId == null || platform == null) {
        return Response(400,
            body: jsonEncode({'error': 'hardware_id and platform are required'}),
            headers: {'content-type': 'application/json'});
      }

      // Check if device already exists
      var client = await clientService.getClientByHardwareId(hardwareId);

      if (client != null) {
        // Device already registered - return existing config
        await logRepo.auditLog(
          actorType: 'client',
          actorId: client.id,
          eventType: 'DEVICE_RECONNECTED',
          resourceType: 'client',
          resourceId: client.id,
          resourceName: client.name,
          details: {'platform': platform, 'hardware_id': hardwareId},
          ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
        );

        return Response.ok(
          jsonEncode({
            'status': 'existing',
            'client_id': client.id,
            'message': 'Device already registered',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      // Create new client
      final shortId = hardwareId.length > 8 ? hardwareId.substring(0, 8) : hardwareId;
      final name = deviceName ?? '$platform-$shortId';
      client = await clientService.createClient(
        name: name,
        platform: platform,
        hardwareId: hardwareId,
        userEmail: data['user_email'] as String?,
        userName: data['user_name'] as String?,
      );

      // Audit log
      await logRepo.auditLog(
        actorType: 'client',
        actorId: client.id,
        eventType: 'DEVICE_REGISTERED',
        resourceType: 'client',
        resourceId: client.id,
        resourceName: client.name,
        details: {'platform': platform, 'hardware_id': hardwareId},
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(201,
          body: jsonEncode({
            'status': 'created',
            'client_id': client.id,
            'message': 'Device registered successfully',
          }),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      await logRepo.errorLog(
        severity: 'ERROR',
        component: 'enrollment',
        message: 'Failed to register device: $e',
      );
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to register device: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Redeem an enrollment code for device token and config
  /// POST /api/v1/enrollment/redeem
  ///
  /// Body:
  /// {
  ///   "code": "ABCD-1234",
  ///   "hardware_id": "unique-device-id",
  ///   "platform": "macos",
  ///   "device_name": "John's MacBook Pro" (optional)
  /// }
  ///
  /// Returns:
  /// {
  ///   "device_token": "eyJ...",
  ///   "client_id": "uuid",
  ///   "config": "[Interface]..."
  /// }
  ///
  /// Rate limited to 5 requests per IP per minute to prevent brute-force attacks.
  Future<Response> _redeemEnrollmentCode(Request request) async {
    // Get client IP for rate limiting
    final clientIp = request.headers['x-forwarded-for']?.split(',').first.trim() ??
        request.headers['x-real-ip'] ??
        'unknown';

    // Check rate limit (5 attempts per minute per IP)
    if (redis != null) {
      final rateLimitKey = RedisService.enrollmentRedeemKey(clientIp);
      final rateLimitResult = await redis!.checkRateLimit(
        key: rateLimitKey,
        maxRequests: 5,
        windowSeconds: 60,
      );

      if (!rateLimitResult.allowed) {
        await logRepo.auditLog(
          actorType: 'system',
          actorId: 'rate_limiter',
          eventType: 'ENROLLMENT_RATE_LIMITED',
          resourceType: 'enrollment',
          details: {'ip_address': clientIp},
          ipAddress: clientIp,
        );

        return Response(429,
            body: jsonEncode({
              'error': 'rate_limited',
              'message': 'Too many enrollment attempts. Please try again later.',
              'retry_after': rateLimitResult.resetSeconds,
            }),
            headers: {
              'content-type': 'application/json',
              'Retry-After': rateLimitResult.resetSeconds.toString(),
              'X-RateLimit-Remaining': '0',
              'X-RateLimit-Reset': rateLimitResult.resetSeconds.toString(),
            });
      }
    }

    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final code = data['code'] as String?;
      final hardwareId = data['hardware_id'] as String?;
      final platform = data['platform'] as String?;
      final deviceName = data['device_name'] as String?;

      if (code == null || hardwareId == null) {
        return Response(400,
            body: jsonEncode({
              'error': 'invalid_request',
              'message': 'code and hardware_id are required',
            }),
            headers: {'content-type': 'application/json'});
      }

      // Validate the enrollment code
      final clientId = await clientService.validateEnrollmentCode(code);
      if (clientId == null) {
        return Response(400,
            body: jsonEncode({
              'error': 'invalid_code',
              'message': 'Invalid or expired enrollment code',
            }),
            headers: {'content-type': 'application/json'});
      }

      // Mark code as redeemed
      await clientService.redeemEnrollmentCode(code, hardwareId);

      // Update client with device info
      await clientService.updateClient(clientId, {
        'hardware_id': hardwareId,
        if (platform != null) 'platform': platform,
        if (deviceName != null) 'name': deviceName,
      });

      // Generate device token (JWT)
      final deviceToken = _generateDeviceToken(clientId, hardwareId);

      // Store token hash in client record
      final tokenHash = sha256.convert(utf8.encode(deviceToken)).toString();
      await clientRepo.updateDeviceTokenHash(clientId, tokenHash);

      // Get WireGuard config
      final config = await clientService.generateConfigFile(clientId);
      if (config == null) {
        return Response.internalServerError(
            body: jsonEncode({
              'error': 'config_generation_failed',
              'message': 'Failed to generate VPN configuration',
            }),
            headers: {'content-type': 'application/json'});
      }

      // Audit log
      await logRepo.auditLog(
        actorType: 'client',
        actorId: clientId,
        eventType: 'ENROLLMENT_CODE_REDEEMED',
        resourceType: 'client',
        resourceId: clientId,
        details: {
          'hardware_id': hardwareId,
          'platform': platform,
        },
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode({
          'device_token': deviceToken,
          'client_id': clientId,
          'config': config,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      await logRepo.errorLog(
        severity: 'ERROR',
        component: 'enrollment',
        message: 'Failed to redeem enrollment code: $e',
      );
      return Response.internalServerError(
        body: jsonEncode({
          'error': 'redemption_failed',
          'message': 'Failed to redeem enrollment code: $e',
        }),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Generate a device token (JWT) for API access
  String _generateDeviceToken(String clientId, String hardwareId) {
    final jwt = JWT({
      'sub': clientId,
      'type': 'device',
      'hardware_id': hardwareId,
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });

    // Device tokens don't expire (revocation is handled by token hash check)
    return jwt.sign(SecretKey(jwtSecret));
  }

  /// Get config for authenticated device
  /// GET /api/v1/enrollment/config
  Future<Response> _getConfig(Request request) async {
    try {
      final clientId = request.context['clientId'] as String?;
      if (clientId == null) {
        return Response(401,
            body: jsonEncode({'error': 'Device authentication required'}),
            headers: {'content-type': 'application/json'});
      }

      final config = await clientService.generateConfigFile(clientId);
      if (config == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Update last config fetch
      await clientService.updateLastConfigFetch(clientId);

      // Audit log
      await logRepo.auditLog(
        actorType: 'client',
        actorId: clientId,
        eventType: 'CONFIG_FETCHED',
        resourceType: 'client',
        resourceId: clientId,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        config,
        headers: {'content-type': 'text/plain'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get config: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Check config version for updates
  /// GET /api/v1/enrollment/config/version
  Future<Response> _getConfigVersion(Request request) async {
    try {
      final clientId = request.context['clientId'] as String?;
      if (clientId == null) {
        return Response(401,
            body: jsonEncode({'error': 'Device authentication required'}),
            headers: {'content-type': 'application/json'});
      }

      final client = await clientService.getClient(clientId);
      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Return a version based on updated_at timestamp
      final version = client.updatedAt.millisecondsSinceEpoch.toRadixString(16);

      return Response.ok(
        jsonEncode({
          'version': version,
          'status': client.status,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get config version: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Device heartbeat - report status and connection events
  /// POST /api/v1/enrollment/heartbeat
  ///
  /// Body (all fields optional):
  /// {
  ///   "event": "connected" | "disconnected" | "heartbeat",
  ///   "vpn_ip": "10.0.0.5",
  ///   "bytes_sent": 12345,
  ///   "bytes_received": 67890,
  ///   "client_version": "1.0.0",
  ///   "platform_version": "14.0",
  ///   "error_message": "Connection timeout"  // only for errors
  /// }
  Future<Response> _heartbeat(Request request) async {
    try {
      final clientId = request.context['clientId'] as String?;
      if (clientId == null) {
        return Response(401,
            body: jsonEncode({'error': 'Device authentication required'}),
            headers: {'content-type': 'application/json'});
      }

      final body = await request.readAsString();
      final data = body.isNotEmpty ? jsonDecode(body) as Map<String, dynamic> : <String, dynamic>{};

      // Get client info for event publishing
      final client = await clientService.getClient(clientId);
      final clientName = client?.name ?? 'Unknown';
      final sourceIp = request.headers['x-forwarded-for'] ??
                       request.headers['x-real-ip'] ??
                       'unknown';

      // Handle hostname lock enforcement
      final hostname = data['hostname'] as String?;
      if (hostname != null && hostname.isNotEmpty) {
        final storedHostname = await clientRepo.getHostname(clientId);
        if (storedHostname == null) {
          // First connection - lock the hostname
          await clientRepo.setHostnameIfEmpty(clientId, hostname);
          await logRepo.auditLog(
            actorType: 'client',
            actorId: clientId,
            eventType: 'HOSTNAME_LOCKED',
            resourceType: 'client',
            resourceId: clientId,
            resourceName: clientName,
            details: {'hostname': hostname},
            ipAddress: sourceIp,
          );
        } else if (storedHostname != hostname) {
          // Hostname mismatch - reject connection
          await logRepo.auditLog(
            actorType: 'client',
            actorId: clientId,
            eventType: 'HOSTNAME_MISMATCH',
            resourceType: 'client',
            resourceId: clientId,
            resourceName: clientName,
            details: {
              'expected_hostname': storedHostname,
              'received_hostname': hostname,
              'source_ip': sourceIp,
            },
            ipAddress: sourceIp,
          );
          return Response(403,
              body: jsonEncode({
                'error': 'hostname_mismatch',
                'message': 'This client is locked to a different device',
              }),
              headers: {'content-type': 'application/json'});
        }
      }

      // Parse event type (default to heartbeat)
      final event = data['event'] as String? ?? 'heartbeat';
      final vpnIp = data['vpn_ip'] as String?;
      final bytesSent = data['bytes_sent'] as int?;
      final bytesReceived = data['bytes_received'] as int?;

      // Update last seen
      await clientService.updateLastSeen(clientId);

      // Optionally update client info
      if (data.containsKey('client_version') || data.containsKey('platform_version')) {
        await clientService.updateClient(clientId, {
          if (data.containsKey('client_version'))
            'client_version': data['client_version'],
          if (data.containsKey('platform_version'))
            'platform_version': data['platform_version'],
        });
      }

      // Handle connection events
      switch (event) {
        case 'connected':
          await _handleConnected(
            clientId: clientId,
            clientName: clientName,
            sourceIp: sourceIp,
            vpnIp: vpnIp,
          );
          break;

        case 'disconnected':
          await _handleDisconnected(
            clientId: clientId,
            clientName: clientName,
            bytesSent: bytesSent,
            bytesReceived: bytesReceived,
            reason: data['error_message'] as String?,
          );
          break;

        case 'heartbeat':
        default:
          // Regular heartbeat - update online status in Redis
          await _updateOnlineStatus(
            clientId: clientId,
            clientName: clientName,
            vpnIp: vpnIp,
            bytesSent: bytesSent ?? 0,
            bytesReceived: bytesReceived ?? 0,
          );
          break;
      }

      return Response.ok(
        jsonEncode({'status': 'ok'}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Heartbeat failed: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Handle client connected event
  Future<void> _handleConnected({
    required String clientId,
    required String clientName,
    required String sourceIp,
    String? vpnIp,
  }) async {
    // Log connection start to database
    final connectionId = await logRepo.connectionStart(
      clientId: clientId,
      sourceIp: sourceIp,
    );
    _activeConnections[clientId] = connectionId;

    // Update Redis online status
    await _updateOnlineStatus(
      clientId: clientId,
      clientName: clientName,
      vpnIp: vpnIp,
      bytesSent: 0,
      bytesReceived: 0,
    );

    // Publish connection event to Redis
    if (redis != null) {
      await redis!.publish(RedisChannels.connections, {
        'event': 'connected',
        'client_id': clientId,
        'name': clientName,
        'vpn_ip': vpnIp,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Record metrics
      await redis!.incrementCounter(RedisMetrics.totalConnections);
      await redis!.recordMetric(
        RedisMetrics.connectionCount,
        (await redis!.getOnlineClientCount()).toDouble(),
      );
    }

    // Audit log
    await logRepo.auditLog(
      actorType: 'client',
      actorId: clientId,
      eventType: 'VPN_CONNECTED',
      resourceType: 'client',
      resourceId: clientId,
      resourceName: clientName,
      details: {'vpn_ip': vpnIp, 'source_ip': sourceIp},
    );
  }

  /// Handle client disconnected event
  Future<void> _handleDisconnected({
    required String clientId,
    required String clientName,
    int? bytesSent,
    int? bytesReceived,
    String? reason,
  }) async {
    // Log connection end to database
    final connectionId = _activeConnections.remove(clientId);
    if (connectionId != null) {
      await logRepo.connectionEnd(
        connectionId: connectionId,
        bytesSent: bytesSent,
        bytesReceived: bytesReceived,
        disconnectReason: reason,
      );
    }

    // Remove from Redis online set
    if (redis != null) {
      await redis!.setClientOffline(clientId);

      // Publish disconnection event
      await redis!.publish(RedisChannels.connections, {
        'event': 'disconnected',
        'client_id': clientId,
        'name': clientName,
        'reason': reason,
        'bytes_sent': bytesSent,
        'bytes_received': bytesReceived,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Record metrics
      await redis!.recordMetric(
        RedisMetrics.connectionCount,
        (await redis!.getOnlineClientCount()).toDouble(),
      );

      // Update bandwidth totals
      if (bytesSent != null) {
        await redis!.incrementCounter(RedisMetrics.totalBytesTx, amount: bytesSent);
      }
      if (bytesReceived != null) {
        await redis!.incrementCounter(RedisMetrics.totalBytesRx, amount: bytesReceived);
      }
    }

    // Audit log
    await logRepo.auditLog(
      actorType: 'client',
      actorId: clientId,
      eventType: 'VPN_DISCONNECTED',
      resourceType: 'client',
      resourceId: clientId,
      resourceName: clientName,
      details: {
        'reason': reason,
        'bytes_sent': bytesSent,
        'bytes_received': bytesReceived,
      },
    );
  }

  /// Update client online status in Redis
  Future<void> _updateOnlineStatus({
    required String clientId,
    required String clientName,
    String? vpnIp,
    required int bytesSent,
    required int bytesReceived,
  }) async {
    if (redis == null) return;

    await redis!.setClientOnline(clientId, {
      'name': clientName,
      'vpn_ip': vpnIp,
      'bytes_sent': bytesSent,
      'bytes_received': bytesReceived,
      'last_heartbeat': DateTime.now().toIso8601String(),
    });
  }
}
