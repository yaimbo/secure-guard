import 'dart:convert';

import '../database/database.dart';
import '../models/client.dart';

/// Repository for VPN client data access
class ClientRepository {
  final Database db;

  ClientRepository(this.db);

  /// List clients with pagination and filtering
  Future<Map<String, dynamic>> list({
    int page = 1,
    int limit = 50,
    String? status,
    String? search,
  }) async {
    final offset = (page - 1) * limit;

    var whereClauses = <String>[];
    var whereParams = <String, dynamic>{};

    if (status != null) {
      whereClauses.add('status = @status');
      whereParams['status'] = status;
    }

    if (search != null && search.isNotEmpty) {
      whereClauses.add('(name ILIKE @search OR user_email ILIKE @search OR user_name ILIKE @search)');
      whereParams['search'] = '%$search%';
    }

    final whereClause =
        whereClauses.isEmpty ? '' : 'WHERE ${whereClauses.join(' AND ')}';

    // Get total count (only pass where params, not limit/offset)
    final countResult = await db.execute(
      'SELECT COUNT(*) FROM clients $whereClause',
      whereParams.isEmpty ? null : whereParams,
    );
    final total = countResult.first[0] as int;

    // Get page of clients (include limit and offset)
    final queryParams = <String, dynamic>{
      ...whereParams,
      'limit': limit,
      'offset': offset,
    };

    final result = await db.execute('''
      SELECT * FROM clients
      $whereClause
      ORDER BY created_at DESC
      LIMIT @limit OFFSET @offset
    ''', queryParams);

    final clients = result.map((row) => Client.fromRow(row.toColumnMap())).toList();

    return {
      'clients': clients.map((c) => c.toJson()).toList(),
      'pagination': {
        'page': page,
        'limit': limit,
        'total': total,
        'total_pages': (total / limit).ceil(),
      },
    };
  }

  /// Get client by ID
  Future<Client?> getById(String id) async {
    final result = await db.execute(
      'SELECT * FROM clients WHERE id = @id',
      {'id': id},
    );

    if (result.isEmpty) return null;
    return Client.fromRow(result.first.toColumnMap());
  }

  /// Get client by public key
  Future<Client?> getByPublicKey(String publicKey) async {
    final keyBytes = base64Decode(publicKey);
    final result = await db.execute(
      'SELECT * FROM clients WHERE public_key = @key',
      {'key': keyBytes},
    );

    if (result.isEmpty) return null;
    return Client.fromRow(result.first.toColumnMap());
  }

  /// Get client by hardware ID
  Future<Client?> getByHardwareId(String hardwareId) async {
    final result = await db.execute(
      'SELECT * FROM clients WHERE hardware_id = @hardware_id',
      {'hardware_id': hardwareId},
    );

    if (result.isEmpty) return null;
    return Client.fromRow(result.first.toColumnMap());
  }

  /// Create a new client
  Future<Client> create({
    required String name,
    String? description,
    String? userEmail,
    String? userName,
    required String publicKey,
    required String privateKeyEnc,
    String? presharedKey,
    required String assignedIp,
    List<String>? allowedIps,
    String? platform,
    String? hardwareId,
  }) async {
    final pubKeyBytes = base64Decode(publicKey);
    final privKeyBytes = base64Decode(privateKeyEnc);
    final pskBytes = presharedKey != null ? base64Decode(presharedKey) : null;

    final result = await db.execute('''
      INSERT INTO clients (
        name, description, user_email, user_name,
        public_key, private_key_enc, preshared_key,
        assigned_ip, allowed_ips, platform, hardware_id
      ) VALUES (
        @name, @description, @user_email, @user_name,
        @public_key, @private_key_enc, @preshared_key,
        @assigned_ip::inet, @allowed_ips::inet[], @platform, @hardware_id
      )
      RETURNING *
    ''', {
      'name': name,
      'description': description,
      'user_email': userEmail,
      'user_name': userName,
      'public_key': pubKeyBytes,
      'private_key_enc': privKeyBytes,
      'preshared_key': pskBytes,
      'assigned_ip': assignedIp,
      'allowed_ips': allowedIps != null ? '{${allowedIps.join(',')}}' : '{10.0.0.0/24}',
      'platform': platform,
      'hardware_id': hardwareId,
    });

    return Client.fromRow(result.first.toColumnMap());
  }

