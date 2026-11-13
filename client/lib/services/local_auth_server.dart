import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'dart:io';

import '../config/client_config.dart';
import '../models/auth_models.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/chat_v2.dart';
import '../services/client_identity.dart';
import '../services/profile_service.dart';

/// Loopback-only local control API used by the DSH MCP plugin.
///
/// It reuses [AuthService] and [ProfileGateway], so the UI, the standalone Dart
/// entry and the plugin share one implementation:
///
/// * `POST /auth/register` -> 201 `{account, username}`
/// * `POST /auth/login`    -> 200 `{account, username}` (token never leaves the
///   client process)
/// * protected `/v2/profile/*` routes are implemented by [ChatV2Router];
///   the old unguarded `/profile/*` routes are gone and answer 404.
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
  final Future<void> Function(String token)? onUnauthorized;

  /// Small JSON routes keep the STEP-1 bound.
  static const int maxRequestBytes = 16 * 1024;

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
  late final ChatV2Router _v2 = ChatV2Router(
    session: service.session,
    chat: chat,
    profile: profile,
  );

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
      if (path.startsWith('/v2/')) {
        await _handleV2(request, path, requestToken);
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
        await _notifyUnauthorized(requestToken);
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

  /// Strict v2 local protocol; errors keep the v2 `{error:{code,message,fields}}`
  /// envelope with field-name strings only.
  Future<void> _handleV2(
    HttpRequest request,
    String path,
    String? requestToken,
  ) async {
    if (request.method != 'POST') {
      await _writeEnvelope(request, 405, <String, dynamic>{
        'error': <String, dynamic>{
          'code': 'validation_error',
          'message': '只支持 POST',
          'fields': <Object>[],
        },
      });
      return;
    }
    Map<String, dynamic> body;
    try {
      body = await _readJsonObject(request, maxBytes: maxChatRequestBytes);
    } on AuthFailure catch (failure) {
      final bool tooLarge = failure.status == 413;
      await _writeEnvelope(request, tooLarge ? 413 : 422, <String, dynamic>{
        'error': <String, dynamic>{
          'code': tooLarge ? 'payload_too_large' : 'validation_error',
          'message': tooLarge ? '请求体过大' : '输入有误',
          'fields': <String>['body'],
        },
      });
      return;
    }
    final ({int status, Map<String, dynamic> body}) result = await _v2.handle(
      path: path,
      ownerKey: request.headers.value(v2OwnerHeader),
      body: body,
    );
    // The v2 router converts AuthFailure into a DTO, so the outer handler's
    // invalidation branch is otherwise unreachable. Only a genuine 401 for the
    // credential captured at request start may clear the session; a request
    // from an older login must never revoke a concurrent new login. Clear
    // before responding so callers never observe an authenticated status after
    // the invalidating 401.
    final Object? error = result.body['error'];
    if (result.status == 401 &&
        error is Map<String, dynamic> &&
        error['code'] == unauthenticated.code &&
        requestToken != null &&
        service.session.tokenForRequest == requestToken &&
        service.session.hasToken) {
      await _notifyUnauthorized(requestToken);
    }
    await _writeEnvelope(request, result.status, result.body);
  }

  /// STEP-3 local tool surface plus the R3 presentation/event additions.
  ///
  /// These are loopback-only client endpoints. They are deliberately not
  /// exported as model-callable MCP tools by the plugin.
  Future<void> _notifyUnauthorized(String token) async {
    final Future<void> Function(String token)? callback = onUnauthorized;
    if (callback == null) {
      return;
    }
    try {
      await callback(token);
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
