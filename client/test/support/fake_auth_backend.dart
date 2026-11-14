import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal in-process FastAPI stand-in implementing the shared STEP-1/STEP-2
/// contract.
///
/// Tests use real HTTP over loopback so the client transport, status codes,
/// auth headers, ETag revalidation and envelope parsing are exercised for real
/// (no mock of the network layer).
class FakeAuthBackend {
  FakeAuthBackend._(this._server);

  final HttpServer _server;

  /// Account and password that log in successfully.
  String validAccount = '40218765';
  String validPassword = 'Secret42';

  /// Accounts whose profile/avatar routes resolve; others return 404.
  late final Set<String> knownAccounts = <String>{validAccount};

  /// Username attached to the session/profile responses.
  String username = 'muse.tester';

  /// Signature attached to profile responses.
  String? signature;

  /// Token the fake login returns; it is also what protected routes accept.
  String issuedToken = 'fake-token-0123456789abcdef0123456789abcdef';
  bool tokenValid = true;

  /// Avatar state. Bytes are a real (tiny) PNG so `Image.memory` can decode.
  String avatarVersion = 'identicon-v1-fake';
  Uint8List avatarBytes = _onePixelPng;
  bool avatarUploaded = false;

  /// Optional per-account avatar state. Accounts absent here use the
  /// single-account fields above, keeping existing tests unchanged.
  final Map<String, Uint8List> avatarBytesByAccount = <String, Uint8List>{};
  final Map<String, String> avatarVersionsByAccount = <String, String>{};
  int _avatarRevision = 0;

  /// Every request body received, in order (multipart as `{file: length}`).
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  /// Every request method/path/authorization header, in order.
  final List<({String method, String path, String? authorization})> log =
      <({String method, String path, String? authorization})>[];

  /// Every `If-None-Match` value seen on an avatar request.
  final List<String?> avatarIfNoneMatch = <String?>[];

  /// `If-None-Match` values per avatar account, in request order.
  final Map<String, List<String?>> avatarIfNoneMatchByAccount =
      <String, List<String?>>{};

  /// Response code for heartbeat calls; set to 401/500 to script failures.
  int heartbeatStatus = 200;
  int heartbeatCalls = 0;

  /// Artificial upstream latency, used for timeout coverage.
  Duration delay = Duration.zero;

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

  /// Simulates a new uploaded avatar and returns its version.
  String replaceAvatar(Uint8List bytes) {
    avatarBytes = bytes;
    avatarUploaded = true;
    avatarVersion = 'sha256-fake-${DateTime.now().microsecondsSinceEpoch}';
    return avatarVersion;
  }

  /// Sets one account's avatar bytes and returns its new version.
  String setAvatar(String account, Uint8List bytes) {
    avatarBytesByAccount[account] = bytes;
    avatarVersionsByAccount[account] =
        'sha256-test-${++_avatarRevision}-${DateTime.now().microsecondsSinceEpoch}';
    return avatarVersionsByAccount[account]!;
  }

  Future<void> _handle(HttpRequest request) async {
    log.add((
      method: request.method,
      path: request.uri.path,
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
    ));
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in request) {
      builder.add(chunk);
    }
    final Uint8List raw = builder.takeBytes();
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    final String path = request.uri.path;
    final bool multipart =
        request.headers.contentType?.mimeType == 'multipart/form-data';

    if (request.method == 'GET') {
      if (path == '/auth/session') {
        await _handleSession(request);
        return;
      }
      final RegExpMatch? profileMatch = RegExp(r'^/users/([0-9]{8})/profile$')
          .firstMatch(path);
      if (profileMatch != null) {
        await _handleProfileGet(request, profileMatch.group(1)!);
        return;
      }
      final RegExpMatch? avatarMatch = RegExp(r'^/avatars/([0-9]{8})\.png$')
          .firstMatch(path);
      if (avatarMatch != null) {
        await _handleAvatar(request, avatarMatch.group(1)!);
        return;
      }
      await _write(request, 404, _error('not_found', '未知接口'));
      return;
    }

    if (multipart) {
      if (request.method == 'POST' && path == '/me/avatar') {
        requests.add(<String, dynamic>{'file': raw.length});
        await _handleAvatarUpload(request, raw);
        return;
      }
      await _write(request, 404, _error('not_found', '未知接口'));
      return;
    }

