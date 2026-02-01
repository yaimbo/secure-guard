/// Abstract SSO provider interface for OAuth/OIDC authentication
///
/// Implementations should handle provider-specific OAuth flows
/// while exposing a consistent interface for the authentication system.
abstract class SSOProvider {
  /// Unique identifier for this provider (e.g., 'azure', 'okta', 'google')
  String get providerId;

  /// Human-readable name for display
  String get displayName;

  /// Whether this provider is currently configured and enabled
  bool get isEnabled;

  /// Get the authorization URL to redirect users to for login
  ///
  /// [redirectUri] - The callback URL after authentication
  /// [state] - CSRF protection state parameter
  /// [codeVerifier] - PKCE code verifier for secure auth code exchange
  /// [nonce] - Optional nonce for ID token validation
  Future<Uri> getAuthorizationUrl({
    required String redirectUri,
    required String state,
    required String codeVerifier,
    String? nonce,
  });

  /// Exchange authorization code for tokens
  ///
  /// [code] - The authorization code from callback
  /// [codeVerifier] - PKCE code verifier used in authorization
  /// [redirectUri] - Must match the redirect URI used in authorization
  Future<TokenResponse> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  });

  /// Get user information from the access token
  Future<UserInfo> getUserInfo(String accessToken);

  /// Refresh an expired access token
  Future<TokenResponse> refreshToken(String refreshToken);

  /// Validate an ID token and extract claims
  Future<IdTokenClaims> validateIdToken(String idToken);

  /// Get device authorization for device code flow (for CLI/desktop apps)
  Future<DeviceAuthResponse> startDeviceAuth();

  /// Poll for device authorization completion
  Future<TokenResponse> pollDeviceAuth(String deviceCode);
}

/// Token response from OAuth provider
class TokenResponse {
  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final int expiresIn;
  final String tokenType;
  final List<String>? scopes;

  TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    required this.expiresIn,
    this.tokenType = 'Bearer',
    this.scopes,
  });

  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    return TokenResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
      expiresIn: json['expires_in'] as int? ?? 3600,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      scopes: (json['scope'] as String?)?.split(' '),
    );
  }
}

/// User information from SSO provider
class UserInfo {
  final String subject;
  final String? email;
  final bool? emailVerified;
  final String? name;
  final String? givenName;
  final String? familyName;
  final String? picture;
  final Map<String, dynamic>? claims;

  UserInfo({
    required this.subject,
    this.email,
    this.emailVerified,
    this.name,
    this.givenName,
    this.familyName,
    this.picture,
    this.claims,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      subject: json['sub'] as String,
      email: json['email'] as String?,
      emailVerified: json['email_verified'] as bool?,
      name: json['name'] as String?,
      givenName: json['given_name'] as String?,
      familyName: json['family_name'] as String?,
      picture: json['picture'] as String?,
      claims: json,
    );
  }
}

/// ID token claims after validation
class IdTokenClaims {
  final String issuer;
  final String subject;
  final String audience;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String? nonce;
  final String? email;
  final Map<String, dynamic> allClaims;

  IdTokenClaims({
    required this.issuer,
    required this.subject,
    required this.audience,
    required this.issuedAt,
    required this.expiresAt,
    this.nonce,
    this.email,
    required this.allClaims,
  });
}

/// Device authorization response for device code flow
class DeviceAuthResponse {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String? verificationUriComplete;
  final int expiresIn;
  final int interval;

  DeviceAuthResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    this.verificationUriComplete,
    required this.expiresIn,
    this.interval = 5,
  });

  factory DeviceAuthResponse.fromJson(Map<String, dynamic> json) {
    return DeviceAuthResponse(
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String,
      verificationUri: json['verification_uri'] as String,
      verificationUriComplete: json['verification_uri_complete'] as String?,
      expiresIn: json['expires_in'] as int,
      interval: json['interval'] as int? ?? 5,
    );
  }
}

/// SSO configuration for a provider
class SSOConfig {
  final String providerId;
  final String clientId;
  final String? clientSecret;
  final String? tenantId; // For Azure AD
  final String? domain; // For Okta
  final List<String> scopes;
  final bool enabled;
  final Map<String, dynamic>? metadata;

  SSOConfig({
    required this.providerId,
    required this.clientId,
    this.clientSecret,
    this.tenantId,
    this.domain,
    this.scopes = const ['openid', 'profile', 'email'],
    this.enabled = true,
    this.metadata,
  });

  factory SSOConfig.fromJson(Map<String, dynamic> json) {
    return SSOConfig(
      providerId: json['provider_id'] as String,
      clientId: json['client_id'] as String,
      clientSecret: json['client_secret'] as String?,
      tenantId: json['tenant_id'] as String?,
      domain: json['domain'] as String?,
      scopes: (json['scopes'] as List<dynamic>?)?.cast<String>() ??
          ['openid', 'profile', 'email'],
      enabled: json['enabled'] as bool? ?? true,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
        'provider_id': providerId,
        'client_id': clientId,
        'client_secret': clientSecret,
        'tenant_id': tenantId,
        'domain': domain,
        'scopes': scopes,
        'enabled': enabled,
        'metadata': metadata,
      };
}

/// Exception thrown by SSO providers
class SSOException implements Exception {
  final String message;
  final String? errorCode;
  final String? errorDescription;

  SSOException(this.message, {this.errorCode, this.errorDescription});

  @override
  String toString() {
    if (errorCode != null) {
      return 'SSOException: $message (code: $errorCode)';
    }
    return 'SSOException: $message';
  }
}

/// Pending authorization error (for device code flow)
class AuthorizationPendingException extends SSOException {
  AuthorizationPendingException() : super('Authorization pending');
}

/// Slow down error (for device code flow polling)
class SlowDownException extends SSOException {
  SlowDownException() : super('Slow down polling');
}

/// Expired device code error
class ExpiredDeviceCodeException extends SSOException {
  ExpiredDeviceCodeException() : super('Device code expired');
}
