import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

final _log = Logger('HTTP');

/// Middleware that logs all HTTP requests
Middleware requestLogger() {
  return (Handler innerHandler) {
    return (Request request) async {
      final stopwatch = Stopwatch()..start();

      Response response;
      try {
        response = await innerHandler(request);
      } catch (e) {
        stopwatch.stop();
        _log.warning(
          '${request.method} ${request.requestedUri.path} - ERROR (${stopwatch.elapsedMilliseconds}ms)',
        );
        rethrow;
      }

      stopwatch.stop();

      final statusCode = response.statusCode;
      final level = statusCode >= 500
          ? Level.SEVERE
          : statusCode >= 400
              ? Level.WARNING
              : Level.INFO;

      _log.log(
        level,
        '${request.method} ${request.requestedUri.path} - $statusCode (${stopwatch.elapsedMilliseconds}ms)',
      );

      return response;
    };
  };
}
