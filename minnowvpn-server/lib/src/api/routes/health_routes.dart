import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

/// Health check routes
class HealthRoutes {
  Router get router {
    final router = Router();

    router.get('/', _health);
    router.get('/ready', _ready);
    router.get('/live', _live);

    return router;
  }

  Response _health(Request request) {
    return Response.ok(
      jsonEncode({
        'status': 'healthy',
        'service': 'minnowvpn-api',
        'version': '0.1.0',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _ready(Request request) {
    // TODO: Check database and redis connectivity
    return Response.ok(
      jsonEncode({'ready': true}),
      headers: {'content-type': 'application/json'},
    );
  }

  Response _live(Request request) {
    return Response.ok(
      jsonEncode({'live': true}),
      headers: {'content-type': 'application/json'},
    );
  }
}
