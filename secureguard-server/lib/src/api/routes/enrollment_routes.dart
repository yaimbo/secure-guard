import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../services/client_service.dart';
import '../../repositories/log_repository.dart';

/// Device enrollment routes (client-facing)
class EnrollmentRoutes {
  final ClientService clientService;
  final LogRepository logRepo;

  EnrollmentRoutes(this.clientService, this.logRepo);

  Router get router {
    final router = Router();

    router.post('/register', _registerDevice);
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

  /// Device heartbeat - report status
  /// POST /api/v1/enrollment/heartbeat
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
}
