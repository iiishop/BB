import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/auth_models.dart';
import 'http_transport.dart';
import 'space_schema.g.dart';
export '../models/space_models.dart';
export 'space_methods.g.dart';

/// Same bounded, authenticated transport for Flutter and standalone Dart.
/// This accepts only the actions in the generated shared Space contract.
class SpaceApiClient {
  SpaceApiClient({
    required this.baseUri,
    this.timeout = const Duration(seconds: 30),
  });
  final Uri baseUri;
  final Duration timeout;

  /// Reused across calls so the TLS connection is not rebuilt per request.
  late final HttpTransport _http = HttpTransport(connectionTimeout: timeout);

  Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body, {
    required String token,
  }) async {
    validateSpace(action, body);
    final HttpClient client = _http.client;
    try {
      final request = await client
          .postUrl(baseUri.resolve('/space/$action'))
          .timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > 48 * 1024 * 1024) throw upstreamMalformed;
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (response.statusCode != 200) {
        final error = decoded is Map ? decoded['error'] : null;
        final code = error is Map ? error['code'] : null;
        if (code is String && spaceErrorStatus[code] == response.statusCode) {
          throw spaceFailure(response.statusCode, code);
        }
        if (response.statusCode == 404 && action == 'overview') {
          throw spaceFailure(404, 'unsupported_space');
        }
        throw upstreamMalformed;
      }
      if (decoded is! Map<String, dynamic>) throw upstreamMalformed;
      try {
        validateSpace(action, decoded, kind: 'response');
      } on FormatException {
        throw upstreamMalformed;
      }
      return decoded;
    } on SocketException {
      throw upstreamUnavailable;
    } on HttpException {
      throw upstreamUnavailable;
    } on HandshakeException {
      throw upstreamUnavailable;
    } on TimeoutException {
      throw upstreamTimeout;
    } on FormatException {
      throw upstreamMalformed;
    }
  }
}

const spaceErrorStatus = <String, int>{
  'unauthenticated': 401,
  'forbidden': 403,
  'not_found': 404,
  'version_conflict': 409,
  'invalid_state': 409,
  'idempotency_conflict': 409,
  'source_deleted': 409,
  'stale_identity': 409,
  'stale_binding': 409,
  'validation_error': 422,
  'attachments_not_ready': 422,
  'payload_too_large': 413,
  'unsupported_media_type': 415,
  'storage_unavailable': 503,
  'upstream_unavailable': 502,
  'upstream_timeout': 504,
};
AuthFailure spaceFailure(int status, String code) =>
    AuthFailure(status: status, code: code, message: code);

/// Validate the generated schema subset used by Space; never a second protocol.
void validateSpace(
  String action,
  Map<String, dynamic> value, {
  String kind = 'request',
}) {
  final schema = spaceSchemas[action]?[kind] as Map<String, dynamic>?;
  if (schema == null) throw const FormatException('unknown space action');
  _validate(schema, value, schema);
  // Pydantic model validators beyond JSON Schema constraints.
  if (kind != 'response') {
    if (action == 'update_draft') {
      final ids = value['image_ids'] as List;
      if (ids.toSet().length != ids.length) {
        throw const FormatException('duplicate images');
      }
    }
    if (action == 'create_comment' &&
        (value['text'] as String).trim().isEmpty) {
      throw const FormatException('blank comment');
    }
  }
}

void _validate(Map<String, dynamic> s, Object? v, Map<String, dynamic> root) {
  Never bad() => throw const FormatException('space schema mismatch');
  if (s.containsKey(r'$ref')) {
    _validate(
      root[r'$defs'][(s[r'$ref'] as String).split('/').last]
          as Map<String, dynamic>,
      v,
      root,
    );
    return;
  }
  if (s['anyOf'] is List) {
    for (final branch in s['anyOf'] as List) {
      try {
        _validate(branch as Map<String, dynamic>, v, root);
        return;
      } on FormatException {
        /* try the next declared alternative */
      }
    }
    bad();
  }
  if (s.containsKey('const') && v != s['const']) bad();
  if (s['enum'] is List && !(s['enum'] as List).contains(v)) bad();
  switch (s['type']) {
    case 'object':
      if (v is! Map<String, dynamic>) bad();
      final properties = s['properties'] as Map<String, dynamic>;
      if ((s['required'] as List? ?? []).any((key) => !v.containsKey(key))) {
        bad();
      }
      if (s['additionalProperties'] == false &&
          v.keys.any((key) => !properties.containsKey(key))) {
        bad();
      }
      for (final key in v.keys) {
        if (properties.containsKey(key)) {
          _validate(properties[key] as Map<String, dynamic>, v[key], root);
        }
      }
    case 'string':
      if (v is! String) bad();
      final length = v.runes.length;
      if (length < (s['minLength'] as int? ?? 0) ||
          length > (s['maxLength'] as int? ?? 0x7fffffffffffffff)) {
        bad();
      }
      if (s['pattern'] is String && !RegExp(s['pattern'] as String).hasMatch(v)) {
        bad();
      }
    case 'integer':
      if (v is! int ||
          v < (s['minimum'] as num? ?? -double.infinity) ||
          v > (s['maximum'] as num? ?? double.infinity)) {
        bad();
      }
    case 'boolean':
      if (v is! bool) bad();
    case 'null':
      if (v != null) bad();
    case 'array':
      if (v is! List) bad();
      if (v.length < (s['minItems'] as int? ?? 0) ||
          v.length > (s['maxItems'] as int? ?? 0x7fffffffffffffff)) {
        bad();
      }
      for (final item in v) {
        _validate(s['items'] as Map<String, dynamic>, item, root);
      }
    default:
      bad();
  }
}
