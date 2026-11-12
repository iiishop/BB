import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:characters/characters.dart';

/// In-process FastAPI stand-in for widget/local-API tests.
///
/// This is a labelled double, not the real server. The real REST chain is
/// exercised by `live_chat_e2e_test.dart`; this backend exists so the local
/// control API and Flutter surfaces can run in the normal `flutter test` pass
/// without an external process.
class FakeChatBackend {
  FakeChatBackend._(this._server, this._users);

  static Future<FakeChatBackend> start({
    required Map<String, String> users,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final FakeChatBackend backend = FakeChatBackend._(
      server,
      Map<String, String>.from(users),
    );
    server.listen(backend._handle);
    return backend;
  }

  final HttpServer _server;
  final Map<String, String> _users;
  final Map<String, String> _presence = <String, String>{};
  final Map<String, List<_FakeMessage>> _pairs = <String, List<_FakeMessage>>{};
  final Map<String, _FakeMedia> _media = <String, _FakeMedia>{};
  final Map<String, _FakeOperation> _operations = <String, _FakeOperation>{};
  final List<_FakeEvent> _events = <_FakeEvent>[];
  final Map<String, String> _tokens = <String, String>{};
  final Map<String, String> _requestDigests = <String, String>{};

  /// One-shot injected failure for retry tests.
  int failNextSendStatus = 0;
  int _messageSeq = 0;
  int _mediaSeq = 0;
  String? lastMediaRange;
  int _eventSeq = 0;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  String tokenFor(String account) {
    final String token = 'tok-$account';
    _tokens[token] = account;
    return token;
  }

  void setPresence(String account, {required bool online}) {
    _presence[account] = online ? 'online' : 'offline';
  }

  /// Pre-populates a message for UI/screenshot tests.
  Future<String> seedMessage({
    required String sender,
    required String target,
    required String text,
    String? mediaId,
  }) async {
    final _FakeMessage message = _appendMessage(
      sender: sender,
      target: target,
      kind: 'body',
      content: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
        if (mediaId != null)
          <String, dynamic>{'type': 'image', 'media_id': mediaId},
      ],
    );
    _appendEvent(message);
    return message.id;
  }

  Future<String> addImage({
    required String owner,
    required String peer,
    required Uint8List bytes,
    String filename = 'image.png',
  }) {
    return addMedia(
      owner: owner,
      peer: peer,
      bytes: bytes,
      mime: 'image/png',
      kind: 'image',
      filename: filename,
    );
  }

  Future<String> addMedia({
    required String owner,
    required String peer,
    required Uint8List bytes,
    required String mime,
    required String kind,
    required String filename,
    String? coverId,
  }) async {
    final String id = 'seed-media-${++_mediaSeq}';
    _media[id] = _FakeMedia(
      id: id,
      owner: owner,
      peer: peer,
      mime: mime,
      kind: kind,
      filename: filename,
      bytes: bytes,
      coverId: coverId,
    );
    return id;
  }

  Future<void> close() => _server.close(force: true);

  // ------------------------------------------------------------- transport --

  Future<void> _handle(HttpRequest request) async {
    try {
      final String path = request.uri.path;
      final String? account = _authenticated(request);
      if (account == null) {
        await _error(request, 401, 'unauthenticated');
        return;
      }
      if (request.method == 'GET' && path == '/users') {
        await _listUsers(request, account);
        return;
      }
      if (request.method == 'POST' && path == '/messages') {
        await _sendMessage(request, account);
        return;
      }
      if (request.method == 'POST' && path == '/messages/attachments') {
        await _sendAttachment(request, account);
        return;
      }
      if (request.method == 'POST' && path == '/media') {
        await _uploadMedia(request, account);
        return;
      }
      if (request.method == 'GET' && path == '/events') {
        await _eventsPage(request, account);
        return;
      }
      final RegExp conversation = RegExp(r'^/conversations/([^/]+)/messages$');
      final Match? conversationMatch = conversation.firstMatch(path);
      if (request.method == 'GET' && conversationMatch != null) {
        await _conversation(request, account, conversationMatch.group(1)!);
        return;
      }
      final RegExp operation = RegExp(r'^/operations/([^/]+)$');
      final Match? operationMatch = operation.firstMatch(path);
      if (request.method == 'GET' && operationMatch != null) {
        await _operation(request, account, operationMatch.group(1)!);
        return;
      }
      final RegExp media = RegExp(r'^/media/([^/]+)$');
      final Match? mediaMatch = media.firstMatch(path);
      if (request.method == 'GET' && mediaMatch != null) {
        await _mediaGet(request, account, mediaMatch.group(1)!);
        return;
      }
      await _error(request, 404, 'not_found');
    } catch (_) {
      await _error(request, 500, 'internal_error');
    }
  }

