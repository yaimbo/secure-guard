import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../services/client_service.dart';
import '../../services/email_queue_service.dart';
import '../../repositories/log_repository.dart';

/// Client management routes (admin only)
class ClientRoutes {
  final ClientService clientService;
  final LogRepository logRepo;
  final EmailQueueService? emailQueueService;
  final String serverDomain;

  ClientRoutes(
    this.clientService,
    this.logRepo, {
    this.emailQueueService,
    this.serverDomain = '',
  });

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

    // Enrollment code management
    router.get('/<id>/enrollment-code', _getEnrollmentCode);
    router.post('/<id>/enrollment-code', _generateEnrollmentCode);
    router.delete('/<id>/enrollment-code', _revokeEnrollmentCode);

    // Email sending
    router.post('/<id>/send-enrollment-email', _sendEnrollmentEmail);

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

      // Generate enrollment code for the new client
      final enrollmentCode = await clientService.generateEnrollmentCode(client.id);

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

      // Return client with enrollment code
      final responseData = client.toJson();
      responseData['enrollment_code'] = enrollmentCode.toJson();

      return Response(201,
          body: jsonEncode(responseData),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      // Handle specific PostgreSQL errors with user-friendly messages
      final errorStr = e.toString();
      if (errorStr.contains('23505')) {
        // Unique constraint violation
        if (errorStr.contains('assigned_ip')) {
          return Response(409,
              body: jsonEncode({'error': 'No available IP addresses in the subnet. Please contact your administrator.'}),
              headers: {'content-type': 'application/json'});
        }
        if (errorStr.contains('name')) {
          return Response(409,
              body: jsonEncode({'error': 'A client with this name already exists'}),
              headers: {'content-type': 'application/json'});
        }
        return Response(409,
            body: jsonEncode({'error': 'A client with these details already exists'}),
            headers: {'content-type': 'application/json'});
      }
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to create client. Please try again.'}),
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
      final qrPng = await clientService.generateQrCode(id);

      if (qrPng == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      return Response.ok(
        qrPng,
        headers: {'content-type': 'image/png'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to generate QR code: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  // ============================================================
  // Enrollment Code Handlers
  // ============================================================

  Future<Response> _getEnrollmentCode(Request request, String id) async {
    try {
      final client = await clientService.getClient(id);
      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      final enrollmentCode = await clientService.getEnrollmentCode(id);

      if (enrollmentCode == null) {
        return Response(404,
            body: jsonEncode({
              'error': 'no_active_code',
              'message': 'No active enrollment code for this client',
            }),
            headers: {'content-type': 'application/json'});
      }

      return Response.ok(
        jsonEncode(enrollmentCode.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get enrollment code: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _generateEnrollmentCode(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final client = await clientService.getClient(id);
      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      final enrollmentCode = await clientService.generateEnrollmentCode(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'ENROLLMENT_CODE_GENERATED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        details: {'expires_at': enrollmentCode.expiresAt.toIso8601String()},
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode(enrollmentCode.toJson()),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to generate enrollment code: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  Future<Response> _revokeEnrollmentCode(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      final client = await clientService.getClient(id);
      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      await clientService.revokeEnrollmentCode(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'ENROLLMENT_CODE_REVOKED',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response(204);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to revoke enrollment code: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  // ============================================================
  // Email Sending
  // ============================================================

  Future<Response> _sendEnrollmentEmail(Request request, String id) async {
    try {
      final adminId = request.context['adminId'] as String;

      // Check if email service is configured
      if (emailQueueService == null) {
        return Response(400,
            body: jsonEncode({
              'error': 'email_not_configured',
              'message': 'Email service is not configured',
            }),
            headers: {'content-type': 'application/json'});
      }

      final client = await clientService.getClient(id);
      if (client == null) {
        return Response(404,
            body: jsonEncode({'error': 'Client not found'}),
            headers: {'content-type': 'application/json'});
      }

      // Check if client has an email address
      if (client.userEmail == null || client.userEmail!.isEmpty) {
        return Response(400,
            body: jsonEncode({
              'error': 'no_email',
              'message': 'Client has no email address configured',
            }),
            headers: {'content-type': 'application/json'});
      }

      // Get or generate enrollment code
      var enrollmentCode = await clientService.getEnrollmentCode(id);
      if (enrollmentCode == null) {
        enrollmentCode = await clientService.generateEnrollmentCode(id);
      }

      // Calculate remaining time
      final expiresIn = _formatExpiresIn(enrollmentCode.expiresAt);

      // Queue the email
      final jobId = await emailQueueService!.queueEnrollmentEmail(
        toEmail: client.userEmail!,
        toName: client.userName ?? client.name,
        enrollmentCode: enrollmentCode.formattedCode,
        deepLink: enrollmentCode.deepLink,
        serverDomain: serverDomain,
        expiresIn: expiresIn,
      );

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'ENROLLMENT_EMAIL_SENT',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        details: {
          'to_email': client.userEmail,
          'job_id': jobId,
        },
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      return Response.ok(
        jsonEncode({
          'status': 'queued',
          'job_id': jobId,
          'to_email': client.userEmail,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to send enrollment email: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Format expiration time in a human-readable format
  String _formatExpiresIn(DateTime expiresAt) {
    final now = DateTime.now();
    final difference = expiresAt.difference(now);

    if (difference.inHours >= 24) {
      final days = difference.inDays;
      return '$days day${days > 1 ? 's' : ''}';
    } else if (difference.inHours >= 1) {
      final hours = difference.inHours;
      return '$hours hour${hours > 1 ? 's' : ''}';
    } else if (difference.inMinutes >= 1) {
      final minutes = difference.inMinutes;
      return '$minutes minute${minutes > 1 ? 's' : ''}';
    } else {
      return 'less than a minute';
    }
  }
}
