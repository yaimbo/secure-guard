import 'dart:convert';

import '../database/database.dart';
import '../models/server_config_model.dart';

/// Repository for server WireGuard configuration
class ServerConfigRepository {
  final Database db;

  ServerConfigRepository(this.db);

  /// Get the server config (singleton)
  Future<ServerConfigModel?> get() async {
    final result = await db.execute('SELECT * FROM server_config WHERE id = 1');
    if (result.isEmpty) return null;
    return ServerConfigModel.fromRow(result.first.toColumnMap());
  }

  /// Create or update server config
  Future<ServerConfigModel> upsert({
    required String privateKeyEnc,
    required String publicKey,
    required String endpoint,
    required int listenPort,
    required String ipSubnet,
    List<String>? dnsServers,
    int mtu = 1420,
  }) async {
    final privKeyBytes = base64Decode(privateKeyEnc);
    final pubKeyBytes = base64Decode(publicKey);

    final result = await db.execute('''
      INSERT INTO server_config (
        id, private_key_enc, public_key, endpoint, listen_port,
        ip_subnet, dns_servers, mtu
      ) VALUES (
        1, @private_key_enc, @public_key, @endpoint, @listen_port,
        @ip_subnet::cidr, @dns_servers::inet[], @mtu
      )
      ON CONFLICT (id) DO UPDATE SET
        private_key_enc = EXCLUDED.private_key_enc,
        public_key = EXCLUDED.public_key,
        endpoint = EXCLUDED.endpoint,
        listen_port = EXCLUDED.listen_port,
        ip_subnet = EXCLUDED.ip_subnet,
        dns_servers = EXCLUDED.dns_servers,
        mtu = EXCLUDED.mtu,
        updated_at = NOW()
      RETURNING *
    ''', {
      'private_key_enc': privKeyBytes,
      'public_key': pubKeyBytes,
      'endpoint': endpoint,
      'listen_port': listenPort,
      'ip_subnet': ipSubnet,
      'dns_servers': dnsServers != null ? '{${dnsServers.join(',')}}' : null,
      'mtu': mtu,
    });

    return ServerConfigModel.fromRow(result.first.toColumnMap());
  }

  /// Update just the endpoint
  Future<ServerConfigModel?> updateEndpoint(String endpoint) async {
    final result = await db.execute('''
      UPDATE server_config
      SET endpoint = @endpoint, updated_at = NOW()
      WHERE id = 1
      RETURNING *
    ''', {'endpoint': endpoint});

    if (result.isEmpty) return null;
    return ServerConfigModel.fromRow(result.first.toColumnMap());
  }

  /// Check if server config exists
  Future<bool> exists() async {
    final result = await db.execute(
      'SELECT COUNT(*) FROM server_config WHERE id = 1',
    );
    return (result.first[0] as int) > 0;
  }
}
