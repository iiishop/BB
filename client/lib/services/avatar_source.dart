import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/auth_models.dart';
import '../validation/profile_rules.dart';

/// Avatar byte sources used by `update_avatar`.
///
/// All three sources are resolved by the client (never by the MCP plugin) and
/// bounded to 5 MiB before anything is uploaded to the server:
/// * [readPath] reads a bounded local file (POSIX or Windows absolute path);
/// * [readUrl] downloads over http(s), following redirects manually so every
///   hop's scheme can be checked, with a timeout and without forwarding any
///   session/server Authorization header;
/// * [readBase64] decodes raw base64 or a `data:image/...;base64,` payload.
abstract class AvatarSourceReader {
  Future<Uint8List> readPath(String path);

  Future<Uint8List> readUrl(String url);

  Future<Uint8List> readBase64(String payload);
}

/// Shared limit: 5 MiB, matching the server's `MAX_AVATAR_BYTES`.
const int maxAvatarBytes = 5 * 1024 * 1024;

AuthFailure _failure(
  int status,
  String code,
  String message, {
  AuthFieldError? field,
}) {
  return AuthFailure(
    status: status,
    code: code,
    message: message,
    fields: field == null ? const <AuthFieldError>[] : <AuthFieldError>[field],
  );
}

AuthFailure _sourceError(String source, String code, String message) {
  return _failure(
    422,
    'validation_error',
    message,
    field: AuthFieldError(field: source, code: code, message: message),
  );
}

/// Detected image MIME type (`image/png`, `image/jpeg`, `image/webp`) or null.
String? detectImageMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// Rejects empty bytes, oversized data and non-image magic bytes.
void validateAvatarBytes(Uint8List bytes, {required String sourceField}) {
  if (bytes.isEmpty) {
    throw _sourceError(sourceField, 'required', '头像内容为空');
  }
  if (bytes.length > maxAvatarBytes) {
    throw _failure(413, 'payload_too_large', '头像超过 5 MB 上限');
  }
  if (detectImageMime(bytes) == null) {
    throw _failure(
      415,
      'unsupported_media_type',
      '仅支持 PNG、JPEG 或 WebP 图片',
      field: AuthFieldError(
        field: sourceField,
        code: 'format',
        message: '仅支持 PNG、JPEG 或 WebP 图片',
      ),
    );
  }
}

/// Default production implementation backed by `dart:io`.
class DefaultAvatarSourceReader implements AvatarSourceReader {
  DefaultAvatarSourceReader({
    this.timeout = const Duration(seconds: 10),
    this.maxRedirects = 5,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final Duration timeout;
  final int maxRedirects;
  final HttpClient Function() _clientFactory;

  @override
  Future<Uint8List> readPath(String path) async {
    if (!isAbsoluteAvatarPath(path)) {
      throw _sourceError('path', 'format', '必须为本机绝对路径');
    }
    final File file = File(path);
    try {
      final int length = await file.length();
      if (length > maxAvatarBytes) {
        throw _failure(413, 'payload_too_large', '头像超过 5 MB 上限');
      }
      final Uint8List bytes = await file.readAsBytes();
      validateAvatarBytes(bytes, sourceField: 'path');
      return bytes;
    } on AuthFailure {
      rethrow;
    } on FileSystemException {
      throw _sourceError('path', 'unreadable', '无法读取该本机路径');
    }
  }

  @override
  Future<Uint8List> readUrl(String url) async {
    if (!isSupportedAvatarUrl(url)) {
      throw _sourceError('url', 'format', '必须为有效 http/https URL');
    }
    final HttpClient client = _clientFactory()..connectionTimeout = timeout;
    Uri current = Uri.parse(url);
    try {
      for (int hop = 0; hop <= maxRedirects; hop++) {
        if (current.scheme != 'http' && current.scheme != 'https') {
          throw _sourceError('url', 'format', '重定向目标必须是 http/https');
        }
        final HttpClientRequest request = await client
            .getUrl(current)
            .timeout(timeout);
        request.followRedirects = false;
        // Never forward a session or server credential to an avatar URL.
        request.headers.removeAll(HttpHeaders.authorizationHeader);
        final HttpClientResponse response = await request.close().timeout(
          timeout,
        );
        final int status = response.statusCode;
        if (status >= 300 && status < 400) {
          final String? location = response.headers.value(
            HttpHeaders.locationHeader,
          );
          await response.drain<void>().catchError((_) {});
          if (location == null || location.isEmpty) {
            throw _sourceError('url', 'format', '重定向缺少 Location');
          }
          current = current.resolve(location);
          continue;
        }
        if (status != HttpStatus.ok) {
          await response.drain<void>().catchError((_) {});
          throw _failure(502, 'upstream_unavailable', '图片下载失败（HTTP $status）');
        }
        final Uint8List bytes = await _readBounded(response);
        validateAvatarBytes(bytes, sourceField: 'url');
        return bytes;
      }
      throw _sourceError('url', 'format', '重定向次数过多');
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

  @override
  Future<Uint8List> readBase64(String payload) async {
    String encoded = payload;
    final RegExp dataPrefix = RegExp(
      r'^data:image/[A-Za-z0-9.+-]+;base64,',
      caseSensitive: false,
    );
    final Match? match = dataPrefix.firstMatch(encoded);
    if (match != null) {
      encoded = encoded.substring(match.end);
    }
    encoded = encoded.replaceAll(RegExp(r'\s+'), '');
    if (encoded.isEmpty) {
      throw _sourceError('base64', 'required', '此字段必填');
    }
    // A regex over a multi-megabyte base64 string can exhaust the stack, so
    // validate with the decoder and map its FormatException instead.
    final String normalized = encoded.replaceAll('-', '+').replaceAll('_', '/');
    final String padded = normalized.padRight(
      normalized.length + (4 - normalized.length % 4) % 4,
      '=',
    );
    Uint8List bytes;
    try {
      bytes = base64Decode(padded);
    } on FormatException {
      throw _sourceError('base64', 'format', 'base64 内容无效');
    }
    validateAvatarBytes(bytes, sourceField: 'base64');
    return bytes;
  }

  Future<Uint8List> _readBounded(HttpClientResponse response) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxAvatarBytes) {
        throw _failure(413, 'payload_too_large', '头像超过 5 MB 上限');
      }
    }
    return builder.takeBytes();
  }
}
