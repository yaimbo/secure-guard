import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';

// Server config model
class ServerConfig {
  final String endpoint;
  final int port;
  final String subnet;
  final List<String> dnsServers;
  final int mtu;

  ServerConfig({
    required this.endpoint,
    required this.port,
    required this.subnet,
    required this.dnsServers,
    required this.mtu,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      endpoint: json['endpoint'] as String,
      port: json['listen_port'] as int,
      subnet: json['ip_subnet'] as String,
      dnsServers: (json['dns_servers'] as List?)?.cast<String>() ?? [],
      mtu: json['mtu'] as int? ?? 1420,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'endpoint': endpoint,
      'listen_port': port,
      'ip_subnet': subnet,
      'dns_servers': dnsServers,
      'mtu': mtu,
    };
  }
}

// Server config provider
final serverConfigProvider = FutureProvider<ServerConfig>((ref) async {
  final api = ref.read(apiServiceProvider);
  return api.getServerConfig();
});

// Admin user model
class AdminUser {
  final String id;
  final String email;
  final String role;
  final bool isActive;
  final DateTime? lastLoginAt;
  final DateTime createdAt;

  AdminUser({
    required this.id,
    required this.email,
    required this.role,
    required this.isActive,
    this.lastLoginAt,
    required this.createdAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) {
    return AdminUser(
      id: json['id'] as String,
      email: json['email'] as String,
      role: json['role'] as String,
      isActive: json['is_active'] as bool,
      lastLoginAt: json['last_login_at'] != null
          ? DateTime.parse(json['last_login_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

// Admin users provider
final adminUsersProvider = FutureProvider<List<AdminUser>>((ref) async {
  final api = ref.read(apiServiceProvider);
  return api.getAdminUsers();
});
