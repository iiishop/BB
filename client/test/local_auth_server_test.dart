import 'dart:convert';
import 'dart:io';

import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late SessionStore store;
  late AuthSession session;
  late AuthService service;
  late LocalAuthServer server;
  late Uri address;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-local-api-');
    store = SessionStore.atPath('${directory.path}/session.json');
    session = AuthSession();
    service = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
      store: store,
    );
    server = LocalAuthServer(service: service, port: 0);
    address = await server.start();
  });

  tearDown(() async {
    await server.close();
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('register returns 201 with account and username only', () async {
    final _Response response = await _post(
      address.resolve('/auth/register'),
      <String, dynamic>{'username': '  muse  ', 'password': 'Secret42'},
    );

    expect(response.status, 201);
    expect(response.body, <String, dynamic>{
      'account': '87654321',
      'username': 'muse',
    });
    expect(response.raw.contains('token'), isFalse);
    expect(backend.requests.single['username'], 'muse');
  });

  test(
    'login returns identity only while the session keeps the token',
    () async {
      final _Response response = await _post(
        address.resolve('/auth/login'),
        <String, dynamic>{'account': '40218765', 'password': 'Secret42'},
      );

      expect(response.status, 200);
      expect(response.body, <String, dynamic>{
        'account': '40218765',
        'username': 'muse.tester',
      });
      expect(response.raw.contains('token'), isFalse);
      expect(response.raw.contains(backend.issuedToken), isFalse);
      expect(session.hasToken, isTrue);
      expect(session.tokenForRequest, backend.issuedToken);
    },
  );

  test('login through the local API writes the shared session store', () async {
    await _post(address.resolve('/auth/login'), <String, dynamic>{
      'account': '40218765',
      'password': 'Secret42',
    });

    final PersistedSession? stored = await store.read();
    expect(stored?.account, '40218765');
    expect(stored?.token, backend.issuedToken);
    expect(
      (await store.file.readAsString()).contains('Secret42'),
      isFalse,
      reason: 'never persist a password',
    );
    expect(session.hasToken, isTrue);
  });

  test('login cannot succeed when the credential cannot be stored', () async {
    final AuthService failing = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: AuthSession(),
      store: SessionStore.atPath(
        '${directory.path}/failing.json',
        replace: (File temporary, File target) async {
          throw FileSystemException('injected replace failure', temporary.path);
        },
      ),
    );
    final LocalAuthServer failingServer = LocalAuthServer(
      service: failing,
      port: 0,
    );
    final Uri failingAddress = await failingServer.start();
    addTearDown(failingServer.close);

    final _Response response = await _post(
      failingAddress.resolve('/auth/login'),
      <String, dynamic>{'account': '40218765', 'password': 'Secret42'},
    );

    expect(response.status, 500);
    expect(response.body, <String, dynamic>{
      'error': <String, dynamic>{
        'code': 'session_storage_unavailable',
        'message': '会话存储不可用',
        'fields': <Object>[],
      },
    });
    expect(response.raw.contains(backend.issuedToken), isFalse);
    expect(failing.session.hasToken, isFalse);
  });

  test('wrong password returns the shared 401 envelope', () async {
    final _Response response = await _post(
      address.resolve('/auth/login'),
      <String, dynamic>{'account': '40218765', 'password': 'Wrong42'},
    );

    expect(response.status, 401);
    expect(response.body, <String, dynamic>{
      'error': <String, dynamic>{
        'code': 'invalid_credentials',
        'message': '账号或密码错误',
        'fields': <Object>[],
      },
    });
    expect(session.hasToken, isFalse);
  });

  test('upstream 422 field reasons pass through unchanged', () async {
    final _Response response = await _post(
      address.resolve('/auth/register'),
      <String, dynamic>{'username': 'ab', 'password': 'abc'},
    );

    expect(response.status, 422);
    final Map<String, dynamic> error =
        response.body['error'] as Map<String, dynamic>;
    expect(error['code'], 'validation_error');
    expect(error['message'], '输入有误');
    final List<dynamic> fields = error['fields'] as List<dynamic>;
    expect(
      fields.map((dynamic field) => (field as Map<String, dynamic>)['field']),
      everyElement(anyOf('username', 'password')),
    );
    expect(
      fields.map((dynamic field) => (field as Map<String, dynamic>)['message']),
      contains('密码至少 6 位'),
    );
  });

  test('unknown fields are rejected with code=extra', () async {
    final _Response response = await _post(
      address.resolve('/auth/register'),
      <String, dynamic>{
        'username': 'muse',
        'password': 'Secret42',
        'account': '12345678',
      },
    );

    expect(response.status, 422);
    final Map<String, dynamic> error =
        response.body['error'] as Map<String, dynamic>;
    final List<dynamic> fields = error['fields'] as List<dynamic>;
    final Map<String, dynamic> field = fields.single as Map<String, dynamic>;
    expect(field['field'], 'account');
    expect(field['code'], 'extra');
    expect(field['message'], '不允许的字段');
  });

  test('missing password is rejected locally with code=required', () async {
    final int callsBefore = backend.requests.length;
    final _Response response = await _post(
      address.resolve('/auth/register'),
      <String, dynamic>{'username': 'muse'},
    );

    expect(response.status, 422);
    final Map<String, dynamic> error =
        response.body['error'] as Map<String, dynamic>;
    final List<dynamic> fields = error['fields'] as List<dynamic>;
    expect((fields.single as Map<String, dynamic>)['field'], 'password');
    expect((fields.single as Map<String, dynamic>)['code'], 'required');
    expect(backend.requests.length, callsBefore, reason: 'no upstream call');
  });

  test('unreachable upstream returns 502 upstream_unavailable', () async {
    await backend.close();

    final _Response response = await _post(
      address.resolve('/auth/login'),
      <String, dynamic>{'account': '40218765', 'password': 'Secret42'},
    );

    expect(response.status, 502);
    expect(response.body, <String, dynamic>{
      'error': <String, dynamic>{
        'code': 'upstream_unavailable',
        'message': '无法连接服务器，请检查服务地址或网络后重试',
        'fields': <Object>[],
      },
    });
  });

  test('unknown path returns 404 and a non-POST method returns 405', () async {
    final _Response missing = await _post(
      address.resolve('/nope'),
      <String, dynamic>{},
    );
    expect(missing.status, 404);

    final HttpClient client = HttpClient();
    final HttpClientRequest request = await client.getUrl(
      address.resolve('/auth/login'),
    );
    final HttpClientResponse raw = await request.close();
    await raw.drain<void>();
    client.close(force: true);
    expect(raw.statusCode, 405);
  });

  test('refuses to bind any host other than 127.0.0.1', () async {
    final LocalAuthServer wildcard = LocalAuthServer(
      service: service,
      host: '0.0.0.0',
      port: 0,
    );

    await expectLater(wildcard.start(), throwsA(isA<ArgumentError>()));
  });

  test('close() releases the loopback port', () async {
    final int boundPort = address.port;
    await server.close();

    final HttpServer rebound = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      boundPort,
    );
    await rebound.close(force: true);
  });
}

class _Response {
  const _Response(this.status, this.body, this.raw);

  final int status;
  final Map<String, dynamic> body;
  final String raw;
}

Future<_Response> _post(Uri uri, Map<String, dynamic> payload) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    final List<int> bytes = utf8.encode(jsonEncode(payload));
    request.contentLength = bytes.length;
    request.add(bytes);
    final HttpClientResponse response = await request.close();
    final String raw = await utf8.decoder.bind(response).join();
    return _Response(
      response.statusCode,
      jsonDecode(raw) as Map<String, dynamic>,
      raw,
    );
  } finally {
    client.close(force: true);
  }
}
