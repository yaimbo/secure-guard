import 'dart:convert';

import '../../database/database.dart';
import 'azure_provider.dart' show AzureADProvider, generateCodeVerifier, generateState;
import 'google_provider.dart';
import 'okta_provider.dart';
import 'sso_provider.dart';

/// Manages SSO providers and authentication flows
class SSOManager {
  final Database db;
  final Map<String, SSOProvider> _providers = {};
  final Map<String, _PendingAuth> _pendingAuths = {};

  SSOManager(this.db);

  /// Initialize SSO providers from database configuration
  Future<void> init() async {
    await _loadProviders();
  }

  /// Load provider configurations from database
  Future<void> _loadProviders() async {
    try {
      final result = await db.execute('''
        SELECT * FROM sso_configs WHERE enabled = true
      ''');

      for (final row in result) {
        final config = SSOConfig.fromJson(row.toColumnMap());
        _registerProvider(config);
      }
    } catch (e) {
      // Table might not exist yet
    }
  }

  /// Register a provider based on configuration
  void _registerProvider(SSOConfig config) {
    switch (config.providerId) {
      case 'azure':
        _providers['azure'] = AzureADProvider(config);
        break;
      case 'google':
        _providers['google'] = GoogleProvider(config);
        break;
      case 'okta':
        _providers['okta'] = OktaProvider(config);
        break;
    }
  }

  /// Get a provider by ID
  SSOProvider? getProvider(String providerId) => _providers[providerId];

  /// Get all enabled providers
  List<SSOProvider> get enabledProviders =>
      _providers.values.where((p) => p.isEnabled).toList();

  /// Check if any SSO providers are enabled
  bool get hasEnabledProviders => enabledProviders.isNotEmpty;

  /// Start authorization code flow
  ///
  /// Returns the authorization URL to redirect the user to
  Future<Uri> startAuthorizationFlow({
    required String providerId,
    required String redirectUri,
    String? nonce,
  }) async {
    final provider = getProvider(providerId);
    if (provider == null) {
      throw SSOException('Provider not found: $providerId');
    }

    // Generate PKCE parameters
    final codeVerifier = generateCodeVerifier();
    final state = generateState();

    // Store pending auth for callback verification
    _pendingAuths[state] = _PendingAuth(
      providerId: providerId,
      codeVerifier: codeVerifier,
      redirectUri: redirectUri,
      nonce: nonce,
      createdAt: DateTime.now(),
    );

    // Clean up old pending auths (older than 10 minutes)
    _cleanupPendingAuths();

    return provider.getAuthorizationUrl(
      redirectUri: redirectUri,
      state: state,
      codeVerifier: codeVerifier,
      nonce: nonce,
    );
  }

  /// Handle OAuth callback
  ///
  /// Exchanges the authorization code for tokens and returns user info
  Future<SSOAuthResult> handleCallback({
    required String state,
    required String code,
  }) async {
    final pending = _pendingAuths.remove(state);
    if (pending == null) {
      throw SSOException('Invalid or expired state parameter');
    }

    final provider = getProvider(pending.providerId);
    if (provider == null) {
      throw SSOException('Provider not found');
    }

    // Exchange code for tokens
    final tokens = await provider.exchangeCode(
      code: code,
      codeVerifier: pending.codeVerifier,
      redirectUri: pending.redirectUri,
    );

    // Validate ID token if present
    IdTokenClaims? idClaims;
    if (tokens.idToken != null) {
      idClaims = await provider.validateIdToken(tokens.idToken!);

      // Verify nonce if we set one
      if (pending.nonce != null && idClaims.nonce != pending.nonce) {
        throw SSOException('Nonce mismatch in ID token');
      }
    }

    // Get user info
    final userInfo = await provider.getUserInfo(tokens.accessToken);

    return SSOAuthResult(
      providerId: pending.providerId,
      tokens: tokens,
      userInfo: userInfo,
      idClaims: idClaims,
    );
  }

  /// Start device code flow for desktop/CLI applications
  Future<DeviceAuthResponse> startDeviceFlow(String providerId) async {
    final provider = getProvider(providerId);
    if (provider == null) {
      throw SSOException('Provider not found: $providerId');
    }

    return provider.startDeviceAuth();
  }

  /// Poll for device code flow completion
  Future<SSOAuthResult> pollDeviceFlow({
    required String providerId,
    required String deviceCode,
  }) async {
    final provider = getProvider(providerId);
    if (provider == null) {
      throw SSOException('Provider not found: $providerId');
    }

    final tokens = await provider.pollDeviceAuth(deviceCode);
    final userInfo = await provider.getUserInfo(tokens.accessToken);

    IdTokenClaims? idClaims;
    if (tokens.idToken != null) {
      idClaims = await provider.validateIdToken(tokens.idToken!);
    }

    return SSOAuthResult(
      providerId: providerId,
      tokens: tokens,
      userInfo: userInfo,
      idClaims: idClaims,
    );
  }

  /// Save or update SSO configuration
  Future<void> saveConfig(SSOConfig config) async {
    await db.execute('''
      INSERT INTO sso_configs (
        provider_id, client_id, client_secret, tenant_id, domain,
        scopes, enabled, metadata
      ) VALUES (
        @provider_id, @client_id, @client_secret, @tenant_id, @domain,
        @scopes, @enabled, @metadata
      )
      ON CONFLICT (provider_id) DO UPDATE SET
        client_id = @client_id,
        client_secret = @client_secret,
        tenant_id = @tenant_id,
        domain = @domain,
        scopes = @scopes,
        enabled = @enabled,
        metadata = @metadata,
        updated_at = NOW()
    ''', {
      'provider_id': config.providerId,
      'client_id': config.clientId,
      'client_secret': config.clientSecret,
      'tenant_id': config.tenantId,
      'domain': config.domain,
      'scopes': config.scopes,
      'enabled': config.enabled,
      'metadata': config.metadata != null ? jsonEncode(config.metadata) : null,
    });

    // Reload providers
    await _loadProviders();
  }

  /// Get all SSO configurations
  Future<List<SSOConfig>> getConfigs() async {
    final result = await db.execute('SELECT * FROM sso_configs');
    return result.map((row) => SSOConfig.fromJson(row.toColumnMap())).toList();
  }

  /// Delete SSO configuration
  Future<void> deleteConfig(String providerId) async {
    await db.execute(
      'DELETE FROM sso_configs WHERE provider_id = @provider_id',
      {'provider_id': providerId},
    );

    _providers.remove(providerId);
  }

  void _cleanupPendingAuths() {
    final expiry = DateTime.now().subtract(const Duration(minutes: 10));
    _pendingAuths.removeWhere((_, auth) => auth.createdAt.isBefore(expiry));
  }

  void dispose() {
    for (final provider in _providers.values) {
      if (provider is AzureADProvider) {
        provider.dispose();
      } else if (provider is GoogleProvider) {
        provider.dispose();
      } else if (provider is OktaProvider) {
        provider.dispose();
      }
    }
  }
}

/// Pending authorization state
class _PendingAuth {
  final String providerId;
  final String codeVerifier;
  final String redirectUri;
  final String? nonce;
  final DateTime createdAt;

  _PendingAuth({
    required this.providerId,
    required this.codeVerifier,
    required this.redirectUri,
    this.nonce,
    required this.createdAt,
  });
}

/// Result of SSO authentication
class SSOAuthResult {
  final String providerId;
  final TokenResponse tokens;
  final UserInfo userInfo;
  final IdTokenClaims? idClaims;

  SSOAuthResult({
    required this.providerId,
    required this.tokens,
    required this.userInfo,
    this.idClaims,
  });
}