  /// Update a client
  Future<Client?> update(String id, Map<String, dynamic> data) async {
    final setClauses = <String>[];
    final params = <String, dynamic>{'id': id};

    final allowedFields = [
      'name',
      'description',
      'user_email',
      'user_name',
      'status',
      'platform',
      'platform_version',
      'client_version',
      'hardware_id',
    ];

    for (final field in allowedFields) {
      if (data.containsKey(field)) {
        setClauses.add('$field = @$field');
        params[field] = data[field];
      }
    }

    if (data.containsKey('allowed_ips')) {
      setClauses.add('allowed_ips = @allowed_ips::inet[]');
      params['allowed_ips'] = '{${(data['allowed_ips'] as List).join(',')}}';
    }

    if (setClauses.isEmpty) return getById(id);

    setClauses.add('updated_at = NOW()');

    final result = await db.execute('''
      UPDATE clients
      SET ${setClauses.join(', ')}
      WHERE id = @id
      RETURNING *
    ''', params);

    if (result.isEmpty) return null;
    return Client.fromRow(result.first.toColumnMap());
  }

  /// Set client status
  Future<Client?> setStatus(String id, String status) async {
    final result = await db.execute('''
      UPDATE clients
      SET status = @status, updated_at = NOW()
      WHERE id = @id
      RETURNING *
    ''', {'id': id, 'status': status});

    if (result.isEmpty) return null;
    return Client.fromRow(result.first.toColumnMap());
  }

  /// Update client keys
  Future<Client?> updateKeys(
    String id, {
    required String publicKey,
    required String privateKeyEnc,
    String? presharedKey,
  }) async {
    final pubKeyBytes = base64Decode(publicKey);
    final privKeyBytes = base64Decode(privateKeyEnc);
    final pskBytes = presharedKey != null ? base64Decode(presharedKey) : null;

    final result = await db.execute('''
      UPDATE clients
      SET public_key = @public_key,
          private_key_enc = @private_key_enc,
          preshared_key = @preshared_key,
          updated_at = NOW()
      WHERE id = @id
      RETURNING *
    ''', {
      'id': id,
      'public_key': pubKeyBytes,
      'private_key_enc': privKeyBytes,
      'preshared_key': pskBytes,
    });

    if (result.isEmpty) return null;
    return Client.fromRow(result.first.toColumnMap());
  }

  /// Update last seen timestamp
  Future<void> updateLastSeen(String id) async {
    await db.execute('''
      UPDATE clients SET last_seen_at = NOW() WHERE id = @id
    ''', {'id': id});
  }

  /// Update last config fetch timestamp
  Future<void> updateLastConfigFetch(String id) async {
    await db.execute('''
      UPDATE clients SET last_config_fetch = NOW() WHERE id = @id
    ''', {'id': id});
  }

  /// Update device token hash (for enrollment/authentication)
  Future<void> updateDeviceTokenHash(String id, String tokenHash) async {
    await db.execute('''
      UPDATE clients
      SET device_token_hash = @token_hash, updated_at = NOW()
      WHERE id = @id
    ''', {'id': id, 'token_hash': tokenHash});
  }

  /// Verify device token hash matches stored hash
  Future<bool> verifyDeviceTokenHash(String id, String tokenHash) async {
    final result = await db.execute('''
      SELECT device_token_hash FROM clients WHERE id = @id
    ''', {'id': id});

    if (result.isEmpty) return false;
    final storedHash = result.first[0] as String?;
    return storedHash == tokenHash;
  }

  /// Delete a client
  Future<bool> delete(String id) async {
    final result = await db.execute(
      'DELETE FROM clients WHERE id = @id',
      {'id': id},
    );
    return result.affectedRows > 0;
  }

  /// Get the next available IP address in subnet
  Future<String> getNextAvailableIp(String subnet) async {
    // Parse subnet (e.g., "10.0.0.0/24")
    final parts = subnet.split('/');
    final baseIp = parts[0];
    final baseParts = baseIp.split('.').map(int.parse).toList();

    // Find used IPs
    final result = await db.execute('''
      SELECT assigned_ip FROM clients
      WHERE assigned_ip << @subnet::inet
      ORDER BY assigned_ip
    ''', {'subnet': subnet});

    final usedIps = result.map((r) => r[0] as String).toSet();

    // Find first available (skip .0 and .1 - usually reserved for gateway)
    for (var i = 2; i < 255; i++) {
      final ip = '${baseParts[0]}.${baseParts[1]}.${baseParts[2]}.$i';
      if (!usedIps.contains(ip)) {
        return ip;
      }
    }

    throw Exception('No available IP addresses in subnet $subnet');
  }

  /// Get active client count
  Future<int> getActiveCount() async {
    final result = await db.execute(
      "SELECT COUNT(*) FROM clients WHERE status = 'active'",
    );
    return result.first[0] as int;
  }

  /// Get total client count
  Future<int> getTotalCount() async {
    final result = await db.execute('SELECT COUNT(*) FROM clients');
    return result.first[0] as int;
  }
}