    final String body = utf8.decode(raw, allowMalformed: true);
    final Map<String, dynamic> json = body.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(body) as Map<String, dynamic>? ?? <String, dynamic>{});
    requests.add(json);

    if (request.method == 'PATCH' && path == '/me/profile') {
      await _handleProfilePatch(request, json);
      return;
    }
    if (request.method == 'DELETE' && path == '/me/avatar') {
      await _handleAvatarDelete(request);
      return;
    }
    if (request.method != 'POST') {
      await _write(request, 405, _error('method_not_allowed', '只支持 POST'));
      return;
    }

    switch (path) {
      case '/auth/register':
        await _handleRegister(request, json);
        return;
      case '/auth/login':
        await _handleLogin(request, json);
        return;
      case '/auth/logout':
        await _handleLogout(request);
        return;
      case '/auth/heartbeat':
        await _handleHeartbeat(request);
        return;
      case '/me/avatar':
        await _handleAvatarUpload(request, raw);
        return;
      default:
        await _write(request, 404, _error('not_found', '未知接口'));
        return;
    }
  }

  Future<void> _handleSession(HttpRequest request) async {
    if (_authorized(request)) {
      await _write(request, 200, <String, dynamic>{
        'account': validAccount,
        'username': username,
      });
      return;
    }
    await _write(request, 401, _error('unauthenticated', '请重新登录'));
  }

  Future<void> _handleProfileGet(HttpRequest request, String account) async {
    if (!_authorized(request)) {
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    if (!knownAccounts.contains(account)) {
      await _write(request, 404, _error('not_found', '用户不存在'));
      return;
    }
    await _write(request, 200, _profileJson(account));
  }

  Future<void> _handleProfilePatch(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    if (!_authorized(request)) {
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    if (json.containsKey('username')) {
      username = (json['username']! as String).trim();
    }
    if (json.containsKey('signature')) {
      final Object? value = json['signature'];
      signature = (value as String?)?.trim();
      if (signature != null && signature!.isEmpty) {
        signature = null;
      }
    }
    await _write(request, 200, _profileJson(validAccount));
  }

  Future<void> _handleAvatarUpload(HttpRequest request, Uint8List raw) async {
    if (!_authorized(request)) {
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    // Extract the single file part; validates the multipart shape the client
    // actually sent instead of trusting a length.
    final String contentType = request.headers.value(
      HttpHeaders.contentTypeHeader,
    )!;
    final RegExpMatch? boundaryMatch = RegExp(r'boundary=(.+)$')
        .firstMatch(contentType);
    if (boundaryMatch == null) {
      await _write(
        request,
        422,
        _error('validation_error', 'multipart 缺少 boundary'),
      );
      return;
    }
    final String boundary = boundaryMatch.group(1)!;
    final String latin = latin1.decode(raw, allowInvalid: true);
    if (!latin.contains('name="file"') || !latin.contains('--$boundary--')) {
      await _write(request, 422, _error('validation_error', '只允许一个 file 字段'));
      return;
    }
    final int headerEnd = latin.indexOf('\r\n\r\n');
    final int tailStart = latin.lastIndexOf('\r\n--$boundary--');
    if (headerEnd < 0 || tailStart <= headerEnd) {
      await _write(request, 422, _error('validation_error', 'multipart 形状错误'));
      return;
    }
    final Uint8List bytes = raw.sublist(headerEnd + 4, tailStart);
    if (bytes.isEmpty) {
      await _write(request, 422, _error('validation_error', '空文件'));
      return;
    }
    final String version = replaceAvatar(bytes);
    await _write(request, 200, <String, dynamic>{
      'avatar_url': '/avatars/$validAccount.png',
      'avatar_version': version,
    });
  }

  Future<void> _handleAvatarDelete(HttpRequest request) async {
    if (!_authorized(request)) {
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    avatarUploaded = false;
    avatarBytes = _onePixelPng;
    avatarVersion =
        'identicon-v1-fake-${DateTime.now().microsecondsSinceEpoch}';
    await _write(request, 200, <String, dynamic>{
      'avatar_url': '/avatars/$validAccount.png',
      'avatar_version': avatarVersion,
    });
  }

  Future<void> _handleAvatar(HttpRequest request, String account) async {
    if (!_authorized(request)) {
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    if (!knownAccounts.contains(account)) {
      await _write(request, 404, _error('not_found', '用户不存在'));
      return;
    }
    final String? ifNoneMatch = request.headers.value(
      HttpHeaders.ifNoneMatchHeader,
    );
    avatarIfNoneMatch.add(ifNoneMatch);
    avatarIfNoneMatchByAccount
        .putIfAbsent(account, () => <String?>[])
        .add(ifNoneMatch);
    final String version = avatarVersionsByAccount[account] ?? avatarVersion;
    final Uint8List bytes = avatarBytesByAccount[account] ?? avatarBytes;
    final String etag = '"$version"';
    if (ifNoneMatch == etag) {
      request.response.statusCode = 304;
      request.response.headers.set(HttpHeaders.etagHeader, etag);
      await request.response.close();
      return;
    }
    final HttpResponse response = request.response;
    response.statusCode = 200;
    response.headers.set(HttpHeaders.etagHeader, etag);
    response.headers.contentType = ContentType('image', 'png');
    response.add(bytes);
    await response.close();
  }

  Future<void> _handleLogout(HttpRequest request) async {
    if (!_authorized(request)) {
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    tokenValid = false;
    request.response.statusCode = 204;
    await request.response.close();
  }

  Future<void> _handleHeartbeat(HttpRequest request) async {
    heartbeatCalls += 1;
    if (!_authorized(request) || heartbeatStatus == 401) {
      tokenValid = false;
      await _write(request, 401, _error('unauthenticated', '请重新登录'));
      return;
    }
    if (heartbeatStatus != 200) {
      await _write(
        request,
        heartbeatStatus,
        _error('storage_unavailable', '存储暂不可用'),
      );
      return;
    }
    await _write(request, 200, <String, dynamic>{
      'status': 'online',
      'last_seen_at': '2026-11-11T20:00:00.000Z',
    });
  }

  Future<void> _handleRegister(
    HttpRequest request,
    Map<String, dynamic> json,
  ) async {
    final List<Map<String, String>> fields = <Map<String, String>>[];
    final Object? usernameValue = json['username'];
    final String trimmed = usernameValue is String ? usernameValue.trim() : '';
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
      tokenValid = true;
      await _write(request, 200, <String, dynamic>{
        'account': validAccount,
        'username': username,
        'token': issuedToken,
      });
      return;
    }
    await _write(request, 401, _error('invalid_credentials', '账号或密码错误'));
  }

  Map<String, dynamic> _profileJson(String account) => <String, dynamic>{
    'account': account,
    'username': username,
    'signature': signature,
    'avatar_url': '/avatars/$account.png',
    'avatar_version': avatarVersionsByAccount[account] ?? avatarVersion,
  };

  bool _authorized(HttpRequest request) {
    final String? header = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    return tokenValid && header == 'Bearer $issuedToken';
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

/// 1×1 transparent PNG, valid for `Image.memory` in widget tests.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
