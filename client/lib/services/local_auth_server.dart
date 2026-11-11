import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;
import 'dart:io';

import '../config/client_config.dart';
import '../models/auth_models.dart';
import 'auth_service.dart';

/// Loopback-only local control API used by the DSH MCP plugin.
///
/// It reuses [AuthService], so the UI and the plugin share one auth
/// implementation:
///
/// * `POST /auth/register` -> 201 `{account, username}`
/// * `POST /auth/login`    -> 200 `{account, username}` (token never leaves the
///   client process; it is kept in [AuthSession])
///
/// Errors keep the server contract: 422 `validation_error` with `fields`,
/// 401 `invalid_credentials`, and 502/504 `upstream_unavailable` /
/// `upstream_timeout` when the server cannot be reached.
class LocalAuthServer {
  LocalAuthServer({
    required this.service,
    this.host = loopbackHost,
    this.port = defaultLocalPort,
  });

  final AuthService service;
  final String host;
  final int port;

  static const int maxRequestBytes = 16 * 1024;

  /// Field names the shared contract knows; an unknown extra key must not be
  /// echoed verbatim (it may contain a secret).
  static const Set<String> _knownFields = <String>{
    'username',
    'password',
    'account',
  };

  HttpServer? _httpServer;

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
    final HttpServer? server = _httpServer;
    _httpServer = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final String path = request.uri.path;
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
        await _writeEnvelope(request, 405, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'method_not_allowed',
            'message': '只支持 POST',
            'fields': <Object>[],
          },
        });
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
      }
    } on AuthFailure catch (failure) {
      await _writeEnvelope(request, failure.status, failure.toEnvelope());
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

  Future<Map<String, dynamic>> _readJsonObject(HttpRequest request) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in request) {
      builder.add(chunk);
      if (builder.length > maxRequestBytes) {
        throw const AuthFailure(
          status: 413,
          code: 'validation_error',
          message: '请求体过大',
          fields: <AuthFieldError>[
            AuthFieldError(
              field: 'body',
              code: 'too_large',
              message: '请求体超过 16KB',
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
    final Object? value = body[field];
    if (value == null) {
      throw AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '输入有误',
        fields: <AuthFieldError>[
          AuthFieldError(field: field, code: 'required', message: '此字段必填'),
        ],
      );
    }
    if (value is! String) {
      throw AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '输入有误',
        fields: <AuthFieldError>[
          AuthFieldError(field: field, code: 'type', message: '字段类型错误'),
        ],
      );
    }
    return value;
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
