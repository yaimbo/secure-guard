import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../services/client_service.dart';
import '../../services/email_queue_service.dart';
import '../../services/vpn_daemon_client.dart';
import '../../repositories/log_repository.dart';

/// Client management routes (admin only)
class ClientRoutes {
  final ClientService clientService;
  final LogRepository logRepo;
  final EmailQueueService? emailQueueService;
  final String serverDomain;

  /// Optional VPN daemon client for syncing peers
  /// If null, peer sync is skipped (daemon may not be running)
  final VpnDaemonClient? vpnDaemonClient;

  ClientRoutes(
    this.clientService,
    this.logRepo, {
    this.emailQueueService,
    this.serverDomain = '',
    this.vpnDaemonClient,
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

    // Security alerts
    router.get('/<id>/security-alerts', _getSecurityAlerts);

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
        severity: 'INFO',
        resourceType: 'client',
        resourceId: client.id,
        resourceName: client.name,
        details: {'name': client.name, 'ip': client.assignedIp},
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      // Sync peer to VPN daemon (best-effort)
      await _syncAddPeerToDaemon(
        client.publicKey,
        client.allowedIps,
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
        severity: 'INFO',
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

      // Remove peer from VPN daemon first (terminates active connection)
      await _syncRemovePeerFromDaemon(client.publicKey);

      await clientService.deleteClient(id);

      // Audit log
      await logRepo.auditLog(
        actorType: 'admin',
        actorId: adminId,
        eventType: 'CLIENT_DELETED',
        severity: 'ALERT',
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
        severity: 'INFO',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      // Add peer back to VPN daemon (allow new connections)
      await _syncAddPeerToDaemon(
        client.publicKey,
        client.allowedIps,
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
        severity: 'WARNING',
        resourceType: 'client',
        resourceId: id,
        resourceName: client.name,
        ipAddress: request.headers['x-forwarded-for'] ?? request.headers['x-real-ip'],
      );

      // Remove peer from VPN daemon (terminates active connection)
      await _syncRemovePeerFromDaemon(client.publicKey);

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
        severity: 'WARNING',
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
        severity: 'INFO',
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
        severity: 'INFO',
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
        severity: 'WARNING',
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
        severity: 'INFO',
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

  /// Get security alerts for a client (hostname mismatches, etc.)
  /// GET /api/v1/clients/:id/security-alerts
  Future<Response> _getSecurityAlerts(Request request, String id) async {
    try {
      // Query audit log for HOSTNAME_MISMATCH events for this client
      final result = await logRepo.queryAuditLog(
        resourceType: 'client',
        resourceId: id,
        eventType: 'HOSTNAME_MISMATCH',
        limit: 100,
      );

      final events = result['events'] as List;
      final count = events.length;

      return Response.ok(
        jsonEncode({
          'client_id': id,
          'alert_count': count,
          'alerts': events,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get security alerts: $e'}),
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

  // ============================================================
  // VPN Daemon Sync Helpers
  // ============================================================

  /// Sync peer addition to VPN daemon
  ///
  /// This is best-effort - if daemon isn't running, we log and continue.
  /// The daemon will load peers from database when it starts.
  Future<void> _syncAddPeerToDaemon(
    String publicKey,
    List<String> allowedIps, {
    String? presharedKey,
  }) async {
    if (vpnDaemonClient == null) return;

    try {
      if (!vpnDaemonClient!.isConnected) {
        await vpnDaemonClient!.connect();
      }

      await vpnDaemonClient!.addPeer(
        publicKey: publicKey,
        allowedIps: allowedIps,
        presharedKey: presharedKey,
      );
    } catch (e) {
      // Log but don't fail - daemon may not be running
      print('Warning: Could not sync peer to VPN daemon: $e');
    }
  }

  /// Sync peer removal to VPN daemon
  ///
  /// This is best-effort - if daemon isn't running, we log and continue.
  Future<void> _syncRemovePeerFromDaemon(String publicKey) async {
    if (vpnDaemonClient == null) return;

    try {
      if (!vpnDaemonClient!.isConnected) {
        await vpnDaemonClient!.connect();
      }

      await vpnDaemonClient!.removePeer(publicKey);
    } catch (e) {
      // Log but don't fail - daemon may not be running
      print('Warning: Could not remove peer from VPN daemon: $e');
    }
  }
}
