import '../database/postgres_utils.dart';

/// VPN client model
class Client {
  final String id;
  final String name;
  final String? description;
  final String? userEmail;
  final String? userName;
  final String? ssoProvider;
  final String? ssoSubject;

  // WireGuard keys (base64 encoded for JSON)
  final String publicKey;
  final String privateKeyEnc; // Encrypted at rest
  final String? presharedKey;

  // Network
  final String assignedIp;
  final List<String> allowedIps;

  // Device info
  final String? platform;
  final String? platformVersion;
  final String? clientVersion;
  final String? hardwareId;

  // Status
  final String status; // active, disabled, pending
  final DateTime? lastSeenAt;
  final DateTime? lastConfigFetch;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;

  Client({
    required this.id,
    required this.name,
    this.description,
    this.userEmail,
    this.userName,
    this.ssoProvider,
    this.ssoSubject,
    required this.publicKey,
    required this.privateKeyEnc,
    this.presharedKey,
    required this.assignedIp,
    required this.allowedIps,
    this.platform,
    this.platformVersion,
    this.clientVersion,
    this.hardwareId,
    required this.status,
    this.lastSeenAt,
    this.lastConfigFetch,
    required this.createdAt,
    required this.updatedAt,
    this.expiresAt,
  });

  factory Client.fromRow(Map<String, dynamic> row) {
    return Client(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String?,
      userEmail: row['user_email'] as String?,
      userName: row['user_name'] as String?,
      ssoProvider: row['sso_provider'] as String?,
      ssoSubject: row['sso_subject'] as String?,
      publicKey: bytesToBase64(row['public_key']),
      privateKeyEnc: bytesToBase64(row['private_key_enc']),
      presharedKey: row['preshared_key'] != null
          ? bytesToBase64(row['preshared_key'])
          : null,
      assignedIp: row['assigned_ip'] as String,
      allowedIps: parseInetArray(row['allowed_ips']),
      platform: row['platform'] as String?,
      platformVersion: row['platform_version'] as String?,
      clientVersion: row['client_version'] as String?,
      hardwareId: row['hardware_id'] as String?,
      status: row['status'] as String,
      lastSeenAt: row['last_seen_at'] as DateTime?,
      lastConfigFetch: row['last_config_fetch'] as DateTime?,
      createdAt: row['created_at'] as DateTime,
      updatedAt: row['updated_at'] as DateTime,
      expiresAt: row['expires_at'] as DateTime?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'user_email': userEmail,
      'user_name': userName,
      'sso_provider': ssoProvider,
      'public_key': publicKey,
      'assigned_ip': assignedIp,
      'allowed_ips': allowedIps,
      'platform': platform,
      'platform_version': platformVersion,
      'client_version': clientVersion,
      'status': status,
      'last_seen_at': lastSeenAt?.toIso8601String(),
      'last_config_fetch': lastConfigFetch?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
    };
  }

  /// Full JSON including private key (for config generation)
  Map<String, dynamic> toJsonWithPrivateKey() {
    final json = toJson();
    json['private_key'] = privateKeyEnc;
    json['preshared_key'] = presharedKey;
    return json;
  }

}
