import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../models/auth_models.dart';

/// HTTP client for the FastAPI auth/session endpoints.
///
/// Uses `dart:io` directly so the exact same transport runs in the Flutter UI,
/// in the standalone local control API and in widget/integration tests, with no
/// platform-specific plugin.
class AuthApiClient {
  AuthApiClient({
    required this.baseUri,
    this.timeout = const Duration(seconds: 10),
  });

  final Uri baseUri;
  final Duration timeout;

  /// Upper bound on a response body; auth payloads are tiny.
  static const int maxResponseBytes = 64 * 1024;

  Future<AuthUser> register({
    required String username,
    required String password,
  }) async {
    final Map<String, dynamic> body = await _requestJson(
      'POST',
      '/auth/register',
      payload: <String, String>{'username': username, 'password': password},
    );
    return _userFrom(body);
  }

  Future<LoginResult> login({
    required String account,
    required String password,
  }) async {
    final Map<String, dynamic> body = await _requestJson(
      'POST',
      '/auth/login',
      payload: <String, String>{'account': account, 'password': password},
    );
    final Object? token = body['token'];
    if (token is! String || token.isEmpty) {
      throw upstreamMalformed;
    }
    return LoginResult(user: _userFrom(body), token: token);
  }

  /// `GET /auth/session` — verifies a stored bearer token and returns the
  /// account it belongs to.
  Future<AuthUser> fetchSession(String token) async {
    final Map<String, dynamic> body = await _requestJson(
      'GET',
      '/auth/session',
      token: token,
    );
    return _userFrom(body);
  }

  /// `POST /auth/logout` — deletes only this session server-side (204).
  Future<void> logout(String token) async {
    final _RawResponse response = await _send(
      'POST',
      '/auth/logout',
      token: token,
    );
    if (response.status == 204 || response.status == 200) {
      return;
    }
    throw _decodeFailure(response.status, response.body);
  }

  /// `POST /auth/heartbeat` — refreshes `last_seen_at` and returns online.
  Future<void> heartbeat(String token) async {
    final _RawResponse response = await _send(
      'POST',
      '/auth/heartbeat',
      token: token,
    );
    if (response.status < 200 || response.status >= 300) {
      throw _decodeFailure(response.status, response.body);
    }
    final Map<String, dynamic> body = _decodeJson(response.body);
    if (body['status'] != 'online' || body['last_seen_at'] is! String) {
      throw upstreamMalformed;
    }
  }

  AuthUser _userFrom(Map<String, dynamic> json) {
    final Object? account = json['account'];
    final Object? username = json['username'];
    if (account is! String || username is! String) {
      throw upstreamMalformed;
    }
    return AuthUser(account: account, username: username);
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, String>? payload,
    String? token,
  }) async {
    final _RawResponse response = await _send(
      method,
      path,
      payload: payload,
      token: token,
    );
    if (response.status >= 200 && response.status < 300) {
      return _decodeJson(response.body);
    }
    throw _decodeFailure(response.status, response.body);
  }

  Map<String, dynamic> _decodeJson(String rawBody) {
    try {
      final Object? decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // Fall through to the typed failure below.
    }
    throw upstreamMalformed;
  }

  AuthFailure _decodeFailure(int status, String rawBody) {
    try {
      final Object? decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        final Object? error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final Object? code = error['code'];
          final Object? message = error['message'];
          final Object? rawFields = error['fields'];
          if (code is String && message is String) {
            final List<AuthFieldError> fields = <AuthFieldError>[];
            if (rawFields is List) {
              for (final Object? entry in rawFields) {
                fields.add(AuthFieldError.fromJson(entry));
              }
            }
            return AuthFailure(
              status: status,
              code: code,
              message: message,
              fields: fields,
            );
          }
        }
      }
    } on FormatException {
      // Fall through to the typed failure below.
    }
    if (status == 401) {
      return unauthenticated;
    }
    return upstreamMalformed;
  }

  Future<_RawResponse> _send(
    String method,
    String path, {
    Map<String, String>? payload,
    String? token,
  }) async {
    final Uri url = baseUri.resolve(path);
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .openUrl(method, url)
          .timeout(timeout);
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (payload != null) {
        request.headers.contentType = ContentType.json;
        final List<int> bodyBytes = utf8.encode(jsonEncode(payload));
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }

      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String rawBody = await _readBody(response);
      return _RawResponse(response.statusCode, rawBody);
    } on SocketException {
      throw upstreamUnavailable;
    } on HandshakeException {
      throw upstreamUnavailable;
    } on HttpException {
      throw upstreamUnavailable;
    } on TimeoutException {
      throw upstreamTimeout;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _readBody(HttpClientResponse response) async {
    if (response.statusCode == 204) {
      await response.drain<void>();
      return '';
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxResponseBytes) {
        throw upstreamMalformed;
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }
}

class _RawResponse {
  const _RawResponse(this.status, this.body);

  final int status;
  final String body;
}
