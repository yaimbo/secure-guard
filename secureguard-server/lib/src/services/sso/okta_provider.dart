import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'sso_provider.dart';

/// Okta SSO provider
///
/// Supports authorization code flow with PKCE and device code flow.
/// Uses standard Okta OAuth 2.0 / OpenID Connect endpoints.
/// Implements full JWT signature verification using Okta's JWKS.
class OktaProvider implements SSOProvider {
  final SSOConfig config;
  final HttpClient _httpClient;

  // JWKS cache
  Map<String, _CachedJwk>? _jwksCache;
  DateTime? _jwksCacheExpiry;
  static const _jwksCacheDuration = Duration(hours: 1);

  /// Base URL for Okta endpoints (domain is required in config)
  String get _baseUrl => 'https://${config.domain}';

  OktaProvider(this.config) : _httpClient = HttpClient() {
    if (config.domain == null || config.domain!.isEmpty) {
      throw ArgumentError('Okta requires domain in config (e.g., your-org.okta.com)');
    }
  }

  @override
  String get providerId => 'okta';

  @override
  String get displayName => 'Okta';

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
    };

    if (nonce != null) {
      params['nonce'] = nonce;
    }

    return Uri.parse('$_baseUrl/oauth2/v1/authorize').replace(
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

    final response = await _postForm('$_baseUrl/oauth2/v1/token', body);
    return TokenResponse.fromJson(response);
  }

  @override
  Future<UserInfo> getUserInfo(String accessToken) async {
    final uri = Uri.parse('$_baseUrl/oauth2/v1/userinfo');
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

    final response = await _postForm('$_baseUrl/oauth2/v1/token', body);
    return TokenResponse.fromJson(response);
  }

  @override
  Future<IdTokenClaims> validateIdToken(String idToken) async {
    final parts = idToken.split('.');
    if (parts.length != 3) {
      throw SSOException('Invalid ID token format');
    }

    // 1. Decode header to get key ID (kid)
    final header = _decodeJwtPayload(parts[0]);
    final kid = header['kid'] as String?;
    final alg = header['alg'] as String?;

    if (alg != 'RS256') {
      throw SSOException('Unsupported algorithm: $alg (expected RS256)');
    }

    if (kid == null) {
      throw SSOException('Missing kid in JWT header');
    }

    // 2. Verify signature using Okta's JWKS
    await _verifySignature(idToken, kid);

    // 3. Decode and validate payload
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

    // Allow small clock skew (5 minutes)
    final clockSkew = const Duration(minutes: 5);
    if (iat.isAfter(now.add(clockSkew))) {
      throw SSOException('ID token issued in the future');
    }

    // Validate issuer (should start with the Okta domain URL)
    final iss = payload['iss'] as String;
    final expectedIssuerPrefix = 'https://${config.domain}';
    if (!iss.startsWith(expectedIssuerPrefix)) {
      throw SSOException('Invalid issuer in ID token: $iss (expected to start with $expectedIssuerPrefix)');
    }

    // Validate audience
    final aud = payload['aud'];
    if (aud != config.clientId) {
      throw SSOException('Invalid audience in ID token');
    }

    return IdTokenClaims(
      issuer: iss,
      subject: payload['sub'] as String,
      audience: aud as String,
      issuedAt: iat,
      expiresAt: exp,
      nonce: payload['nonce'] as String?,
      email: payload['email'] as String?,
      allClaims: payload,
    );
  }

  /// Verify JWT signature using Okta's JWKS
  Future<void> _verifySignature(String jwt, String kid) async {
    // Fetch JWKS (with caching)
    final jwks = await _fetchJwks();

    // Find the key with matching kid
    final jwk = jwks[kid];
    if (jwk == null) {
      throw SSOException('Key not found in JWKS: $kid');
    }

    // Parse the JWT parts
    final parts = jwt.split('.');
    final signedData = utf8.encode('${parts[0]}.${parts[1]}');
    final signature = _base64UrlDecode(parts[2]);

    // Verify RS256 signature
    final rsaPublicKey = RSAPublicKey(jwk.modulus, jwk.exponent);
    final signer = Signer('SHA-256/RSA-PKCS1');
    signer.init(false, PublicKeyParameter<RSAPublicKey>(rsaPublicKey));

    try {
      final valid = signer.verifySignature(
        Uint8List.fromList(signedData),
        RSASignature(signature),
      );
      if (!valid) {
        throw SSOException('Invalid JWT signature');
      }
    } catch (e) {
      if (e is SSOException) rethrow;
      throw SSOException('Signature verification failed: $e');
    }
  }

  /// Fetch Okta's JWKS with caching
  Future<Map<String, _CachedJwk>> _fetchJwks() async {
    // Return cached JWKS if still valid
    if (_jwksCache != null &&
        _jwksCacheExpiry != null &&
        DateTime.now().isBefore(_jwksCacheExpiry!)) {
      return _jwksCache!;
    }

    // Fetch fresh JWKS
    final uri = Uri.parse('$_baseUrl/oauth2/v1/keys');
    final request = await _httpClient.getUrl(uri);
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw SSOException('Failed to fetch JWKS: ${response.statusCode}');
    }

    final json = jsonDecode(responseBody) as Map<String, dynamic>;
    final keys = json['keys'] as List<dynamic>?;

    if (keys == null || keys.isEmpty) {
      throw SSOException('Invalid JWKS response: no keys found');
    }

    final jwks = <String, _CachedJwk>{};
    for (final key in keys) {
      final keyMap = key as Map<String, dynamic>;
      final kid = keyMap['kid'] as String?;
      final kty = keyMap['kty'] as String?;
      final use = keyMap['use'] as String?;
      final n = keyMap['n'] as String?;
      final e = keyMap['e'] as String?;

      // Only process RSA signature keys
      if (kid != null && kty == 'RSA' && use == 'sig' && n != null && e != null) {
        jwks[kid] = _CachedJwk(
          kid: kid,
          modulus: _base64UrlDecodeBigInt(n),
          exponent: _base64UrlDecodeBigInt(e),
        );
      }
    }

    // Cache the JWKS
    _jwksCache = jwks;
    _jwksCacheExpiry = DateTime.now().add(_jwksCacheDuration);

    return jwks;
  }

  /// Decode base64url to bytes
  Uint8List _base64UrlDecode(String input) {
    var normalized = input.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    return Uint8List.fromList(base64.decode(normalized));
  }

  /// Decode base64url to BigInt (for RSA modulus/exponent)
  BigInt _base64UrlDecodeBigInt(String input) {
    final bytes = _base64UrlDecode(input);
    return _bytesToBigInt(bytes);
  }

  /// Convert bytes to BigInt (big-endian unsigned)
  BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  @override
  Future<DeviceAuthResponse> startDeviceAuth() async {
    final body = {
      'client_id': config.clientId,
      'scope': config.scopes.join(' '),
    };

    final response = await _postForm('$_baseUrl/oauth2/v1/device/authorize', body);
    return DeviceAuthResponse.fromJson(response);
  }

  @override
  Future<TokenResponse> pollDeviceAuth(String deviceCode) async {
    final body = {
      'client_id': config.clientId,
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      'device_code': deviceCode,
    };

    if (config.clientSecret != null) {
      body['client_secret'] = config.clientSecret!;
    }

    try {
      final response = await _postForm('$_baseUrl/oauth2/v1/token', body);
      return TokenResponse.fromJson(response);
    } on SSOException catch (e) {
      // Handle specific error codes
      if (e.errorCode == 'authorization_pending') {
        throw AuthorizationPendingException();
      } else if (e.errorCode == 'slow_down') {
        throw SlowDownException();
      } else if (e.errorCode == 'expired_token') {
        throw ExpiredDeviceCodeException();
      } else if (e.errorCode == 'access_denied') {
        throw SSOException('User denied authorization', errorCode: 'access_denied');
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

/// Cached JWK (JSON Web Key) for signature verification
class _CachedJwk {
  final String kid;
  final BigInt modulus;
  final BigInt exponent;

  _CachedJwk({
    required this.kid,
    required this.modulus,
    required this.exponent,
  });
}
