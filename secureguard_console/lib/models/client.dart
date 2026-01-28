class Client {
  final String id;
  final String name;
  final String? description;
  final String? userEmail;
  final String? userName;
  final String assignedIp;
  final String status;
  final String? platform;
  final String? clientVersion;
  final DateTime? lastSeenAt;
  final DateTime? lastConfigFetch;
  final DateTime createdAt;
  final DateTime updatedAt;

  Client({
    required this.id,
    required this.name,
    this.description,
    this.userEmail,
    this.userName,
    required this.assignedIp,
    required this.status,
    this.platform,
    this.clientVersion,
    this.lastSeenAt,
    this.lastConfigFetch,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Client.fromJson(Map<String, dynamic> json) {
    return Client(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      userEmail: json['user_email'] as String?,
      userName: json['user_name'] as String?,
      assignedIp: json['assigned_ip'] as String,
      status: json['status'] as String,
      platform: json['platform'] as String?,
      clientVersion: json['client_version'] as String?,
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.parse(json['last_seen_at'] as String)
          : null,
      lastConfigFetch: json['last_config_fetch'] != null
          ? DateTime.parse(json['last_config_fetch'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'user_email': userEmail,
      'user_name': userName,
      'assigned_ip': assignedIp,
      'status': status,
      'platform': platform,
      'client_version': clientVersion,
      'last_seen_at': lastSeenAt?.toIso8601String(),
      'last_config_fetch': lastConfigFetch?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Client copyWith({
    String? id,
    String? name,
    String? description,
    String? userEmail,
    String? userName,
    String? assignedIp,
    String? status,
    String? platform,
    String? clientVersion,
    DateTime? lastSeenAt,
    DateTime? lastConfigFetch,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Client(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      userEmail: userEmail ?? this.userEmail,
      userName: userName ?? this.userName,
      assignedIp: assignedIp ?? this.assignedIp,
      status: status ?? this.status,
      platform: platform ?? this.platform,
      clientVersion: clientVersion ?? this.clientVersion,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastConfigFetch: lastConfigFetch ?? this.lastConfigFetch,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
