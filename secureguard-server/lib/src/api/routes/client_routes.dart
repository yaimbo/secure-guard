import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../services/client_service.dart';
import '../../repositories/log_repository.dart';

/// Client management routes (admin only)
class ClientRoutes {
  final ClientService clientService;
  final LogRepository logRepo;

  ClientRoutes(this.clientService, this.logRepo);

  Router get router {
    final router = Router();

    router.get('/', _listClients);
    router.post('/', _createClient);
    router.get('/<id>', _getClient);
    router.put('/<id>', _updateClient);
    router.delete('/<id>', _deleteClient);
    router.post('/<id>/enable', _enableClient);
    router.post('/<id>/disable', _disableClient);
    router.post('/<id>/regenerate-keys', _regenerateKeys);
    router.get('/<id>/config', _downloadConfig);
    router.get('/<id>/qr', _getQrCode);

    return router;
  }

  Future<Response> _listClients(Request request) async {
    try {
      final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
      final limit = int.tryParse(request.url.queryParameters['limit'] ?? '50') ?? 50;
      final status = request.url.queryParameters['status'];
      final search = request.url.queryParameters['search'];

      final result = await clientService.listClients(
        page: page,
        limit: limit,
        status: status,
        search: search,
      );

      return Response.ok(
        jsonEncode(result),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to list clients: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _createClient(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final adminId = request.context['adminId'] as String;

      final client = await clientService.createClient(
        name: data['name'] as String,
        description: data['description'] as String?,
        userEmail: data['user_email'] as String?,
        userName: data['user_name'] as String?,
        allowedIps: (data['allowed_ips'] as List<dynamic>?)?.cast<String>(),
      );

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_CREATED',
        resourceType: 'client',
        resourceId: client.id,
        resourceName: client.name,
        details: {'name': client.name, 'ip': client.assignedIp},
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(201,
          body: jsonEncode(client.toJson()),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to create client: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _getClient(Request request, String id) async {
    try {
      final client = await clientService.getClient(id);

      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      return Response.ok(
        jsonEncode(client.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get client: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _updateClient(Request request, String id) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final adminId = request.context['adminId'] as String;

      final client = await clientService.updateClient(id, data);

      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_UPDATED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        details: data,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode(client.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to update client: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _deleteClient(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final client = await clientService.getClient(id);
      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      await clientService.deleteClient(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_DELETED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(204);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to delete client: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _enableClient(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final client = await clientService.setClientStatus(id, 'active');

      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_ENABLED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode(client.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to enable client: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _disableClient(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final client = await clientService.setClientStatus(id, 'disabled');

      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_DISABLED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode(client.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to disable client: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _regenerateKeys(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final client = await clientService.regenerateKeys(id);

      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_KEYS_REGENERATED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode(client.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to regenerate keys: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _downloadConfig(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final config = await clientService.generateConfigFile(id);

      if (config == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      final client = await clientService.getClient(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CONFIG_DOWNLOADED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client?.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        config,
        headers: {
          'content-type': 'text/plain',
          'content-disposition': 'attachment; filename="${client?.name ?? id}.conf"',
        },
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to generate config: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _getQrCode(Request request, String id) async {
    try {
      final qrData = await clientService.generateQrCode(id);

      if (qrData == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      return Response.ok(
        jsonEncode({'qr_data': qrData}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to generate QR code: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }
}
