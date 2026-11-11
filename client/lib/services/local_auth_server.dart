import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'dart:io';

import '../config/client_config.dart';
import '../models/auth_models.dart';
import '../models/chat_models.dart';
import '../models/profile_models.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/media_source.dart';
import '../services/profile_service.dart';
import '../validation/profile_rules.dart';

/// Loopback-only local control API used by the DSH MCP plugin.
///
/// It reuses [AuthService] and [ProfileGateway], so the UI, the standalone Dart
/// entry and the plugin share one implementation:
///
/// * `POST /auth/register` -> 201 `{account, username}`
/// * `POST /auth/login`    -> 200 `{account, username}` (token never leaves the
///   client process)
/// * `POST /profile/view_avatar|update_avatar|view_nickname|update_nickname|`
///   `view_signature|update_signature`
///
/// Errors keep the server contract: 422 `validation_error` with `fields`,
/// 401 `invalid_credentials`/`unauthenticated`, 413/415 for media, and
/// 502/504 when the server cannot be reached. The session token is never part
/// of a response.
class LocalAuthServer {
  LocalAuthServer({
    required this.service,
    this.profile,
    this.chat,
    this.host = loopbackHost,
    this.port = defaultLocalPort,
    this.onSessionEstablished,
    this.onUnauthorized,
  });

  final AuthService service;
  final ProfileGateway? profile;

  /// STEP-3 chat service. Null keeps the STEP-1/2 local contract only.
  final ChatService? chat;
  final String host;
  final int port;

  /// Called after `POST /auth/login` succeeds, so the standalone entry can
  /// start its 30-second heartbeat for the newly established session.
  final void Function()? onSessionEstablished;

  /// Called when an authenticated local route receives a genuine 401
  /// (`unauthenticated`, never `invalid_credentials`), so the owner can clear
  /// both the in-memory session and the on-disk credential.
  final Future<void> Function()? onUnauthorized;

  /// Small JSON routes keep the STEP-1 bound.
  static const int maxRequestBytes = 16 * 1024;

  /// `update_avatar` carries a base64 image; the contract recommends 8 MiB.
  static const int maxAvatarRequestBytes = 8 * 1024 * 1024;

  /// Chat sends may carry a 32 MiB image as base64 (plus multipart-free JSON
  /// overhead), so this bound is intentionally larger than the avatar bound.
  static const int maxChatRequestBytes = 48 * 1024 * 1024;

  /// Field names the shared contract knows; an unknown extra key must not be
  /// echoed verbatim (it may contain a secret).
  static const Set<String> _knownFields = <String>{
    'username',
    'password',
    'account',
    'value',
    'path',
    'url',
    'base64',
    'signature',
    'nickname',
  };

  HttpServer? _httpServer;
  final CancelToken _cancel = CancelToken();

  /// Binds the listener and returns its `http://127.0.0.1:<port>` address.
  Future<Uri> start() async {
    assertLoopbackHost(host);
    if (_httpServer != null) {
      throw StateError('本地控制接口已经启动');
    }
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    _httpServer = server;
    server.listen(_handle, onError: (Object error, StackTrace stack) {});
    return Uri(scheme: 'http', host: loopbackHost, port: server.port);
  }

  Future<void> close() async {
    _cancel.cancel();
    final HttpServer? server = _httpServer;
    _httpServer = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    // The session can change while an upstream request is in flight (MCP login
    // of another account); a 401 then belongs to the old session only.
    final String? requestToken = service.session.tokenForRequest;
    try {
      final String path = request.uri.path;
      if (path.startsWith('/profile/')) {
        await _handleProfile(request, path);
        return;
      }
      if (path.startsWith('/chat/') ||
          path.startsWith('/downloads/') ||
          path.startsWith('/operations/') ||
          path.startsWith('/events/')) {
        await _handleChat(request, path);
        return;
      }
      if (path != '/auth/register' && path != '/auth/login') {
        await _writeEnvelope(request, 404, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'not_found',
            'message': '未知接口',
            'fields': <Object>[],
          },
        });
        return;
      }
      if (request.method != 'POST') {
        await _methodNotAllowed(request);
        return;
      }

      final Map<String, dynamic> body = await _readJsonObject(request);
      final bool registering = path == '/auth/register';
      _rejectUnknownFields(
        body,
        registering
            ? const <String>{'username', 'password'}
            : const <String>{'account', 'password'},
      );
      final String usernameOrAccount = _requireString(
        body,
        registering ? 'username' : 'account',
      );
      final String password = _requireString(body, 'password');

