import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal in-process FastAPI stand-in implementing the shared STEP-1 contract.
///
/// Tests use real HTTP over loopback so the client transport, status codes and
/// envelope parsing are exercised for real (no mock of the network layer).
class FakeAuthBackend {
  FakeAuthBackend._(this._server);

  final HttpServer _server;

  /// Account and password that log in successfully.
  String validAccount = '40218765';
  String validPassword = 'Secret42';

  /// Username attached to both responses.
  String username = 'muse.tester';

  /// Token the fake login returns; it is also what `GET /auth/session` accepts.
  String issuedToken = 'fake-token-0123456789abcdef0123456789abcdef';

  /// Artificial upstream latency, used for timeout coverage.
  Duration delay = Duration.zero;

  /// Every request body received, in order.
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  /// Every request method/path/authorization header, in order.
  final List<({String method, String path, String? authorization})> log =
      <({String method, String path, String? authorization})>[];

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<FakeAuthBackend> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final FakeAuthBackend backend = FakeAuthBackend._(server);
    server.listen(backend._handle);
    return backend;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    log.add((
      method: request.method,
      path: request.uri.path,
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
    ));
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> json = body.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(body) as Map<String, dynamic>? ?? <String, dynamic>{});
    requests.add(json);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    if (request.method == 'GET' && request.uri.path == '/auth/session') {
      await _handleSession(request);
      return;
    }
    if (request.method != 'POST') {
      await _write(request, 405, _error('method_not_allowed', '只支持 POST'));
      return;
    }
    switch (request.uri.path) {
      case '/auth/register':
        await _handleRegister(request, json);
      case '/auth/login':
        await _handleLogin(request, json);
      default:
        await _write(request, 404, _error('not_found', '未知接口'));
    }
  }

  Future<void> _handleSession(HttpRequest request) async {
    final String? header = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    if (header == 'Bearer $issuedToken') {
      await _write(request, 200, <String, dynamic>{
        'account': validAccount,
        'username': username,
      });
      return;
    }
    await _write(request, 401, _error('unauthenticated', '请重新登录'));
  }

  Future<void> _handleRegister(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    final List<Map<String, String>> fields = <Map<String, String>>[];
    final Object? username = json['username'];
    final String trimmed = username is String ? username.trim() : '';
    if (trimmed.length < 3 || trimmed.length > 24) {
      fields.add(<String, String>{
        'field': 'username',
        'code': 'length',
        'message': '用户名去除首尾空白后须为 3–24 字符',
      });
    }
    final Object? password = json['password'];
    if (password is! String) {
      fields.add(<String, String>{
        'field': 'password',
        'code': 'required',
        'message': '密码不能为空',
      });
    } else {
      fields.addAll(_passwordFieldErrors(password));
    }
    if (fields.isNotEmpty) {
      await _write(
        request,
        422,
        _error('validation_error', '输入有误', fields: fields),
      );
      return;
    }
    await _write(request, 201, <String, dynamic>{
      'account': '87654321',
      'username': trimmed,
    });
  }

  Future<void> _handleLogin(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    final Object? account = json['account'];
    final Object? password = json['password'];
    if (account == validAccount && password == validPassword) {
      await _write(request, 200, <String, dynamic>{
        'account': validAccount,
        'username': username,
        'token': issuedToken,
      });
      return;
    }
    await _write(request, 401, _error('invalid_credentials', '账号或密码错误'));
  }

  List<Map<String, String>> _passwordFieldErrors(String password) {
    final List<Map<String, String>> fields = <Map<String, String>>[];
    if (password.length < 6) {
      fields.add(<String, String>{
        'field': 'password',
        'code': 'min_length',
        'message': '密码至少 6 位',
      });
    }
    if (!RegExp('[A-Z]').hasMatch(password)) {
      fields.add(<String, String>{
        'field': 'password',
        'code': 'missing_uppercase',
        'message': '密码必须包含大写字母',
      });
    }
    if (!RegExp('[a-z]').hasMatch(password)) {
      fields.add(<String, String>{
        'field': 'password',
        'code': 'missing_lowercase',
        'message': '密码必须包含小写字母',
      });
    }
    if (!RegExp('[0-9]').hasMatch(password)) {
      fields.add(<String, String>{
        'field': 'password',
        'code': 'missing_digit',
        'message': '密码必须包含数字',
      });
    }
    return fields;
  }

  Map<String, dynamic> _error(
    String code,
    String message, {
    List<Map<String, String>> fields = const <Map<String, String>>[],
  }) {
    return <String, dynamic>{
      'error': <String, dynamic>{
        'code': code,
        'message': message,
        'fields': fields,
      },
    };
  }

  Future<void> _write(
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
