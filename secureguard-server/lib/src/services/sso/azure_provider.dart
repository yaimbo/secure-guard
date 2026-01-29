import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'sso_provider.dart';

/// Azure AD / Entra ID SSO provider
///
/// Supports both authorization code flow (with PKCE) and device code flow.
/// Device code flow is recommended for desktop/CLI applications.
class AzureADProvider implements SSOProvider {
  final SSOConfig config;
  final HttpClient _httpClient;

  /// Base URL for Azure AD endpoints
  String get _baseUrl =>
      'https://login.microsoftonline.com/${config.tenantId ?? 'common'}';

  AzureADProvider(this.config) : _httpClient = HttpClient() {
    if (config.tenantId == null) {
      throw ArgumentError('Azure AD requires tenantId in config');
    }
  }

  @override
  String get providerId => 'azure';

  @override
  String get displayName => 'Microsoft Entra ID';

  @override
  bool get isEnabled => config.enabled;

  @override
  Future<Uri> getAuthorizationUrl({
    required String redirectUri,
    required String state,
    required String codeVerifier,
    String? nonce,
  }) async {
    // Generate code challenge from verifier (S256 method)
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    final params = {
      'client_id': config.clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': config.scopes.join(' '),
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'response_mode': 'query',
    };

    if (nonce != null) {
      params['nonce'] = nonce;
    }

    return Uri.parse('$_baseUrl/oauth2/v2.0/authorize').replace(
      queryParameters: params,
    );
  }

  @override
  Future<TokenResponse> exchangeCode({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final body = {
      'client_id': config.clientId,
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': codeVerifier,
    };

    if (config.clientSecret != null) {
      body['client_secret'] = config.clientSecret!;
    }

    final response = await _postForm('$_baseUrl/oauth2/v2.0/token', body);
    return TokenResponse.fromJson(response);
  }

  @override
  Future<UserInfo> getUserInfo(String accessToken) async {
    final uri = Uri.parse('https://graph.microsoft.com/v1.0/me');
    final request = await _httpClient.getUrl(uri);
    request.headers.add('Authorization', 'Bearer $accessToken');

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw SSOException(
        'Failed to get user info',
        errorCode: response.statusCode.toString(),
        errorDescription: responseBody,
      );
    }

    final json = jsonDecode(responseBody) as Map<String, dynamic>;

    return UserInfo(
      subject: json['id'] as String,
      email: json['mail'] as String? ?? json['userPrincipalName'] as String?,
      name: json['displayName'] as String?,
      givenName: json['givenName'] as String?,
      familyName: json['surname'] as String?,
      claims: json,
    );
  }

  @override
  Future<TokenResponse> refreshToken(String refreshToken) async {
    final body = {
      'client_id': config.clientId,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'scope': config.scopes.join(' '),
    };

    if (config.clientSecret != null) {
      body['client_secret'] = config.clientSecret!;
    }

    final response = await _postForm('$_baseUrl/oauth2/v2.0/token', body);
    return TokenResponse.fromJson(response);
  }

  @override
  Future<IdTokenClaims> validateIdToken(String idToken) async {
    // Decode JWT (without signature verification for now)
    // In production, fetch JWKS and verify signature
    final parts = idToken.split('.');
    if (parts.length != 3) {
      throw SSOException('Invalid ID token format');
    }

    final payload = _decodeJwtPayload(parts[1]);

    // Validate standard claims
    final now = DateTime.now();
    final exp = DateTime.fromMillisecondsSinceEpoch(
        (payload['exp'] as int) * 1000);
    final iat = DateTime.fromMillisecondsSinceEpoch(
        (payload['iat'] as int) * 1000);

    if (now.isAfter(exp)) {
      throw SSOException('ID token has expired');
    }

    // Validate audience
    final aud = payload['aud'];
    if (aud != config.clientId) {
      throw SSOException('Invalid audience in ID token');
    }

    return IdTokenClaims(
      issuer: payload['iss'] as String,
      subject: payload['sub'] as String,
      audience: aud as String,
      issuedAt: iat,
      expiresAt: exp,
      nonce: payload['nonce'] as String?,
      email: payload['email'] as String? ??
          payload['preferred_username'] as String?,
      allClaims: payload,
    );
  }

  @override
  Future<DeviceAuthResponse> startDeviceAuth() async {
    final body = {
      'client_id': config.clientId,
      'scope': config.scopes.join(' '),
    };

    final response = await _postForm('$_baseUrl/oauth2/v2.0/devicecode', body);
    return DeviceAuthResponse.fromJson(response);
  }

  @override
  Future<TokenResponse> pollDeviceAuth(String deviceCode) async {
    final body = {
      'client_id': config.clientId,
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      'device_code': deviceCode,
    };

    try {
      final response = await _postForm('$_baseUrl/oauth2/v2.0/token', body);
      return TokenResponse.fromJson(response);
    } on SSOException catch (e) {
      // Handle specific error codes
      if (e.errorCode == 'authorization_pending') {
        throw AuthorizationPendingException();
      } else if (e.errorCode == 'slow_down') {
        throw SlowDownException();
      } else if (e.errorCode == 'expired_token') {
        throw ExpiredDeviceCodeException();
      }
      rethrow;
    }
  }

  /// Make a form-encoded POST request
  Future<Map<String, dynamic>> _postForm(
      String url, Map<String, String> body) async {
    final uri = Uri.parse(url);
    final request = await _httpClient.postUrl(uri);
    request.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded');

    final encodedBody =
        body.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    request.write(encodedBody);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    final json = jsonDecode(responseBody) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw SSOException(
        json['error_description'] as String? ?? 'Token request failed',
        errorCode: json['error'] as String?,
        errorDescription: json['error_description'] as String?,
      );
    }

    return json;
  }

  /// Generate PKCE code challenge from verifier (S256 method)
  String _generateCodeChallenge(String codeVerifier) {
    final bytes = utf8.encode(codeVerifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// Decode JWT payload
  Map<String, dynamic> _decodeJwtPayload(String payload) {
    // Add padding if needed
    var normalized = payload;
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }

    final decoded = utf8.decode(base64Url.decode(normalized));
    return jsonDecode(decoded) as Map<String, dynamic>;
  }

  void dispose() {
    _httpClient.close();
  }
}

/// Generate a cryptographically secure random string for PKCE
String generateCodeVerifier([int length = 128]) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final random = Random.secure();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)])
      .join();
}

/// Generate a random state parameter for CSRF protection
String generateState([int length = 32]) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return List.generate(length, (_) => chars[random.nextInt(chars.length)])
      .join();
}
