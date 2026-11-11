import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'dart:io';

import '../models/auth_models.dart';

/// HTTP client for the FastAPI auth endpoints.
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
    final Map<String, dynamic> body = await _postJson(<String, String>{
      'username': username,
      'password': password,
    }, path: '/auth/register');
    return _userFrom(body);
  }

  Future<LoginResult> login({
    required String account,
    required String password,
  }) async {
    final Map<String, dynamic> body = await _postJson(<String, String>{
      'account': account,
      'password': password,
    }, path: '/auth/login');
    final Object? token = body['token'];
    if (token is! String || token.isEmpty) {
      throw upstreamMalformed;
    }
    return LoginResult(user: _userFrom(body), token: token);
  }

  AuthUser _userFrom(Map<String, dynamic> json) {
    final Object? account = json['account'];
    final Object? username = json['username'];
    if (account is! String || username is! String) {
      throw upstreamMalformed;
    }
    return AuthUser(account: account, username: username);
  }

  Future<Map<String, dynamic>> _postJson(
    Map<String, String> payload, {
    required String path,
  }) async {
    final Uri url = baseUri.resolve(path);
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .postUrl(url)
          .timeout(timeout);
      request.headers.contentType = ContentType.json;
      final List<int> bodyBytes = utf8.encode(jsonEncode(payload));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String rawBody = await _readBody(response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _decodeSuccess(rawBody);
      }
      throw _decodeFailure(response.statusCode, rawBody);
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
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxResponseBytes) {
        throw upstreamMalformed;
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Map<String, dynamic> _decodeSuccess(String rawBody) {
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
    return upstreamMalformed;
  }
}
