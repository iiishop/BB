import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import '../models/auth_models.dart';
import '../models/chat_models.dart';

/// HTTP/WebSocket client for the server's STEP-3 chat REST surface.
///
/// The same transport runs in the Flutter UI, the standalone Dart control API
/// and widget/integration tests. No platform plugin and no server token ever
/// leaves the client process.
class ChatApiClient {
  ChatApiClient({
    required this.baseUri,
    this.timeout = const Duration(seconds: 15),
    this.mediaTimeout = const Duration(seconds: 120),
  });

  final Uri baseUri;
  final Duration timeout;

  /// Large media transfers get a longer bound than JSON calls.
  final Duration mediaTimeout;

  static const int maxJsonBytes = 8 * 1024 * 1024;
  static const int maxMediaResponseBytes = chatMaxUploadBytes + (1024 * 1024);

  // ---------------------------------------------------------------- REST ----

  Future<UserPage> listUsers({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    final Uri url = _query('/users', <String, String>{
      'after_account': afterAccount,
      if (limit != 50) 'limit': '$limit',
    });
    final _RawResponse response = await _send('GET', url, token: token);
    _requireSuccess(response, const <int>{200});
    return UserPage.fromJson(_decode(response.body));
  }

  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    if (content.isEmpty) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '正文不能为空',
      );
    }
    final _RawResponse response = await _send(
      'POST',
      _query('/messages'),
      token: token,
      payload: <String, dynamic>{
        'target_account': targetAccount,
        'client_nonce': clientNonce,
        'content': content.map((MessagePart p) => p.toJson()).toList(),
      },
    );
    _requireSuccess(response, const <int>{200});
    return ChatMessage.fromJson(_decode(response.body));
  }

  Future<ChatMessage> sendAttachment({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required String mediaId,
  }) async {
    final _RawResponse response = await _send(
      'POST',
      _query('/messages/attachments'),
      token: token,
      payload: <String, dynamic>{
        'target_account': targetAccount,
        'client_nonce': clientNonce,
        'media_id': mediaId,
      },
    );
    _requireSuccess(response, const <int>{200});
    return ChatMessage.fromJson(_decode(response.body));
  }

  /// One page of a pair's history.
  ///
  /// [afterPosition] and [beforePosition] are mutually exclusive; both
  /// directions return ascending items. Omitting both is the historical
  /// `after_position=0` call.
  Future<MessagePage> conversation({
    required String token,
    required String account,
    int? afterPosition = 0,
    int? beforePosition,
    int limit = 50,
  }) async {
    if (afterPosition != null && beforePosition != null) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'before_position 与 after_position 互斥',
      );
    }
    final Uri url = _query(
      '/conversations/${Uri.encodeComponent(account)}/messages',
      <String, String>{
        if (beforePosition != null)
          'before_position': '$beforePosition'
        else if ((afterPosition ?? 0) > 0)
          'after_position': '$afterPosition',
        if (limit != 50) 'limit': '$limit',
      },
    );
    final _RawResponse response = await _send('GET', url, token: token);
    _requireSuccess(response, const <int>{200});
    return MessagePage.fromJson(_decode(response.body));
  }

  /// Existing private conversations, peer-account keyset order.
  Future<ConversationRecordPage> conversations({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    final Uri url = _query('/conversations', <String, String>{
      'after_account': afterAccount,
      if (limit != 50) 'limit': '$limit',
    });
    final _RawResponse response = await _send('GET', url, token: token);
    _requireSuccess(response, const <int>{200});
    return ConversationRecordPage.fromJson(_decode(response.body));
  }

  /// Direct message lookup. 404 is the uniform safe miss for absent/forbidden.
  Future<ChatMessage?> messageById({
    required String token,
    required String messageId,
  }) async {
    final _RawResponse response = await _send(
      'GET',
      _query('/messages/${Uri.encodeComponent(messageId)}'),
      token: token,
    );
    if (response.status == 404) {
      return null;
    }
    _requireSuccess(response, const <int>{200});
    return ChatMessage.fromJson(_decode(response.body));
  }

  /// Direct context lookup from the same server query layer.
  Future<MessageContextRecord?> messageContext({
    required String token,
    required String messageId,
    int beforeLimit = 10,
    int afterLimit = 10,
  }) async {
    final _RawResponse response = await _send(
      'GET',
      _query(
        '/messages/${Uri.encodeComponent(messageId)}/context',
        <String, String>{
          if (beforeLimit != 10) 'before_limit': '$beforeLimit',
          if (afterLimit != 10) 'after_limit': '$afterLimit',
        },
      ),
      token: token,
    );
    if (response.status == 404) {
      return null;
    }
    _requireSuccess(response, const <int>{200});
    return MessageContextRecord.fromJson(_decode(response.body));
  }

  /// Returns null on 404 so a lost socket can query before retrying.
  Future<OperationResult?> getOperation({
    required String token,
    required String operationId,
  }) async {
    final _RawResponse response = await _send(
      'GET',
      _query('/operations/${Uri.encodeComponent(operationId)}'),
      token: token,
    );
    if (response.status == 404) {
      return null;
    }
    _requireSuccess(response, const <int>{200});
    return OperationResult.fromJson(_decode(response.body));
  }

  Future<Attachment> uploadMedia({
    required String token,
    required String targetAccount,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
    String? coverMediaId,
  }) async {
    if (bytes.length > chatMaxUploadBytes) {
      throw const AuthFailure(
        status: 413,
        code: 'payload_too_large',
        message: '文件超过 32 MiB 上限',
      );
    }
    final String safeName = _headerSafeFilename(filename);
    final String boundary =
        'bb-${DateTime.now().microsecondsSinceEpoch}-${bytes.length}';
    final BytesBuilder body = BytesBuilder(copy: false);
    void field(String name, String value) {
      body.add(utf8.encode('--$boundary\r\n'));
      body.add(
        utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'),
      );
      body.add(utf8.encode('$value\r\n'));
    }

    field('target_account', targetAccount);
    if (coverMediaId != null && coverMediaId.isNotEmpty) {
      field('cover_media_id', coverMediaId);
    }
    body.add(utf8.encode('--$boundary\r\n'));
    body.add(
      utf8.encode(
        'Content-Disposition: form-data; name="file"; filename="$safeName"\r\n',
      ),
    );
    body.add(utf8.encode('Content-Type: $mimeType\r\n\r\n'));
    body.add(bytes);
    body.add(utf8.encode('\r\n--$boundary--\r\n'));

    final _RawResponse response = await _sendRaw(
      'POST',
      _query('/media'),
      token: token,
      body: body.takeBytes(),
      contentType: ContentType(
        'multipart',
        'form-data',
        parameters: <String, String>{'boundary': boundary},
      ),
      timeout: mediaTimeout,
    );
    _requireSuccess(response, const <int>{200});
    return Attachment.fromJson(_decode(response.body));
  }

  /// Byte range read used for message images, covers and downloads.
  ///
  /// [onProgress] reports received bytes and the declared total (null when the
  /// server sent no length) while the body is still streaming, so the viewer
  /// can show real progress instead of an unbounded spinner.
  Future<MediaResponse> fetchMedia({
    required String token,
    required String mediaId,
    String? range,
    String? variant,
    void Function(int received, int? total)? onProgress,
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = mediaTimeout;
    try {
      final Uri url = _query(
        '/media/${Uri.encodeComponent(mediaId)}',
        variant == null || variant.isEmpty
            ? null
            : <String, String>{'variant': variant},
      );
      final HttpClientRequest request = await client
          .getUrl(url)
          .timeout(mediaTimeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (range != null && range.isNotEmpty) {
        request.headers.set(HttpHeaders.rangeHeader, range);
      }
      final HttpClientResponse response = await request.close().timeout(
        mediaTimeout,
      );
      // A 206 carries the full size in Content-Range; Content-Length is only
      // the size of this partial response.
      final int? declaredTotal =
          _contentRangeTotal(response) ?? _contentLength(response);
      final Uint8List bytes = await _readBytes(
        response,
        maxMediaResponseBytes,
        total: declaredTotal,
        onProgress: onProgress,
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw _decodeFailure(response.statusCode, utf8.decode(bytes));
      }
      return MediaResponse(
        status: response.statusCode,
        bytes: bytes,
        mimeType:
            response.headers.contentType?.mimeType ??
            'application/octet-stream',
        filename: _filenameFromDisposition(
          response.headers.value(HttpHeaders.contentDisposition),
        ),
        byteSize: declaredTotal,
      );
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

  /// `GET /media/{id}/metadata` (DEA-471): the shared `Media` DTO including
  /// the immutable original `byte_size`, without opening the original file or
  /// generating a thumbnail.
  Future<Attachment> fetchMediaMetadata({
    required String token,
    required String mediaId,
  }) async {
    final _RawResponse response = await _send(
      'GET',
      _query('/media/${Uri.encodeComponent(mediaId)}/metadata'),
      token: token,
    );
    _requireSuccess(response, const <int>{200});
    return Attachment.fromJson(_decode(response.body));
  }

  /// Header-only probe: requests a single byte to learn the type and filename
  /// without downloading the attachment original.
  Future<MediaProbe> probeMedia({
    required String token,
    required String mediaId,
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(_query('/media/${Uri.encodeComponent(mediaId)}'))
          .timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      await response.drain<void>();
      if (response.statusCode != 200 && response.statusCode != 206) {
        if (response.statusCode == 401) {
          throw unauthenticated;
        }
        if (response.statusCode == 404) {
          throw const AuthFailure(
            status: 404,
            code: 'not_found',
            message: '附件不存在或无权访问',
          );
        }
        throw _decodeFailure(response.statusCode, '');
      }
      return MediaProbe(
        mimeType:
            response.headers.contentType?.mimeType ??
            'application/octet-stream',
        filename: _filenameFromDisposition(
          response.headers.value(HttpHeaders.contentDisposition),
        ),
        byteSize: _contentRangeTotal(response) ?? _contentLength(response),
      );
    } on SocketException {
      throw upstreamUnavailable;
    } on HttpException {
      throw upstreamUnavailable;
    } on TimeoutException {
      throw upstreamTimeout;
    } finally {
      client.close(force: true);
    }
  }

  Future<ServerEventPage> events({
    required String token,
    int afterEventId = 0,
    int limit = 100,
  }) async {
    final Uri url = _query('/events', <String, String>{
      if (afterEventId > 0) 'after_event_id': '$afterEventId',
      if (limit != 100) 'limit': '$limit',
    });
    final _RawResponse response = await _send('GET', url, token: token);
    _requireSuccess(response, const <int>{200});
    return ServerEventPage.fromJson(_decode(response.body));
  }

  /// Hints only: the durable replay remains `GET /events`.
  Future<WebSocket> connectEvents(String token) async {
    final Uri ws = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/events',
      query: '',
    );
    return WebSocket.connect(
      ws.toString(),
      headers: <String, Object>{
        HttpHeaders.authorizationHeader: 'Bearer $token',
      },
    ).timeout(timeout);
  }

  // ------------------------------------------------------------- private ----

  Uri _query(String path, [Map<String, String>? params]) {
    final Uri base = baseUri.resolve(path);
    if (params == null || params.isEmpty) {
      return base;
    }
    return base.replace(queryParameters: params);
  }

  Future<_RawResponse> _send(
    String method,
    Uri url, {
    required String token,
    Map<String, dynamic>? payload,
  }) {
    List<int>? body;
    if (payload != null) {
      body = utf8.encode(jsonEncode(payload));
    }
    return _sendRaw(
      method,
      url,
      token: token,
      body: body,
      contentType: payload == null ? null : ContentType.json,
      timeout: timeout,
    );
  }

  Future<_RawResponse> _sendRaw(
    String method,
    Uri url, {
    required String token,
    List<int>? body,
    ContentType? contentType,
    required Duration timeout,
  }) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .openUrl(method, url)
          .timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = contentType ?? ContentType.json;
        request.contentLength = body.length;
        request.add(body);
      }
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String raw = await _readString(response, timeout);
      final String? retryAfter = response.headers.value('retry-after');
      return _RawResponse(
        response.statusCode,
        raw,
        retryAfterSeconds: int.tryParse(retryAfter ?? ''),
      );
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

  Future<String> _readString(
    HttpClientResponse response,
    Duration limit,
  ) async {
    if (response.statusCode == 204) {
      await response.drain<void>();
      return '';
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(limit)) {
      builder.add(chunk);
      if (builder.length > maxJsonBytes) {
        throw upstreamMalformed;
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<Uint8List> _readBytes(
    HttpClientResponse response,
    int maxBytes, {
    int? total,
    void Function(int received, int? total)? onProgress,
  }) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(mediaTimeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw upstreamMalformed;
      }
      onProgress?.call(builder.length, total);
    }
    return builder.takeBytes();
  }

  int? _contentLength(HttpClientResponse response) {
    final String? raw = response.headers.value(HttpHeaders.contentLengthHeader);
    return raw == null ? null : int.tryParse(raw);
  }

  /// Total size from `Content-Range: bytes 0-0/12345`.
  int? _contentRangeTotal(HttpClientResponse response) {
    final String? raw = response.headers.value(HttpHeaders.contentRangeHeader);
    if (raw == null) {
      return null;
    }
    final int slash = raw.lastIndexOf('/');
    if (slash < 0 || slash + 1 >= raw.length) {
      return null;
    }
    return int.tryParse(raw.substring(slash + 1).trim());
  }

  Map<String, dynamic> _decode(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // Fall through.
    }
    throw upstreamMalformed;
  }

  void _requireSuccess(_RawResponse response, Set<int> allowed) {
    if (allowed.contains(response.status)) {
      return;
    }
    throw _decodeFailure(
      response.status,
      response.body,
      retryAfterSeconds: response.retryAfterSeconds,
    );
  }

  AuthFailure _decodeFailure(
    int status,
    String rawBody, {
    int? retryAfterSeconds,
  }) {
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
                try {
                  fields.add(AuthFieldError.fromJson(entry));
                } on FormatException {
                  // Ignore malformed field entries.
                }
              }
            }
            return AuthFailure(
              status: status,
              code: code,
              message: message,
              fields: fields,
              retryAfterSeconds: retryAfterSeconds,
            );
          }
        }
      }
    } on FormatException {
      // Fall through.
    }
    if (status == 401) {
      return unauthenticated;
    }
    return upstreamMalformed;
  }

  static String _headerSafeFilename(String name) {
    final String base = name.replaceAll(RegExp(r'[\r\n"\\/]'), '_').trim();
    return base.isEmpty ? 'attachment' : base;
  }

  static String? _filenameFromDisposition(String? header) {
    if (header == null || header.isEmpty) {
      return null;
    }
    final RegExp extended = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    );
    final Match? star = extended.firstMatch(header);
    if (star != null) {
      try {
        final String decoded = Uri.decodeComponent(star.group(1)!);
        return decoded.isEmpty ? null : decoded;
      } on ArgumentError {
        // Fall through to the plain filename.
      }
    }
    final RegExp plain = RegExp(r'filename="?([^";]+)"?', caseSensitive: false);
    final Match? match = plain.firstMatch(header);
    final String? value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }
}

