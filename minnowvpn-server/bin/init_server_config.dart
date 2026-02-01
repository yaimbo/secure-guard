import 'package:dotenv/dotenv.dart';

import '../lib/src/database/database.dart';
import '../lib/src/repositories/server_config_repository.dart';
import '../lib/src/services/key_service.dart';

/// Initialize server configuration for development
Future<void> main() async {
  // Load environment variables
  final env = DotEnv(includePlatformEnvironment: true)..load();

  // Connect to database
  final db = Database(
    host: env['DB_HOST'] ?? 'localhost',
    port: int.parse(env['DB_PORT'] ?? '5432'),
    database: env['DB_NAME'] ?? 'secureguard',
    username: env['DB_USER'] ?? 'postgres',
    password: env['DB_PASSWORD'] ?? '',
  );

  // Check if already configured
  final serverConfigRepo = ServerConfigRepository(db);
  final existing = await serverConfigRepo.get();

  if (existing != null) {
    print('Server config already exists:');
    print('  Endpoint: ${existing.endpoint}');
    print('  Subnet: ${existing.ipSubnet}');
    print('  Public key: ${existing.publicKey}');
    await db.close();
    return;
  }

  // Generate server keys
  final keyService = KeyService(encryptionKey: env['ENCRYPTION_KEY']);
  final (privateKey, publicKey) = await keyService.generateKeyPair();
  final privateKeyEnc = await keyService.encryptPrivateKey(privateKey);

  // Create server config
  final config = await serverConfigRepo.upsert(
    privateKeyEnc: privateKeyEnc,
    publicKey: publicKey,
    endpoint: 'vpn.example.com:51820',
    listenPort: 51820,
    ipSubnet: '10.0.0.0/24',
    dnsServers: ['1.1.1.1', '8.8.8.8'],
    mtu: 1420,
  );

  print('Server config initialized:');
  print('  Endpoint: ${config.endpoint}');
  print('  Subnet: ${config.ipSubnet}');
  print('  Public key: ${config.publicKey}');

  await db.close();
}
