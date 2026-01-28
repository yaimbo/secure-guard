import 'dart:convert';
import 'dart:typed_data';

/// Server WireGuard configuration model
class ServerConfigModel {
  final String privateKeyEnc; // Encrypted at rest
  final String publicKey;
  final String endpoint;
  final int listenPort;
  final String ipSubnet;
  final List<String>? dnsServers;
  final int mtu;
  final DateTime updatedAt;

  ServerConfigModel({
    required this.privateKeyEnc,
    required this.publicKey,
    required this.endpoint,
    required this.listenPort,
    required this.ipSubnet,
    this.dnsServers,
    required this.mtu,
    required this.updatedAt,
  });

  factory ServerConfigModel.fromRow(Map<String, dynamic> row) {
    return ServerConfigModel(
      privateKeyEnc: _bytesToBase64(row['private_key_enc']),
      publicKey: _bytesToBase64(row['public_key']),
      endpoint: row['endpoint'] as String,
      listenPort: row['listen_port'] as int,
      ipSubnet: row['ip_subnet'] as String,
      dnsServers: _parseInetArray(row['dns_servers']),
      mtu: row['mtu'] as int,
      updatedAt: row['updated_at'] as DateTime,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'public_key': publicKey,
      'endpoint': endpoint,
      'listen_port': listenPort,
      'ip_subnet': ipSubnet,
      'dns_servers': dnsServers,
      'mtu': mtu,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  static String _bytesToBase64(dynamic bytes) {
    if (bytes is Uint8List) {
      return base64Encode(bytes);
    } else if (bytes is List<int>) {
      return base64Encode(Uint8List.fromList(bytes));
    }
    return bytes.toString();
  }

  static List<String>? _parseInetArray(dynamic value) {
    if (value == null) return null;
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return null;
  }
}