      if (path == '/auth/register') {
        final AuthUser user = await service.register(
          username: usernameOrAccount,
          password: password,
        );
        await _writeJson(request, 201, user.toJson());
      } else {
        final AuthUser user = await service.login(
          account: usernameOrAccount,
          password: password,
        );
        // Token is intentionally absent: it lives in the client session only.
        await _writeJson(request, 200, user.toJson());
        // MCP/local login is a real session establishment: start heartbeats.
        onSessionEstablished?.call();
      }
    } on AuthFailure catch (failure) {
      await _writeEnvelope(request, failure.status, failure.toEnvelope());
      if (failure.status == 401 &&
          failure.code == unauthenticated.code &&
          requestToken != null &&
          service.session.tokenForRequest == requestToken &&
          service.session.hasToken) {
        await _notifyUnauthorized();
      }
    } catch (_) {
      await _writeEnvelope(request, 500, <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'internal_error',
          'message': '客户端内部错误',
          'fields': <Object>[],
        },
      });
    }
  }

  Future<void> _handleProfile(HttpRequest request, String path) async {
    if (request.method != 'POST') {
      await _methodNotAllowed(request);
      return;
    }
    final ProfileGateway? gateway = profile;
    if (gateway == null) {
      await _writeEnvelope(request, 503, <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'storage_unavailable',
          'message': '资料功能不可用',
          'fields': <Object>[],
        },
      });
      return;
    }
    if (!service.session.hasToken || service.session.user == null) {
      throw unauthenticated;
    }
    final String selfAccount = service.session.user!.account;
    final bool avatarUpload = path == '/profile/update_avatar';
    final Map<String, dynamic> body = await _readJsonObject(
      request,
      maxBytes: avatarUpload ? maxAvatarRequestBytes : maxRequestBytes,
    );

    switch (path) {
      case '/profile/view_avatar':
        _rejectUnknownFields(body, const <String>{'account'});
        final String account =
            normalizeAccount(_optionalString(body, 'account')) ?? selfAccount;
        final AvatarImage image = await gateway.loadAvatar(account: account);
        await _writeJson(request, 200, <String, dynamic>{
          'account': image.account,
          'mime_type': image.mimeType,
          'data': base64Encode(image.bytes),
          'avatar_version': image.version,
        });
        return;
      case '/profile/update_avatar':
        _rejectUnknownFields(body, const <String>{'path', 'url', 'base64'});
        final ({String source, String value}) source = resolveAvatarSource(
          body,
        );
        final AvatarInfo info;
        switch (source.source) {
          case 'path':
            info = await gateway.updateAvatarFromPath(source.value);
          case 'url':
            info = await gateway.updateAvatarFromUrl(source.value);
          default:
            info = await gateway.updateAvatarFromBase64(source.value);
        }
        await _writeJson(request, 200, info.toJson());
        return;
      case '/profile/view_nickname':
        _rejectUnknownFields(body, const <String>{'account'});
        final String account =
            normalizeAccount(_optionalString(body, 'account')) ?? selfAccount;
        final String username = await gateway.viewNickname(account: account);
        await _writeJson(request, 200, <String, dynamic>{
          'account': account,
          'username': username,
        });
        return;
      case '/profile/update_nickname':
        _rejectUnknownFields(body, const <String>{'value'});
        final String value = _requireString(body, 'value');
        // Validate here so the local contract is enforced even if a gateway
        // implementation forgets; trim is idempotent.
        normalizeUsername(value);
        final String username = await gateway.updateNickname(value);
        await _writeJson(request, 200, <String, dynamic>{
          'account': selfAccount,
          'username': username,
        });
        return;
      case '/profile/view_signature':
        _rejectUnknownFields(body, const <String>{'account'});
        final String account =
            normalizeAccount(_optionalString(body, 'account')) ?? selfAccount;
        final String? signature = await gateway.viewSignature(account: account);
        await _writeJson(request, 200, <String, dynamic>{
          'account': account,
          'signature': signature,
        });
        return;
      case '/profile/update_signature':
        _rejectUnknownFields(body, const <String>{'value'});
        final Object? raw = body['value'];
        if (raw != null && raw is! String) {
          throw _fieldFailure('value', 'type', '字段类型错误');
        }
        final String? signature = normalizeSignature(raw as String?);
        final String? updated = await gateway.updateSignature(signature);
        await _writeJson(request, 200, <String, dynamic>{
          'account': selfAccount,
          'signature': updated,
        });
        return;
      default:
        await _writeEnvelope(request, 404, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'not_found',
            'message': '未知接口',
            'fields': <Object>[],
          },
        });
        return;
    }
  }

  /// STEP-3 local tool surface plus the R3 presentation/event additions.
  ///
  /// These are loopback-only client endpoints. They are deliberately not
  /// exported as model-callable MCP tools by the plugin.
  Future<void> _handleChat(HttpRequest request, String path) async {
    if (request.method != 'POST') {
      await _methodNotAllowed(request);
      return;
    }
    final ChatService? service = chat;
    if (service == null) {
      await _writeEnvelope(request, 503, <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'storage_unavailable',
          'message': '聊天功能不可用',
          'fields': <Object>[],
        },
      });
      return;
    }
    final Map<String, dynamic> body = await _readJsonObject(
      request,
      maxBytes: maxChatRequestBytes,
    );
    switch (path) {
      case '/chat/list_users':
        _rejectUnknownFields(body, const <String>{'after_account', 'limit'});
        final UserPage page = await service.listUsers(
          afterAccount: _optionalString(body, 'after_account') ?? '',
          limit: _optionalInt(body, 'limit') ?? 50,
        );
        await _writeJson(request, 200, page.toJson());
        return;
      case '/chat/send_message':
        _rejectUnknownFields(body, const <String>{
          'target_account',
          'operation_id',
          'content',
        });
        final String target = _requireString(body, 'target_account');
        final String operationId = _requireString(body, 'operation_id');
        final List<OutgoingPart> content = _parseOutgoingContent(
          body['content'],
        );
        final SendOutcome outcome = await service.sendBody(
          targetAccount: target,
          content: content,
          operationId: operationId,
        );
        await _writeJson(
          request,
          200,
          messageToJson(outcome.message ?? (throw upstreamMalformed)),
        );
        return;
      case '/chat/send_attachment':
        _rejectUnknownFields(body, const <String>{
          'target_account',
          'operation_id',
          'source',
          'cover',
        });
        final String target = _requireString(body, 'target_account');
        final String operationId = _requireString(body, 'operation_id');
        final Object? rawSource = body['source'];
        if (rawSource is! Map<String, dynamic>) {
          throw _fieldFailure('source', 'required', '此字段必填');
        }
        final Object? rawCover = body['cover'];
        final SendOutcome outcome = await service.sendAttachment(
          targetAccount: target,
          operationId: operationId,
          attachment: OutgoingAttachment(
            source: MediaSource.fromJson(rawSource),
            cover: rawCover == null ? null : MediaSource.fromJson(rawCover),
          ),
        );
        await _writeJson(
          request,
          200,
          messageToJson(outcome.message ?? (throw upstreamMalformed)),
        );
        return;
      case '/chat/read_messages':
        _rejectUnknownFields(body, const <String>{
          'account',
          'consumer_session',
          'after_position',
          'limit',
        });
        final VisibleMessagePage page = await service.readMessages(
          peerAccount: _requireString(body, 'account'),
          consumerSession: _requireString(body, 'consumer_session'),
          afterPosition: _optionalInt(body, 'after_position') ?? 0,
          limit: _optionalInt(body, 'limit') ?? 50,
        );
        await _writeJson(request, 200, page.toJson());
        return;
      case '/chat/wait_messages':
        _rejectUnknownFields(body, const <String>{
          'account',
          'consumer_session',
          'seen_position',
          'timeout',
        });
        final VisibleMessagePage page = await service.waitMessages(
          peerAccount: _requireString(body, 'account'),
          consumerSession: _requireString(body, 'consumer_session'),
          seenPosition: _requireInt(body, 'seen_position'),
          timeoutSeconds: _optionalInt(body, 'timeout') ?? 60,
          cancel: _cancel,
        );
        await _writeJson(request, 200, page.toJson());
        return;
      case '/chat/ack_messages':
        _rejectUnknownFields(body, const <String>{
          'account',
          'consumer_session',
          'through_position',
        });
        final int consumed = await service.ackMessages(
          peerAccount: _requireString(body, 'account'),
          consumerSession: _requireString(body, 'consumer_session'),
          throughPosition: _requireInt(body, 'through_position'),
        );
        await _writeJson(request, 200, <String, dynamic>{
          'consumed_through': consumed,
        });
        return;
      case '/downloads/start':
        _rejectUnknownFields(body, const <String>{
          'operation_id',
          'consumer_session',
          'media_id',
          'directory',
        });
        final DownloadTask task = await service.downloads.start(
          operationId: _requireString(body, 'operation_id'),
          consumerSession: _requireString(body, 'consumer_session'),
          mediaId: _requireString(body, 'media_id'),
          directory: _optionalString(body, 'directory'),
        );
        await _writeJson(request, 202, task.toWire());
        return;
      case '/downloads/get':
        _rejectUnknownFields(body, const <String>{
          'task_id',
          'consumer_session',
        });
        final DownloadTask? task = await service.downloads.get(
          taskId: _requireString(body, 'task_id'),
          consumerSession: _requireString(body, 'consumer_session'),
        );
        if (task == null) {
          await _writeEnvelope(request, 404, <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'not_found',
              'message': '下载任务不存在',
              'fields': <Object>[],
            },
          });
          return;
        }
        await _writeJson(request, 200, task.toWire());
        return;
      case '/operations/get':
        _rejectUnknownFields(body, const <String>{'operation_id'});
        final OperationResult? operation = await service.getOperation(
          _requireString(body, 'operation_id'),
        );
        if (operation == null) {
          await _writeEnvelope(request, 404, <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'not_found',
              'message': '操作不存在',
              'fields': <Object>[],
            },
          });
          return;
        }
        await _writeJson(request, 200, operation.toJson());
        return;
      case '/chat/confirm_presentation':
        _rejectUnknownFields(body, const <String>{
          'consumer_session',
          'attempt_id',
          'request_digest',
          'receipt_ids',
        });
        final List<String> confirmed = await service.confirmPresentation(
          consumerSession: _requireString(body, 'consumer_session'),
          attemptId: _requireString(body, 'attempt_id'),
          requestDigest: _requireString(body, 'request_digest'),
          receiptIds: _requireStringList(body, 'receipt_ids'),
        );
        await _writeJson(request, 200, <String, dynamic>{
          'confirmed_receipt_ids': confirmed,
        });
        return;
      case '/events/subscribe':
        _rejectUnknownFields(body, const <String>{
          'consumer_session',
          'peer_account',
        });
        final String consumer = _requireString(body, 'consumer_session');
        final String peer = _requireString(body, 'peer_account');
        await service.subscribeEvents(
          consumerSession: consumer,
          peerAccount: peer,
        );
        await _writeJson(request, 200, <String, dynamic>{
          'consumer_session': consumer,
          'peer_account': peer,
        });
        return;
      case '/events/read':
        _rejectUnknownFields(body, const <String>{
          'consumer_session',
          'after_cursor',
          'limit',
        });
        final LocalEventPage page = await service.readEvents(
          consumerSession: _requireString(body, 'consumer_session'),
          afterCursor: _requireInt(body, 'after_cursor'),
          limit: _optionalInt(body, 'limit') ?? 50,
        );
        await _writeJson(request, 200, page.toWire());
        return;
      case '/events/wait':
        _rejectUnknownFields(body, const <String>{
          'consumer_session',
          'after_cursor',
          'timeout',
        });
        final LocalEventPage page = await service.waitEvents(
          consumerSession: _requireString(body, 'consumer_session'),
          afterCursor: _requireInt(body, 'after_cursor'),
          timeoutSeconds: _optionalInt(body, 'timeout') ?? 60,
        );
        await _writeJson(request, 200, page.toWire());
        return;
      default:
        await _writeEnvelope(request, 404, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'not_found',
            'message': '未知接口',
            'fields': <Object>[],
          },
        });
        return;
    }
  }

  List<OutgoingPart> _parseOutgoingContent(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      throw _fieldFailure('content', 'required', '正文不能为空');
    }
    final List<OutgoingPart> parts = <OutgoingPart>[];
    for (final Object? entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw _fieldFailure('content', 'type', '内容片段必须是对象');
      }
      final Object? type = entry['type'];
      if (type == 'text') {
        final Object? text = entry['text'];
        if (text is! String || text.isEmpty) {
          throw _fieldFailure('content', 'type', '文字片段不能为空');
        }
        parts.add(OutgoingText(text));
      } else if (type == 'image') {
        final Object? source = entry['source'];
        if (source is! Map<String, dynamic>) {
          throw _fieldFailure('content', 'type', '图片片段缺少 source');
        }
        parts.add(OutgoingImage(MediaSource.fromJson(source)));
      } else {
        throw _fieldFailure('content', 'type', '不支持的内容片段');
      }
    }
    return parts;
  }

  int _requireInt(Map<String, dynamic> body, String field) {
    if (!body.containsKey(field)) {
      throw _fieldFailure(field, 'required', '此字段必填');
    }
    final Object? value = body[field];
    if (value is! int) {
      throw _fieldFailure(field, 'type', '字段类型错误');
    }
    return value;
  }

  int? _optionalInt(Map<String, dynamic> body, String field) {
    if (!body.containsKey(field) || body[field] == null) {
      return null;
    }
    final Object? value = body[field];
    if (value is! int) {
      throw _fieldFailure(field, 'type', '字段类型错误');
    }
    return value;
  }

  List<String> _requireStringList(Map<String, dynamic> body, String field) {
    if (!body.containsKey(field)) {
      throw _fieldFailure(field, 'required', '此字段必填');
    }
    final Object? value = body[field];
    if (value is! List) {
      throw _fieldFailure(field, 'type', '字段类型错误');
    }
    final List<String> result = <String>[];
    for (final Object? entry in value) {
      if (entry is! String || entry.isEmpty) {
        throw _fieldFailure(field, 'type', '列表元素必须是非空字符串');
      }
      result.add(entry);
    }
    return result;
  }

  Future<void> _notifyUnauthorized() async {
    final Future<void> Function()? callback = onUnauthorized;
    if (callback == null) {
      return;
    }
    try {
      await callback();
    } catch (_) {
      // The owner reports its own storage faults; never leak them as response.
    }
  }

  Future<void> _methodNotAllowed(HttpRequest request) {
    return _writeEnvelope(request, 405, <String, dynamic>{
      'error': <String, dynamic>{
        'code': 'method_not_allowed',
        'message': '只支持 POST',
        'fields': <Object>[],
      },
    });
  }

  Future<Map<String, dynamic>> _readJsonObject(
    HttpRequest request, {
    int maxBytes = maxRequestBytes,
  }) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw AuthFailure(
          status: 413,
          code: 'validation_error',
          message: '请求体过大',
          fields: <AuthFieldError>[
            AuthFieldError(
              field: 'body',
              code: 'too_large',
              message: '请求体超过 ${maxBytes ~/ 1024}KB',
            ),
          ],
        );
      }
    }
    final String raw = utf8.decode(builder.takeBytes(), allowMalformed: true);
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException {
      // Fall through to the typed validation failure.
    }
    throw const AuthFailure(
      status: 422,
      code: 'validation_error',
      message: '输入有误',
      fields: <AuthFieldError>[
        AuthFieldError(field: 'body', code: 'type', message: '请求必须为有效 JSON 对象'),
      ],
    );
  }

  /// Mirrors the server contract: unknown keys are rejected, never echoed.
  void _rejectUnknownFields(Map<String, dynamic> body, Set<String> allowed) {
    final String unknown = body.keys.firstWhere(
      (String key) => !allowed.contains(key),
      orElse: () => '',
    );
    if (unknown.isEmpty) {
      return;
    }
    throw AuthFailure(
      status: 422,
      code: 'validation_error',
      message: '输入有误',
      fields: <AuthFieldError>[
        AuthFieldError(
          field: _knownFields.contains(unknown) ? unknown : 'body',
          code: 'extra',
          message: '不允许的字段',
        ),
      ],
    );
  }

  String? _optionalString(Map<String, dynamic> body, String field) {
    if (!body.containsKey(field)) {
      return null;
    }
    final Object? value = body[field];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw _fieldFailure(field, 'type', '字段类型错误');
    }
    return value;
  }

  String _requireString(Map<String, dynamic> body, String field) {
    if (!body.containsKey(field)) {
      throw _fieldFailure(field, 'required', '此字段必填');
    }
    final Object? value = body[field];
    // Explicit null is a type error, not "missing": the shared PATCH contract
    // distinguishes omission (preserve) from null.
    if (value is! String) {
      throw _fieldFailure(field, 'type', '字段类型错误');
    }
    return value;
  }

  AuthFailure _fieldFailure(String field, String code, String message) {
    return AuthFailure(
      status: 422,
      code: 'validation_error',
      message: '输入有误',
      fields: <AuthFieldError>[
        AuthFieldError(field: field, code: code, message: message),
      ],
    );
  }

  Future<void> _writeJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) {
    return _writeEnvelope(request, status, body);
  }

  Future<void> _writeEnvelope(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    final HttpResponse response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    response.write(jsonEncode(body));
    await response.close();
  }
}
