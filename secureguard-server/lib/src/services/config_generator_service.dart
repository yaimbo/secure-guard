/// Service for generating WireGuard configuration files
class ConfigGeneratorService {
  /// Generate a client WireGuard configuration file
  String generateClientConfig({
    required String privateKey,
    required String assignedIp,
    required String serverPublicKey,
    required String serverEndpoint,
    required List<String> allowedIps,
    List<String>? dnsServers,
    String? presharedKey,
    int? mtu,
  }) {
    final buffer = StringBuffer();

    // Interface section
    buffer.writeln('[Interface]');
    buffer.writeln('PrivateKey = $privateKey');
    buffer.writeln('Address = $assignedIp/24');

    if (dnsServers != null && dnsServers.isNotEmpty) {
      buffer.writeln('DNS = ${dnsServers.join(', ')}');
    }

    if (mtu != null) {
      buffer.writeln('MTU = $mtu');
    }

    buffer.writeln();

    // Peer section (the server)
    buffer.writeln('[Peer]');
    buffer.writeln('PublicKey = $serverPublicKey');

    if (presharedKey != null) {
      buffer.writeln('PresharedKey = $presharedKey');
    }

    buffer.writeln('Endpoint = $serverEndpoint');
    buffer.writeln('AllowedIPs = ${allowedIps.join(', ')}');
    buffer.writeln('PersistentKeepalive = 25');

    return buffer.toString();
  }

  /// Generate a server WireGuard configuration file
  String generateServerConfig({
    required String privateKey,
    required String address,
    required int listenPort,
    required List<PeerConfig> peers,
    int? mtu,
  }) {
    final buffer = StringBuffer();

    // Interface section
    buffer.writeln('[Interface]');
    buffer.writeln('PrivateKey = $privateKey');
    buffer.writeln('Address = $address');
    buffer.writeln('ListenPort = $listenPort');

    if (mtu != null) {
      buffer.writeln('MTU = $mtu');
    }

    // Peer sections
    for (final peer in peers) {
      buffer.writeln();
      buffer.writeln('[Peer]');
      buffer.writeln('PublicKey = ${peer.publicKey}');

      if (peer.presharedKey != null) {
        buffer.writeln('PresharedKey = ${peer.presharedKey}');
      }

      buffer.writeln('AllowedIPs = ${peer.allowedIps.join(', ')}');
    }

    return buffer.toString();
  }

  /// Generate config version hash for change detection
  String generateConfigVersion({
    required String privateKey,
    required String serverPublicKey,
    required String serverEndpoint,
    required List<String> allowedIps,
    String? presharedKey,
  }) {
    // Simple hash based on key values that would trigger a config update
    final content = [
      privateKey,
      serverPublicKey,
      serverEndpoint,
      allowedIps.join(','),
      presharedKey ?? '',
    ].join('|');

    // Simple hash (in production, use a proper hash function)
    var hash = 0;
    for (var i = 0; i < content.length; i++) {
      hash = ((hash << 5) - hash) + content.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF;
    }

    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// Configuration for a WireGuard peer
class PeerConfig {
  final String publicKey;
  final String? presharedKey;
  final List<String> allowedIps;

  PeerConfig({
    required this.publicKey,
    this.presharedKey,
    required this.allowedIps,
  });
}
