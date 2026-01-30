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
          sslMode: SslMode.disable, // Use SslMode.require for production
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

        // Split SQL by semicolons followed by newline (to avoid splitting in strings)
        // and filter out empty statements and pure comment lines
        final rawStatements = migration.sql.split(RegExp(r';\s*\n'));
        for (final raw in rawStatements) {
          // Remove comment-only lines and trim
          final lines = raw
              .split('\n')
              .where((line) => !line.trim().startsWith('--'))
              .join('\n')
              .trim();
          if (lines.isNotEmpty) {
            await conn.execute(lines);
          }
        }

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
      private_key_enc TEXT NOT NULL,
      public_key TEXT NOT NULL,
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

      -- WireGuard keys (base64 encoded)
      public_key TEXT NOT NULL UNIQUE,
      private_key_enc TEXT NOT NULL,
      preshared_key TEXT,

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

  _Migration('002_sso_configs', '''
    -- SSO provider configurations
    CREATE TABLE IF NOT EXISTS sso_configs (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      provider_id VARCHAR(50) UNIQUE NOT NULL,
      client_id VARCHAR(255) NOT NULL,
      client_secret VARCHAR(255),
      tenant_id VARCHAR(255),
      domain VARCHAR(255),
      scopes TEXT[] DEFAULT ARRAY['openid', 'profile', 'email'],
      enabled BOOLEAN DEFAULT true,
      metadata JSONB,
      created_at TIMESTAMPTZ DEFAULT NOW(),
      updated_at TIMESTAMPTZ DEFAULT NOW()
    );

    -- Add updated_at column to admins if not exists
    ALTER TABLE admins ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

    -- Index for enabled providers
    CREATE INDEX IF NOT EXISTS idx_sso_configs_enabled ON sso_configs(enabled) WHERE enabled = true;
  '''),

  _Migration('003_enrollment_codes', '''
    -- Enrollment codes for seamless device onboarding
    CREATE TABLE IF NOT EXISTS enrollment_codes (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
      code VARCHAR(8) NOT NULL UNIQUE,
      created_at TIMESTAMPTZ DEFAULT NOW(),
      expires_at TIMESTAMPTZ NOT NULL,
      redeemed_at TIMESTAMPTZ,
      redeemed_by_hardware_id VARCHAR(255)
    );

    -- Add device_token_hash to clients for token validation
    ALTER TABLE clients ADD COLUMN IF NOT EXISTS device_token_hash VARCHAR(64);

    -- Indexes for enrollment_codes
    CREATE INDEX IF NOT EXISTS idx_enrollment_codes_code ON enrollment_codes(code);
    CREATE INDEX IF NOT EXISTS idx_enrollment_codes_client ON enrollment_codes(client_id);
    CREATE INDEX IF NOT EXISTS idx_enrollment_codes_expires ON enrollment_codes(expires_at) WHERE redeemed_at IS NULL;
  '''),

  _Migration('004_email_settings', '''
    -- Email/SMTP settings (singleton)
    CREATE TABLE IF NOT EXISTS email_settings (
      id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
      enabled BOOLEAN DEFAULT false,
      smtp_host VARCHAR(255),
      smtp_port INTEGER DEFAULT 587,
      smtp_username VARCHAR(255),
      smtp_password_enc TEXT,
      use_ssl BOOLEAN DEFAULT false,
      use_starttls BOOLEAN DEFAULT true,
      from_email VARCHAR(255),
      from_name VARCHAR(255) DEFAULT 'SecureGuard VPN',
      last_test_at TIMESTAMPTZ,
      last_test_success BOOLEAN,
      updated_at TIMESTAMPTZ DEFAULT NOW()
    );
  '''),

  _Migration('005_api_keys', '''
    -- API keys for programmatic access
    CREATE TABLE IF NOT EXISTS api_keys (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      name VARCHAR(255) NOT NULL,
      key_hash VARCHAR(64) NOT NULL UNIQUE,
      key_prefix VARCHAR(12) NOT NULL,
      permissions VARCHAR(50) DEFAULT 'read',
      created_by UUID REFERENCES admins(id),
      created_at TIMESTAMPTZ DEFAULT NOW(),
      last_used_at TIMESTAMPTZ,
      expires_at TIMESTAMPTZ,
      is_active BOOLEAN DEFAULT true
    );

    CREATE INDEX idx_api_keys_hash ON api_keys(key_hash);
    CREATE INDEX idx_api_keys_active ON api_keys(is_active) WHERE is_active = true;
  '''),

  _Migration('006_api_keys_permissions_constraint', '''
    -- Add CHECK constraint to validate permissions values
    ALTER TABLE api_keys ADD CONSTRAINT chk_api_keys_permissions
      CHECK (permissions IN ('read', 'write', 'admin'));
  '''),

  _Migration('007_client_hostname', '''
    -- Add hostname column for device identity locking
    ALTER TABLE clients ADD COLUMN IF NOT EXISTS hostname VARCHAR(255);

    -- Index for hostname lookups
    CREATE INDEX IF NOT EXISTS idx_clients_hostname ON clients(hostname);
  '''),
];