class _RawResponse {
  const _RawResponse(this.status, this.body, {this.retryAfterSeconds});

  final int status;
  final String body;
  final int? retryAfterSeconds;
}

/// Media bytes plus the server's content headers.
class MediaResponse {
  const MediaResponse({
    required this.status,
    required this.bytes,
    required this.mimeType,
    this.filename,
    this.byteSize,
  });

  final int status;
  final Uint8List bytes;
  final String mimeType;
  final String? filename;
  final int? byteSize;
}

/// Metadata probe result (no attachment original kept).
class MediaProbe {
  const MediaProbe({required this.mimeType, this.filename, this.byteSize});

  final String mimeType;
  final String? filename;

  /// Original size learned from `Content-Range`/`Content-Length` without
  /// downloading the bytes.
  final int? byteSize;
}

/// One durable server event. Only IDs/positions; never message bodies.
class ServerEvent {
  const ServerEvent({
    required this.eventId,
    required this.type,
    required this.occurredAt,
    required this.messageId,
    required this.peerAccount,
    required this.position,
  });

  final int eventId;
  final String type;
  final DateTime occurredAt;
  final String messageId;
  final String peerAccount;
  final int position;

  factory ServerEvent.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('event must be an object');
    }
    final Object? eventId = json['event_id'];
    final Object? type = json['type'];
    final Object? occurredAt = json['occurred_at'];
    final Object? messageId = json['message_id'];
    final Object? peer = json['peer_account'];
    final Object? position = json['position'];
    if (eventId is! int ||
        type is! String ||
        occurredAt is! String ||
        messageId is! String ||
        peer is! String ||
        position is! int) {
      throw const FormatException('event has invalid fields');
    }
    return ServerEvent(
      eventId: eventId,
      type: type,
      occurredAt: DateTime.parse(occurredAt).toUtc(),
      messageId: messageId,
      peerAccount: peer,
      position: position,
    );
  }
}

class ServerEventPage {
  const ServerEventPage({
    required this.items,
    required this.nextEventId,
    required this.hasMore,
  });

  final List<ServerEvent> items;
  final int nextEventId;
  final bool hasMore;

  factory ServerEventPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        json['next_event_id'] is! int ||
        json['has_more'] is! bool) {
      throw const FormatException('event page has invalid fields');
    }
    return ServerEventPage(
      items: List<ServerEvent>.unmodifiable(
        (json['items'] as List).map(ServerEvent.fromJson),
      ),
      nextEventId: json['next_event_id'] as int,
      hasMore: json['has_more'] as bool,
    );
  }
}
