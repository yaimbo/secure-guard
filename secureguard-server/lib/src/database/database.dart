import 'package:postgres/postgres.dart';

/// Database connection manager for PostgreSQL
class Database {
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;

  Connection? _connection;

  Database({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
  });

  /// Get active connection, creating one if needed
  Future<Connection> get connection async {
    if (_connection == null || !_connection!.isOpen) {
      _connection = await Connection.open(
        Endpoint(
          host: host,
          port: port,
          database: database,
          username: username,
          password: password,
        ),
        settings: ConnectionSettings(
          sslMode: SslMode.prefer,
        ),
      );
    }
    return _connection!;
  }

  /// Execute a query with parameters
  Future<Result> execute(String sql, [Map<String, dynamic>? parameters]) async {
    final conn = await connection;
    return conn.execute(Sql.named(sql), parameters: parameters ?? {});
  }

  /// Close the connection
  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  /// Run database migrations
  Future<void> migrate() async {
    final conn = await connection;

    // Create migrations table if not exists
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS _migrations (
        id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL UNIQUE,
        applied_at TIMESTAMPTZ DEFAULT NOW()
      )
    ''');

    // Get applied migrations
    final applied = await conn.execute('SELECT name FROM _migrations');
    final appliedNames = applied.map((r) => r[0] as String).toSet();

    // Run pending migrations
    for (final migration in _migrations) {
      if (!appliedNames.contains(migration.name)) {
        print('Applying migration: ${migration.name}');
        await conn.execute(migration.sql);
        await conn.execute(
          Sql.named('INSERT INTO _migrations (name) VALUES (@name)'),
          parameters: {'name': migration.name},
        );
      }
    }
  }
}

class _Migration {
  final String name;
  final String sql;

  const _Migration(this.name, this.sql);
}

const _migrations = <_Migration>[
  _Migration('001_initial_schema', '''
    -- Server config (singleton)
    CREATE TABLE IF NOT EXISTS server_config (
      id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
      private_key_enc BYTEA NOT NULL,
      public_key BYTEA NOT NULL,
      endpoint VARCHAR(255) NOT NULL,
      listen_port INTEGER DEFAULT 51820,
      ip_subnet CIDR NOT NULL,
      dns_servers INET[],
      mtu INTEGER DEFAULT 1420,
      updated_at TIMESTAMPTZ DEFAULT NOW()
    );

    -- Admin users
    CREATE TABLE IF NOT EXISTS admins (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      email VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255),
      role VARCHAR(50) DEFAULT 'admin',
      sso_provider VARCHAR(50),
      sso_subject VARCHAR(255),
      is_active BOOLEAN DEFAULT true,
      last_login_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ DEFAULT NOW()
    );

    -- Clients (VPN devices)
    CREATE TABLE IF NOT EXISTS clients (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      user_email VARCHAR(255),
      user_name VARCHAR(255),
      sso_provider VARCHAR(50),
      sso_subject VARCHAR(255),

      -- WireGuard keys
      public_key BYTEA NOT NULL UNIQUE,
      private_key_enc BYTEA NOT NULL,
      preshared_key BYTEA,

      -- Network
      assigned_ip INET NOT NULL UNIQUE,
      allowed_ips INET[] DEFAULT ARRAY['10.0.0.0/24'::INET],

      -- Device info
      platform VARCHAR(50),
      platform_version VARCHAR(50),
      client_version VARCHAR(50),
      hardware_id VARCHAR(255),

      -- Status
      status VARCHAR(20) DEFAULT 'active',
      last_seen_at TIMESTAMPTZ,
      last_config_fetch TIMESTAMPTZ,

      created_at TIMESTAMPTZ DEFAULT NOW(),
      updated_at TIMESTAMPTZ DEFAULT NOW(),
      expires_at TIMESTAMPTZ
    );

    -- Audit log (append-only)
    CREATE TABLE IF NOT EXISTS audit_log (
      id BIGSERIAL PRIMARY KEY,
      timestamp TIMESTAMPTZ DEFAULT NOW(),
      actor_type VARCHAR(50) NOT NULL,
      actor_id UUID,
      actor_name VARCHAR(255),
      event_type VARCHAR(100) NOT NULL,
      resource_type VARCHAR(50),
      resource_id UUID,
      resource_name VARCHAR(255),
      details JSONB,
      ip_address INET,
      user_agent TEXT
    );

    -- Error log
    CREATE TABLE IF NOT EXISTS error_log (
      id BIGSERIAL PRIMARY KEY,
      timestamp TIMESTAMPTZ DEFAULT NOW(),
      severity VARCHAR(20) NOT NULL,
      component VARCHAR(100) NOT NULL,
      client_id UUID REFERENCES clients(id),
      message TEXT NOT NULL,
      stack_trace TEXT,
      details JSONB
    );

    -- Connection log
    CREATE TABLE IF NOT EXISTS connection_log (
      id BIGSERIAL PRIMARY KEY,
      client_id UUID NOT NULL REFERENCES clients(id),
      connected_at TIMESTAMPTZ NOT NULL,
      disconnected_at TIMESTAMPTZ,
      duration_secs INTEGER,
      source_ip INET,
      bytes_sent BIGINT DEFAULT 0,
      bytes_received BIGINT DEFAULT 0,
      disconnect_reason VARCHAR(100)
    );

    -- Client releases (for auto-update)
    CREATE TABLE IF NOT EXISTS client_releases (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      version VARCHAR(50) NOT NULL,
      platform VARCHAR(50) NOT NULL,
      architecture VARCHAR(20) NOT NULL,
      download_url TEXT NOT NULL,
      signature TEXT NOT NULL,
      sha256_hash VARCHAR(64) NOT NULL,
      file_size BIGINT NOT NULL,
      release_notes TEXT,
      is_mandatory BOOLEAN DEFAULT false,
      published_at TIMESTAMPTZ DEFAULT NOW(),
      UNIQUE(version, platform, architecture)
    );

    -- Indexes
    CREATE INDEX IF NOT EXISTS idx_clients_status ON clients(status);
    CREATE INDEX IF NOT EXISTS idx_clients_hardware_id ON clients(hardware_id);
    CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp ON audit_log(timestamp DESC);
    CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
    CREATE INDEX IF NOT EXISTS idx_error_log_timestamp ON error_log(timestamp DESC);
    CREATE INDEX IF NOT EXISTS idx_connection_log_client ON connection_log(client_id);
  '''),
];
