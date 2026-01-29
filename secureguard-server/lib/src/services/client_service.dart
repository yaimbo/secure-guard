import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';

import '../models/client.dart';
import '../repositories/client_repository.dart';
import '../repositories/server_config_repository.dart';
import 'config_generator_service.dart';
import 'key_service.dart';

/// Service for VPN client management
class ClientService {
  final ClientRepository clientRepo;
  final ServerConfigRepository serverConfigRepo;
  final KeyService keyService;
  final ConfigGeneratorService configGenerator;

  ClientService({
    required this.clientRepo,
    required this.serverConfigRepo,
    required this.keyService,
    required this.configGenerator,
  });

  /// List clients with pagination and filtering
  Future<Map<String, dynamic>> listClients({
    int page = 1,
    int limit = 50,
    String? status,
    String? search,
  }) {
    return clientRepo.list(
      page: page,
      limit: limit,
      status: status,
      search: search,
    );
  }

  /// Get a client by ID
  Future<Client?> getClient(String id) {
    return clientRepo.getById(id);
  }

  /// Get a client by hardware ID (for device enrollment)
  Future<Client?> getClientByHardwareId(String hardwareId) {
    return clientRepo.getByHardwareId(hardwareId);
  }

  /// Create a new client with auto-generated keys
  Future<Client> createClient({
    required String name,
    String? description,
    String? userEmail,
    String? userName,
    List<String>? allowedIps,
    String? platform,
    String? hardwareId,
  }) async {
    // Get server config for subnet
    final serverConfig = await serverConfigRepo.get();
    if (serverConfig == null) {
      throw Exception('Server configuration not initialized');
    }

    // Generate key pair
    final (privateKey, publicKey) = await keyService.generateKeyPair();

    // Encrypt private key for storage
    final privateKeyEnc = await keyService.encryptPrivateKey(privateKey);

    // Generate optional preshared key
    final presharedKey = await keyService.generatePresharedKey();

    // Get next available IP address
    final assignedIp = await clientRepo.getNextAvailableIp(serverConfig.ipSubnet);

    return clientRepo.create(
      name: name,
      description: description,
      userEmail: userEmail,
      userName: userName,
      publicKey: publicKey,
      privateKeyEnc: privateKeyEnc,
      presharedKey: presharedKey,
      assignedIp: assignedIp,
      allowedIps: allowedIps,
      platform: platform,
      hardwareId: hardwareId,
    );
  }

  /// Update a client
  Future<Client?> updateClient(String id, Map<String, dynamic> data) {
    return clientRepo.update(id, data);
  }

  /// Set client status (enable/disable)
  Future<Client?> setClientStatus(String id, String status) {
    return clientRepo.setStatus(id, status);
  }

  /// Regenerate client keys
  Future<Client?> regenerateKeys(String id) async {
    final client = await clientRepo.getById(id);
    if (client == null) return null;

    // Generate new key pair
    final (privateKey, publicKey) = await keyService.generateKeyPair();

    // Encrypt private key
    final privateKeyEnc = await keyService.encryptPrivateKey(privateKey);

    // Generate new preshared key
    final presharedKey = await keyService.generatePresharedKey();

    return clientRepo.updateKeys(
      id,
      publicKey: publicKey,
      privateKeyEnc: privateKeyEnc,
      presharedKey: presharedKey,
    );
  }

  /// Delete a client
  Future<bool> deleteClient(String id) {
    return clientRepo.delete(id);
  }

  /// Generate WireGuard config file content for a client
  Future<String?> generateConfigFile(String id) async {
    final client = await clientRepo.getById(id);
    if (client == null) return null;

    final serverConfig = await serverConfigRepo.get();
    if (serverConfig == null) {
      throw Exception('Server configuration not initialized');
    }

    // Decrypt private key
    final privateKey = await keyService.decryptPrivateKey(client.privateKeyEnc);

    return configGenerator.generateClientConfig(
      privateKey: privateKey,
      assignedIp: client.assignedIp,
      serverPublicKey: serverConfig.publicKey,
      serverEndpoint: serverConfig.endpoint,
      allowedIps: client.allowedIps,
      dnsServers: serverConfig.dnsServers,
      presharedKey: client.presharedKey,
      mtu: serverConfig.mtu,
    );
  }

  /// Generate QR code PNG image for a client config
  Future<Uint8List?> generateQrCode(String id) async {
    final config = await generateConfigFile(id);
    if (config == null) return null;

    // Generate QR code matrix
    final qrCode = QrCode.fromData(
      data: config,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );

    // Create QrImage for rendering (provides isDark method)
    final qrImage = QrImage(qrCode);

    // Render to PNG image
    final moduleCount = qrImage.moduleCount;
    const scale = 8; // pixels per module
    const margin = 4; // modules of margin
    final size = (moduleCount + margin * 2) * scale;

    final image = img.Image(width: size, height: size);

    // Fill white background
    img.fill(image, color: img.ColorRgb8(255, 255, 255));

    // Draw QR modules
    for (var y = 0; y < moduleCount; y++) {
      for (var x = 0; x < moduleCount; x++) {
        if (qrImage.isDark(y, x)) {
          final px = (x + margin) * scale;
          final py = (y + margin) * scale;
          img.fillRect(
            image,
            x1: px,
            y1: py,
            x2: px + scale,
            y2: py + scale,
            color: img.ColorRgb8(0, 0, 0),
          );
        }
      }
    }

    // Encode to PNG
    return Uint8List.fromList(img.encodePng(image));
  }

  /// Update last seen timestamp (called from heartbeat)
  Future<void> updateLastSeen(String id) {
    return clientRepo.updateLastSeen(id);
  }

  /// Update last config fetch timestamp
  Future<void> updateLastConfigFetch(String id) {
    return clientRepo.updateLastConfigFetch(id);
  }

  /// Get stats for dashboard
  Future<Map<String, dynamic>> getStats() async {
    final totalCount = await clientRepo.getTotalCount();
    final activeCount = await clientRepo.getActiveCount();

    return {
      'total_clients': totalCount,
      'active_clients': activeCount,
      'disabled_clients': totalCount - activeCount,
    };
  }
}
