import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../database/database.dart';

/// Client update routes (for auto-update functionality)
class UpdateRoutes {
  final Database db;

  UpdateRoutes(this.db);

  /// Public routes (no auth required)
  Router get router {
    final router = Router();

    router.get('/manifest', _getManifest);
    router.get('/check', _checkForUpdates);
    router.get('/download/<version>/<platform>', _downloadBinary);

    return router;
  }

  /// Admin routes (require admin auth)
  Router get adminRouter {
    final router = Router();

    router.post('/', _createRelease);
    router.get('/', _listReleases);
    router.delete('/<id>', _deleteRelease);

    return router;
  }

  /// Get full update manifest
  /// GET /api/v1/updates/manifest
  Future<Response> _getManifest(Request request) async {
    try {
      final result = await db.execute('''
        SELECT version, platform, architecture, download_url, signature,
               sha256_hash, file_size, release_notes, is_mandatory, published_at
        FROM client_releases
        ORDER BY published_at DESC
      ''');

      final releases = result.map((row) => row.toColumnMap()).toList();

      return Response.ok(
        jsonEncode({'releases': releases}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get manifest: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Check for updates for specific platform
  /// GET /api/v1/updates/check?platform=windows&arch=x64&version=1.0.0
  Future<Response> _checkForUpdates(Request request) async {
    try {
      final params = request.url.queryParameters;
      final platform = params['platform'];
      final arch = params['arch'] ?? 'x64';
      final currentVersion = params['version'];

      if (platform == null || currentVersion == null) {
        return Response(400,
            body: jsonEncode({'error': 'platform and version are required'}),
            headers: {'content-type': 'application/json'});
      }

      // Get latest release for this platform/arch
      final result = await db.execute('''
        SELECT version, download_url, signature, sha256_hash, file_size,
               release_notes, is_mandatory, published_at
        FROM client_releases
        WHERE platform = @platform AND architecture = @arch
        ORDER BY published_at DESC
        LIMIT 1
      ''', {'platform': platform, 'arch': arch});

      if (result.isEmpty) {
        return Response.ok(
          jsonEncode({
            'update_available': false,
            'message': 'No releases available for $platform/$arch',
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      final latest = result.first.toColumnMap();
      final latestVersion = latest['version'] as String;

      // Simple version comparison (could be improved)
      final updateAvailable = _compareVersions(latestVersion, currentVersion) > 0;

      if (!updateAvailable) {
        return Response.ok(
          jsonEncode({
            'update_available': false,
            'current_version': currentVersion,
            'latest_version': latestVersion,
          }),
          headers: {'content-type': 'application/json'},
        );
      }

      return Response.ok(
        jsonEncode({
          'update_available': true,
          'current_version': currentVersion,
          'version': latestVersion,
          'mandatory': latest['is_mandatory'] ?? false,
          'download_url': latest['download_url'],
          'signature': latest['signature'],
          'sha256': latest['sha256_hash'],
          'file_size': latest['file_size'],
          'release_notes': latest['release_notes'],
          'published_at': (latest['published_at'] as DateTime).toIso8601String(),
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to check for updates: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Download binary (redirect or proxy)
  /// GET /api/v1/updates/download/:version/:platform
  Future<Response> _downloadBinary(
      Request request, String version, String platform) async {
    try {
      final arch = request.url.queryParameters['arch'] ?? 'x64';

      final result = await db.execute('''
        SELECT download_url FROM client_releases
        WHERE version = @version AND platform = @platform AND architecture = @arch
      ''', {'version': version, 'platform': platform, 'arch': arch});

      if (result.isEmpty) {
        return Response(404,
            body: jsonEncode({'error': 'Release not found'}),
            headers: {'content-type': 'application/json'});
      }

      final downloadUrl = result.first[0] as String;

      // Redirect to actual download location
      return Response(302, headers: {'location': downloadUrl});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to get download: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Create a new release (admin)
  /// POST /api/v1/updates/releases
  Future<Response> _createRelease(Request request) async {
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final requiredFields = [
        'version',
        'platform',
        'architecture',
        'download_url',
        'signature',
        'sha256_hash',
        'file_size'
      ];

      for (final field in requiredFields) {
        if (!data.containsKey(field)) {
          return Response(400,
              body: jsonEncode({'error': 'Missing required field: $field'}),
              headers: {'content-type': 'application/json'});
        }
      }

      final result = await db.execute('''
        INSERT INTO client_releases (
          version, platform, architecture, download_url, signature,
          sha256_hash, file_size, release_notes, is_mandatory
        ) VALUES (
          @version, @platform, @architecture, @download_url, @signature,
          @sha256_hash, @file_size, @release_notes, @is_mandatory
        )
        RETURNING *
      ''', {
        'version': data['version'],
        'platform': data['platform'],
        'architecture': data['architecture'],
        'download_url': data['download_url'],
        'signature': data['signature'],
        'sha256_hash': data['sha256_hash'],
        'file_size': data['file_size'],
        'release_notes': data['release_notes'],
        'is_mandatory': data['is_mandatory'] ?? false,
      });

      return Response(201,
          body: jsonEncode(result.first.toColumnMap()),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to create release: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// List all releases (admin)
  /// GET /api/v1/updates/releases
  Future<Response> _listReleases(Request request) async {
    try {
      final result = await db.execute('''
        SELECT * FROM client_releases ORDER BY published_at DESC
      ''');

      final releases = result.map((row) => row.toColumnMap()).toList();

      return Response.ok(
        jsonEncode({'releases': releases}),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to list releases: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Delete a release (admin)
  /// DELETE /api/v1/updates/releases/:id
  Future<Response> _deleteRelease(Request request, String id) async {
    try {
      final result = await db.execute(
        'DELETE FROM client_releases WHERE id = @id::uuid',
        {'id': id},
      );

      if (result.affectedRows == 0) {
        return Response(404,
            body: jsonEncode({'error': 'Release not found'}),
            headers: {'content-type': 'application/json'});
      }

      return Response(204);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to delete release: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }
  }

  /// Compare semantic versions
  /// Returns: positive if a > b, negative if a < b, 0 if equal
  int _compareVersions(String a, String b) {
    final partsA = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final partsB = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    // Pad to same length
    while (partsA.length < 3) {
      partsA.add(0);
    }
    while (partsB.length < 3) {
      partsB.add(0);
    }

    for (var i = 0; i < 3; i++) {
      if (partsA[i] > partsB[i]) return 1;
      if (partsA[i] < partsB[i]) return -1;
    }

    return 0;
  }
}