  String? _authenticated(HttpRequest request) {
    final String? header = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    if (header == null || !header.startsWith('Bearer ')) {
      return null;
    }
    return _tokens[header.substring(7)];
  }

  Future<Map<String, dynamic>> _json(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    if (raw.isEmpty) {
      return <String, dynamic>{};
    }
    final Object? decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<void> _write(HttpRequest request, int status, Object body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _error(HttpRequest request, int status, String code) {
    return _write(request, status, <String, dynamic>{
      'error': <String, dynamic>{
        'code': code,
        'message': code,
        'fields': <Object>[],
      },
    });
  }

  // --------------------------------------------------------------- handlers --

  Future<void> _listUsers(HttpRequest request, String account) async {
    final int limit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
    final String after = request.uri.queryParameters['after_account'] ?? '';
    final List<String> accounts =
        _users.keys
            .where((String candidate) => candidate != account)
            .where(
              (String candidate) =>
                  after.isEmpty || candidate.compareTo(after) > 0,
            )
            .toList()
          ..sort();
    final List<String> page = accounts.take(limit).toList();
    final String? next = accounts.length > page.length ? page.last : null;
    await _write(request, 200, <String, dynamic>{
      'items': <Map<String, dynamic>>[
        for (final String peer in page)
          <String, dynamic>{
            'account': peer,
            'username': _users[peer],
            'avatar_url': '/avatars/$peer.png',
            'avatar_version': 'v1',
            'presence': _presence[peer] ?? 'online',
            'last_contact_at': _lastMessage(
              account,
              peer,
            )?.createdAt.toIso8601String(),
            'last_message': _preview(account, peer),
          },
      ],
      'next_cursor': next,
    });
  }

  Map<String, dynamic>? _preview(String me, String peer) {
    final _FakeMessage? message = _lastMessage(me, peer);
    if (message == null) {
      return null;
    }
    return <String, dynamic>{
      'id': message.id,
      'sender_account': message.sender,
      'sender_username': _users[message.sender] ?? message.sender,
      'preview_body': _previewBody(message),
    };
  }

  String _previewBody(_FakeMessage message) {
    final StringBuffer buffer = StringBuffer();
    if (message.kind == 'body') {
      for (final Map<String, dynamic> part in message.content) {
        if (part['type'] == 'text') {
          buffer.write(part['text']);
        } else {
          buffer.write('[图片]');
        }
      }
    } else {
      final Map<String, dynamic> attachment =
          message.attachment ?? <String, dynamic>{};
      final String mime = (attachment['mime_type'] as String?) ?? '';
      final String label = mime.startsWith('video/')
          ? '[视频]'
          : mime.startsWith('audio/')
          ? '[音频]'
          : '[文件]';
      buffer.write('$label${attachment['filename'] ?? ''}');
    }
    final String text = buffer.toString();
    final int count = text.characters.length;
    return count <= 20 ? text : '${text.characters.take(20)}…';
  }

  _FakeMessage? _lastMessage(String a, String b) {
    final List<_FakeMessage> list = _pair(a, b);
    return list.isEmpty ? null : list.last;
  }

  List<_FakeMessage> _pair(String a, String b) {
    final List<String> keys = <String>[a, b]..sort();
    return _pairs.putIfAbsent(keys.join('|'), () => <_FakeMessage>[]);
  }

  Future<void> _sendMessage(HttpRequest request, String account) async {
    final Map<String, dynamic> body = await _json(request);
    final Object? target = body['target_account'];
    final Object? nonce = body['client_nonce'];
    final Object? content = body['content'];
    if (target is! String ||
        nonce is! String ||
        content is! List ||
        content.isEmpty ||
        !_users.containsKey(target) ||
        target == account) {
      await _error(request, 422, 'validation_error');
      return;
    }
    if (failNextSendStatus != 0) {
      final int status = failNextSendStatus;
      failNextSendStatus = 0;
      await _error(request, status, 'storage_unavailable');
      return;
    }
    final String digest = jsonEncode(<String, dynamic>{
      'target': target,
      'content': content,
    });
    final String opKey = '$account\u0001$nonce';
    final _FakeOperation? prior = _operations[opKey];
    if (prior != null) {
      if (_requestDigests[opKey] != digest) {
        await _error(request, 409, 'conflict');
        return;
      }
      await _write(request, 200, prior.message!);
      return;
    }
    final _FakeMessage message = _appendMessage(
      sender: account,
      target: target,
      kind: 'body',
      content: content.cast<Map<String, dynamic>>(),
    );
    _operations[opKey] = _FakeOperation(
      account: account,
      nonce: nonce,
      kind: 'message',
      message: _messageJson(message),
    );
    _requestDigests[opKey] = digest;
    _appendEvent(message);
    await _write(request, 200, _messageJson(message));
  }

  Future<void> _sendAttachment(HttpRequest request, String account) async {
    final Map<String, dynamic> body = await _json(request);
    final Object? target = body['target_account'];
    final Object? nonce = body['client_nonce'];
    final Object? mediaId = body['media_id'];
    if (target is! String ||
        nonce is! String ||
        mediaId is! String ||
        !_users.containsKey(target) ||
        target == account ||
        !_media.containsKey(mediaId)) {
      await _error(request, 422, 'validation_error');
      return;
    }
    final _FakeMedia media = _media[mediaId]!;
    if (media.kind == 'image') {
      await _error(request, 422, 'validation_error');
      return;
    }
    final String digest = '$target\u0001$mediaId';
    final String opKey = '$account\u0001$nonce';
    final _FakeOperation? prior = _operations[opKey];
    if (prior != null) {
      if (_requestDigests[opKey] != digest) {
        await _error(request, 409, 'conflict');
        return;
      }
      await _write(request, 200, prior.message!);
      return;
    }
    final _FakeMessage message = _appendMessage(
      sender: account,
      target: target,
      kind: 'attachment',
      attachment: _mediaJson(media),
    );
    _operations[opKey] = _FakeOperation(
      account: account,
      nonce: nonce,
      kind: 'message',
      message: _messageJson(message),
    );
    _requestDigests[opKey] = digest;
    _appendEvent(message);
    await _write(request, 200, _messageJson(message));
  }

  _FakeMessage _appendMessage({
    required String sender,
    required String target,
    required String kind,
    List<Map<String, dynamic>> content = const <Map<String, dynamic>>[],
    Map<String, dynamic>? attachment,
  }) {
    final List<_FakeMessage> pair = _pair(sender, target);
    final _FakeMessage message = _FakeMessage(
      id: 'm${++_messageSeq}',
      position: pair.length + 1,
      sender: sender,
      target: target,
      createdAt: DateTime.now().toUtc(),
      kind: kind,
      content: content,
      attachment: attachment,
    );
    pair.add(message);
    return message;
  }

  void _appendEvent(_FakeMessage message) {
    for (final String account in <String>[message.sender, message.target]) {
      _events.add(
        _FakeEvent(
          id: ++_eventSeq,
          account: account,
          messageId: message.id,
          peer: account == message.sender ? message.target : message.sender,
          position: message.position,
          occurredAt: message.createdAt,
        ),
      );
    }
  }

  Map<String, dynamic> _messageJson(_FakeMessage message) {
    return <String, dynamic>{
      'id': message.id,
      'position': message.position,
      'sender_account': message.sender,
      'target_account': message.target,
      'created_at': message.createdAt.toIso8601String(),
      'kind': message.kind,
      'content': message.kind == 'body' ? message.content : null,
      'attachment': message.attachment,
    };
  }

  Map<String, dynamic> _mediaJson(_FakeMedia media) {
    return <String, dynamic>{
      'media_id': media.id,
      'media_type': media.kind,
      'filename': media.filename,
      'mime_type': media.mime,
      'byte_size': media.bytes.length,
      'cover_media_id': media.coverId,
    };
  }

  Future<void> _conversation(
    HttpRequest request,
    String account,
    String peer,
  ) async {
    if (!_users.containsKey(peer) || peer == account) {
      await _error(request, 404, 'not_found');
      return;
    }
    final int after =
        int.tryParse(request.uri.queryParameters['after_position'] ?? '') ?? 0;
    final int limit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
    final List<_FakeMessage> list = _pair(
      account,
      peer,
    ).where((_FakeMessage message) => message.position > after).toList();
    final List<_FakeMessage> page = list.take(limit).toList();
    await _write(request, 200, <String, dynamic>{
      'items': page.map(_messageJson).toList(),
      'next_position': page.isEmpty ? after : page.last.position,
      'has_more': list.length > page.length,
    });
  }

  Future<void> _operation(
    HttpRequest request,
    String account,
    String operationId,
  ) async {
    final _FakeOperation? op = _operations['$account\u0001$operationId'];
    if (op == null) {
      await _error(request, 404, 'not_found');
      return;
    }
    if (op.kind == 'message') {
      await _write(request, 200, <String, dynamic>{
        'operation_id': operationId,
        'kind': 'message',
        'status': 'succeeded',
        'message': op.message,
        'task_id': null,
        'error_code': null,
      });
      return;
    }
    await _error(request, 404, 'not_found');
  }

  Future<void> _eventsPage(HttpRequest request, String account) async {
    final int after =
        int.tryParse(request.uri.queryParameters['after_event_id'] ?? '') ?? 0;
    final int limit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 100;
    final List<_FakeEvent> list = _events
        .where((_FakeEvent event) => event.account == account)
        .where((_FakeEvent event) => event.id > after)
        .toList();
    final List<_FakeEvent> page = list.take(limit).toList();
    await _write(request, 200, <String, dynamic>{
      'items': <Map<String, dynamic>>[
        for (final _FakeEvent event in page)
          <String, dynamic>{
            'version': 1,
            'event_id': event.id,
            'type': 'message.available',
            'occurred_at': event.occurredAt.toIso8601String(),
            'message_id': event.messageId,
            'peer_account': event.peer,
            'position': event.position,
          },
      ],
      'next_event_id': page.isEmpty ? after : page.last.id,
      'has_more': list.length > page.length,
    });
  }

  Future<void> _uploadMedia(HttpRequest request, String account) async {
    final String? boundary =
        request.headers.contentType?.parameters['boundary'];
    if (boundary == null) {
      await _error(request, 415, 'unsupported_media_type');
      return;
    }
    final Uint8List body = await _readBytes(request);
    final _Multipart multipart = _parseMultipart(body, boundary);
    final String? target = multipart.fields['target_account'];
    final _MultipartPart? file = multipart.file;
    if (target == null ||
        file == null ||
        !_users.containsKey(target) ||
        target == account) {
      await _error(request, 422, 'validation_error');
      return;
    }
    final String mime = file.contentType ?? 'application/octet-stream';
    final String kind = _kindForMime(mime);
    if (kind == 'unsupported') {
      await _error(request, 415, 'unsupported_media_type');
      return;
    }
    if (kind == 'image' && !_looksLikeImage(file.bytes)) {
      await _error(request, 415, 'unsupported_media_type');
      return;
    }
    if (mime == 'application/pdf' &&
        !_startsWith(file.bytes, utf8.encode('%PDF-'))) {
      await _error(request, 415, 'unsupported_media_type');
      return;
    }
    if (mime == 'video/mp4' &&
        !(file.bytes.length >= 8 &&
            String.fromCharCodes(file.bytes.sublist(4, 8)) == 'ftyp')) {
      await _error(request, 415, 'unsupported_media_type');
      return;
    }
    if (kind == 'video' && (multipart.fields['cover_media_id'] ?? '').isEmpty) {
      await _error(request, 422, 'validation_error');
      return;
    }
    final String id = 'media-${++_mediaSeq}';
    final _FakeMedia created = _FakeMedia(
      id: id,
      owner: account,
      peer: target,
      mime: mime,
      kind: kind,
      filename: file.filename,
      bytes: file.bytes,
      coverId: multipart.fields['cover_media_id'],
    );
    _media[id] = created;
    await _write(request, 200, _mediaJson(created));
  }

  Future<void> _mediaGet(
    HttpRequest request,
    String account,
    String mediaId,
  ) async {
    final _FakeMedia? media = _media[mediaId];
    if (media == null || (media.owner != account && media.peer != account)) {
      await _error(request, 404, 'not_found');
      return;
    }
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    lastMediaRange = range;
    final HttpResponse response = request.response;
    response.headers.set(HttpHeaders.contentTypeHeader, media.mime);
    response.headers.set(
      HttpHeaders.contentDisposition,
      'attachment; filename="${media.filename}"',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
    final RegExpMatch? rangeMatch = range == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (rangeMatch != null && media.bytes.isNotEmpty) {
      final int start = int.parse(rangeMatch.group(1)!);
      final int requestedEnd = rangeMatch.group(2)!.isEmpty
          ? media.bytes.length - 1
          : int.parse(rangeMatch.group(2)!);
      final int end = requestedEnd >= media.bytes.length
          ? media.bytes.length - 1
          : requestedEnd;
      if (start > end) {
        response.statusCode = 416;
        await response.close();
        return;
      }
      response.statusCode = 206;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${media.bytes.length}',
      );
      response.contentLength = end - start + 1;
      response.add(media.bytes.sublist(start, end + 1));
    } else {
      response.statusCode = 200;
      response.contentLength = media.bytes.length;
      response.add(media.bytes);
    }
    await response.close();
  }

  Future<Uint8List> _readBytes(HttpRequest request) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static String _kindForMime(String mime) {
    if (mime.startsWith('image/')) {
      return 'image';
    }
    if (mime.startsWith('video/')) {
      return 'video';
    }
    if (mime.startsWith('audio/')) {
      return 'audio';
    }
    if (mime == 'application/pdf' || mime.startsWith('text/')) {
      return 'document';
    }
    if (mime == 'application/octet-stream') {
      return 'other';
    }
    return 'unsupported';
  }

  static bool _looksLikeImage(Uint8List bytes) {
    return _startsWith(bytes, const <int>[0x89, 0x50, 0x4E, 0x47]) ||
        _startsWith(bytes, const <int>[0xFF, 0xD8, 0xFF]) ||
        (_startsWith(bytes, utf8.encode('RIFF')) &&
            bytes.length > 12 &&
            String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP');
  }

  static bool _startsWith(Uint8List value, List<int> prefix) {
    if (value.length < prefix.length) {
      return false;
    }
    for (int i = 0; i < prefix.length; i++) {
      if (value[i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  static _Multipart _parseMultipart(Uint8List body, String boundary) {
    final List<int> delimiter = utf8.encode('--$boundary');
    final List<int> separator = const <int>[13, 10, 13, 10];
    final Map<String, String> fields = <String, String>{};
    _MultipartPart? file;
    int cursor = 0;
    while (true) {
      final int start = _indexOf(body, delimiter, cursor);
      if (start < 0) {
        break;
      }
      int partStart = start + delimiter.length;
      if (partStart + 1 < body.length &&
          body[partStart] == 45 &&
          body[partStart + 1] == 45) {
        break;
      }
      if (partStart + 1 < body.length &&
          body[partStart] == 13 &&
          body[partStart + 1] == 10) {
        partStart += 2;
      }
      final int next = _indexOf(body, delimiter, partStart);
      if (next < 0) {
        break;
      }
      int partEnd = next;
      if (partEnd >= 2 && body[partEnd - 2] == 13 && body[partEnd - 1] == 10) {
        partEnd -= 2;
      }
      final int headerEnd = _indexOf(body, separator, partStart);
      if (headerEnd < 0 || headerEnd > partEnd) {
        cursor = next;
        continue;
      }
      final String headers = latin1.decode(body.sublist(partStart, headerEnd));
      final Uint8List value = body.sublist(headerEnd + 4, partEnd);
      String? name;
      String? filename;
      String? contentType;
      for (final String line in headers.split('\r\n')) {
        final String lower = line.toLowerCase();
        if (lower.startsWith('content-disposition:')) {
          name = _quoted(line, 'name=');
          filename = _quoted(line, 'filename=');
        } else if (lower.startsWith('content-type:')) {
          contentType = line.substring(line.indexOf(':') + 1).trim();
        }
      }
      if (name != null) {
        if (filename != null) {
          file = _MultipartPart(
            filename: filename,
            bytes: value,
            contentType: contentType,
          );
        } else {
          fields[name] = utf8.decode(value, allowMalformed: true);
        }
      }
      cursor = next;
    }
    return _Multipart(fields: fields, file: file);
  }

  static String? _quoted(String line, String key) {
    final int index = line.indexOf(key);
    if (index < 0) {
      return null;
    }
    final int start = index + key.length;
    if (start >= line.length) {
      return null;
    }
    final String quote = line[start] == '"' ? '"' : '';
    final int valueStart = quote.isEmpty ? start : start + 1;
    final int end = quote.isEmpty
        ? line.indexOf(';', valueStart)
        : line.indexOf('"', valueStart);
    return line.substring(valueStart, end < 0 ? line.length : end);
  }

  static int _indexOf(List<int> data, List<int> pattern, [int start = 0]) {
    for (int i = start; i <= data.length - pattern.length; i++) {
      bool matched = true;
      for (int j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }
}

class _FakeMessage {
  _FakeMessage({
    required this.id,
    required this.position,
    required this.sender,
    required this.target,
    required this.createdAt,
    required this.kind,
    required this.content,
    this.attachment,
  });

  final String id;
  final int position;
  final String sender;
  final String target;
  final DateTime createdAt;
  final String kind;
  final List<Map<String, dynamic>> content;
  final Map<String, dynamic>? attachment;
}

class _FakeMedia {
  _FakeMedia({
    required this.id,
    required this.owner,
    required this.peer,
    required this.mime,
    required this.kind,
    required this.filename,
    required this.bytes,
    this.coverId,
  });

  final String id;
  final String owner;
  final String peer;
  final String mime;
  final String kind;
  final String filename;
  final Uint8List bytes;
  final String? coverId;
}

class _FakeOperation {
  _FakeOperation({
    required this.account,
    required this.nonce,
    required this.kind,
    this.message,
  });

  final String account;
  final String nonce;
  final String kind;
  final Map<String, dynamic>? message;
}

class _FakeEvent {
  _FakeEvent({
    required this.id,
    required this.account,
    required this.messageId,
    required this.peer,
    required this.position,
    required this.occurredAt,
  });

  final int id;
  final String account;
  final String messageId;
  final String peer;
  final int position;
  final DateTime occurredAt;
}

class _Multipart {
  _Multipart({required this.fields, this.file});

  final Map<String, String> fields;
  final _MultipartPart? file;
}

class _MultipartPart {
  _MultipartPart({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String filename;
  final Uint8List bytes;
  final String? contentType;
}
