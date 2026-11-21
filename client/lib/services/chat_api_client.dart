import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'http_transport.dart';

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

  /// Reused across calls so the TLS connection is not rebuilt per request.
  late final HttpTransport _http = HttpTransport(connectionTimeout: timeout);

  static const int maxJsonBytes = 8 * 1024 * 1024;
  static const int maxMediaResponseBytes = chatMaxUploadBytes + (1024 * 1024);

  // ---------------------------------------------------------------- REST ----

  Future<int> eventHead({required String token}) async {
    final _RawResponse response = await _send(
      'GET',
      _query('/events/head'),
      token: token,
    );
    _requireSuccess(response, const <int>{200});
    final Object? value = _decode(response.body)['event_id'];
    if (value is! int || value < 0) throw upstreamMalformed;
    return value;
  }

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
    return ChatMessage.fromJson(_decodeMessages(response));
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
    return ChatMessage.fromJson(_decodeMessages(response));
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
    return MessagePage.fromJson(_decodeMessages(response));
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
    return ConversationRecordPage.fromJson(_decodeMessages(response));
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
    return ChatMessage.fromJson(_decodeMessages(response));
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
    return MessageContextRecord.fromJson(_decodeMessages(response));
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
    return OperationResult.fromJson(_decodeMessages(response));
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
    final response = await _http.send(
      'GET',
      _query(
        '/media/${Uri.encodeComponent(mediaId)}',
        variant == null || variant.isEmpty ? null : {'variant': variant},
      ),
      service: 'chat',
      timeout: mediaTimeout,
      maxBytes: maxMediaResponseBytes,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        if (range != null && range.isNotEmpty) HttpHeaders.rangeHeader: range,
      },
      onProgress: onProgress,
    );
    if (response.status != 200 && response.status != 206) {
      throw _decodeFailure(response.status, utf8.decode(response.bytes));
    }
    return MediaResponse(
      status: response.status,
      bytes: response.bytes,
      mimeType: ContentType.parse(
        response.headers['content-type'] ?? 'application/octet-stream',
      ).mimeType,
      filename: _filenameFromDisposition(
        response.headers[HttpHeaders.contentDisposition],
      ),
      byteSize: response.totalBytes,
    );
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
    final response = await _http.send(
      'GET',
      _query('/media/${Uri.encodeComponent(mediaId)}'),
      service: 'chat',
      timeout: timeout,
      maxBytes: maxMediaResponseBytes,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        HttpHeaders.rangeHeader: 'bytes=0-0',
      },
    );
    if (response.status != 200 && response.status != 206) {
      if (response.status == 401) throw unauthenticated;
      if (response.status == 404) {
        throw const AuthFailure(
          status: 404,
          code: 'not_found',
          message: '附件不存在或无权访问',
        );
      }
      throw _decodeFailure(response.status, '');
    }
    return MediaProbe(
      mimeType: ContentType.parse(
        response.headers['content-type'] ?? 'application/octet-stream',
      ).mimeType,
      filename: _filenameFromDisposition(
        response.headers[HttpHeaders.contentDisposition],
      ),
      byteSize: response.totalBytes,
    );
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
    // Dedicated handshake client: unlike Future.timeout alone this closes a
    // stalled upgrade. Successful WebSockets detach their socket from the pool.
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await WebSocket.connect(
        ws.toString(),
        customClient: client,
        headers: <String, Object>{
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
      ).timeout(
        timeout,
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('WebSocket handshake deadline');
        },
      );
    } finally {
      client.close();
    }
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
    final response = await _http.send(
      method,
      url,
      service: 'chat',
      timeout: timeout,
      maxBytes: maxJsonBytes,
      headers: {
        HttpHeaders.authorizationHeader: 'Bearer $token',
        'X-BB-Message-Association': '1',
        if (body != null)
          HttpHeaders.contentTypeHeader: (contentType ?? ContentType.json)
              .toString(),
      },
      body: body,
    );
    return _RawResponse(
      response.status,
      utf8.decode(response.bytes, allowMalformed: true),
      retryAfterSeconds: int.tryParse(response.headers['retry-after'] ?? ''),
      association: response.headers['x-bb-message-association'] == '1',
    );
  }

  Map<String, dynamic> _decodeMessages(_RawResponse response) {
    final value = _decode(response.body);
    // Only a negotiated response can supply association evidence.
    if (!response.association) {
      void strip(Object? node) {
        if (node is Map<String, dynamic>) {
          if (node.containsKey('sender_account') &&
              node.containsKey('target_account')) {
            node.remove('operation_id');
          }
          for (final child in node.values) {
            strip(child);
          }
        } else if (node is List) {
          for (final child in node) {
            strip(child);
          }
        }
      }

      strip(value);
    }
    return value;
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
  const _RawResponse(
    this.status,
    this.body, {
    this.retryAfterSeconds,
    this.association = false,
  });

  final bool association;

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
