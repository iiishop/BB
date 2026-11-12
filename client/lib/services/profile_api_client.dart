import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/auth_models.dart';
import '../models/profile_models.dart';

/// Result of a conditional avatar fetch.
class AvatarFetch {
  const AvatarFetch({
    required this.notModified,
    required this.bytes,
    required this.version,
  });

  /// True when the server answered 304 and [bytes] come from the local cache.
  final bool notModified;

  /// PNG bytes. Empty only when [notModified] is true and no cache existed
  /// (the caller then retries without `If-None-Match`).
  final Uint8List bytes;
  final String version;
}

/// HTTP client for the STEP-2 Profile/avatar/session endpoints.
///
/// Uses `dart:io` so the identical transport runs in the Flutter UI, in the
/// standalone local control API and in tests. Every avatar request carries the
/// session Bearer token; avatar reads are authenticated server routes.
class ProfileApiClient {
  ProfileApiClient({
    required this.baseUri,
    this.timeout = const Duration(seconds: 10),
  });

  final Uri baseUri;
  final Duration timeout;

  static const int maxJsonResponseBytes = 64 * 1024;
  static const int maxAvatarResponseBytes = 5 * 1024 * 1024;

  Future<Profile> fetchProfile({
    required String token,
    required String account,
  }) async {
    final _Response response = await _send(
      'GET',
      '/users/$account/profile',
      token: token,
    );
    return _decodeProfile(response);
  }

  Future<Profile> patchProfile({
    required String token,
    required ProfilePatch patch,
  }) async {
    final List<int> body = utf8.encode(jsonEncode(patch.toJson()));
    final _Response response = await _send(
      'PATCH',
      '/me/profile',
      token: token,
      body: body,
      contentType: 'application/json; charset=utf-8',
    );
    return _decodeProfile(response);
  }

  Future<AvatarInfo> uploadAvatar({
    required String token,
    required Uint8List bytes,
    String filename = 'avatar.png',
  }) async {
    final String boundary =
        'bb-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final List<int> body = <int>[
      ...utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n',
      ),
      ...bytes,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final _Response response = await _send(
      'POST',
      '/me/avatar',
      token: token,
      body: body,
      contentType: 'multipart/form-data; boundary=$boundary',
    );
    return _decodeAvatar(response);
  }

  Future<AvatarInfo> deleteAvatar({required String token}) async {
    final _Response response = await _send(
      'DELETE',
      '/me/avatar',
      token: token,
    );
    return _decodeAvatar(response);
  }

  /// `GET /avatars/{account}.png` with optional `If-None-Match`.
  ///
  /// A 304 means the cached bytes are still current; the caller must therefore
  /// supply them. Auth happens before 304 server-side.
  Future<AvatarFetch> fetchAvatar({
    required String token,
    required String account,
    String? ifNoneMatch,
  }) async {
    final Map<String, String> extra = <String, String>{};
    if (ifNoneMatch != null && ifNoneMatch.isNotEmpty) {
      extra[HttpHeaders.ifNoneMatchHeader] = '"$ifNoneMatch"';
    }
    final _Response response = await _send(
      'GET',
      '/avatars/$account.png',
      token: token,
      extraHeaders: extra,
      maxBytes: maxAvatarResponseBytes,
      allowNotModified: true,
    );
    if (response.status == HttpStatus.notModified) {
      return AvatarFetch(
        notModified: true,
        bytes: Uint8List(0),
        version: _stripQuotes(response.headers['etag']) ?? ifNoneMatch ?? '',
      );
    }
    if (response.status != HttpStatus.ok) {
      throw _decodeFailure(response);
    }
    if (response.bytes.isEmpty) {
      throw upstreamMalformed;
    }
    final String? version = _stripQuotes(response.headers['etag']);
    if (version == null || version.isEmpty) {
      throw upstreamMalformed;
    }
    return AvatarFetch(
      notModified: false,
      bytes: response.bytes,
      version: version,
    );
  }

  Profile _decodeProfile(_Response response) {
    if (response.status != HttpStatus.ok) {
      throw _decodeFailure(response);
    }
    try {
      return Profile.fromJson(_decodeJson(response.bytes));
    } on FormatException {
      throw upstreamMalformed;
    }
  }

  AvatarInfo _decodeAvatar(_Response response) {
    if (response.status != HttpStatus.ok) {
      throw _decodeFailure(response);
    }
    try {
      return AvatarInfo.fromJson(_decodeJson(response.bytes));
    } on FormatException {
      throw upstreamMalformed;
    }
  }

  Object? _decodeJson(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw upstreamMalformed;
    }
  }

  AuthFailure _decodeFailure(_Response response) {
    try {
      final Object? decoded = _decodeJson(response.bytes);
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
              status: response.status,
              code: code,
              message: message,
              fields: fields,
            );
          }
        }
      }
    } on AuthFailure {
      // Fall through to the typed malformed failure.
    } on FormatException {
      // Fall through to the typed malformed failure.
    }
    return upstreamMalformed;
  }

  static String? _stripQuotes(String? etag) {
    if (etag == null) {
      return null;
    }
    String value = etag.trim();
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<_Response> _send(
    String method,
    String path, {
    required String token,
    List<int>? body,
    String? contentType,
    Map<String, String> extraHeaders = const <String, String>{},
    int maxBytes = maxJsonResponseBytes,
    bool allowNotModified = false,
  }) async {
    final Uri url = baseUri.resolve(path);
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .openUrl(method, url)
          .timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      extraHeaders.forEach(request.headers.set);
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType!);
        request.contentLength = body.length;
        request.add(body);
      }
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final Uint8List bytes = await _readBounded(
        response,
        maxBytes: maxBytes,
        allowNotModified: allowNotModified,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _Response(response.statusCode, bytes, _headers(response));
      }
      if (allowNotModified && response.statusCode == HttpStatus.notModified) {
        return _Response(response.statusCode, bytes, _headers(response));
      }
      return _Response(response.statusCode, bytes, _headers(response));
    } on AuthFailure {
      rethrow;
    } on TimeoutException {
      throw upstreamTimeout;
    } on SocketException {
      throw upstreamUnavailable;
    } on HandshakeException {
      throw upstreamUnavailable;
    } on HttpException {
      throw upstreamUnavailable;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, String> _headers(HttpClientResponse response) {
    final Map<String, String> headers = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      if (values.isNotEmpty) {
        headers[name.toLowerCase()] = values.first;
      }
    });
    return headers;
  }

  Future<Uint8List> _readBounded(
    HttpClientResponse response, {
    required int maxBytes,
    required bool allowNotModified,
  }) async {
    if (allowNotModified && response.statusCode == HttpStatus.notModified) {
      await response.drain<void>();
      return Uint8List(0);
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw upstreamMalformed;
      }
    }
    return builder.takeBytes();
  }
}

class _Response {
  const _Response(this.status, this.bytes, this.headers);

  final int status;
  final Uint8List bytes;
  final Map<String, String> headers;
}
