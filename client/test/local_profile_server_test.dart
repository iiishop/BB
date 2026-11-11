import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late AuthSession session;
  late AuthService auth;
  late ProfileService profile;
  late LocalAuthServer server;
  late Uri address;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-local-profile-');
    session = AuthSession();
    auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
      store: SessionStore.atPath('${directory.path}/session.json'),
    );
    await auth.login(
      account: backend.validAccount,
      password: backend.validPassword,
    );
    profile = ProfileService(
      api: ProfileApiClient(baseUri: backend.baseUri),
      auth: auth,
      cache: AvatarCache(),
    );
    server = LocalAuthServer(service: auth, profile: profile, port: 0);
    address = await server.start();
  });

  tearDown(() async {
    await server.close();
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<_Response> post(String path, Map<String, dynamic> payload) =>
      _post(address.resolve(path), payload);

  group('view tools', () {
    test('view_nickname defaults to self', () async {
      final _Response response = await post(
        '/profile/view_nickname',
        <String, dynamic>{},
      );
      expect(response.status, 200);
      expect(response.body, <String, dynamic>{
        'account': backend.validAccount,
        'username': 'muse.tester',
      });
      expect(response.raw.contains(backend.issuedToken), isFalse);
    });

    test('view_nickname reads another known account', () async {
      backend.knownAccounts.add('87654321');
      final _Response response = await post(
        '/profile/view_nickname',
        <String, dynamic>{'account': '87654321'},
      );
      expect(response.status, 200);
      expect(response.body['account'], '87654321');
    });

    test('view_avatar returns base64 PNG and current version', () async {
      final _Response response = await post(
        '/profile/view_avatar',
        <String, dynamic>{},
      );
      expect(response.status, 200);
      expect(response.body['mime_type'], 'image/png');
      expect(
        base64Decode(response.body['data']! as String),
        backend.avatarBytes,
      );
      expect(response.body['avatar_version'], backend.avatarVersion);
    });

    test('view_avatar revalidates instead of serving a stale copy', () async {
      final _Response first = await post(
        '/profile/view_avatar',
        <String, dynamic>{},
      );
      backend.replaceAvatar(Uint8List.fromList(<int>[..._png, 1]));
      final _Response second = await post(
        '/profile/view_avatar',
        <String, dynamic>{},
      );
      expect(
        second.body['avatar_version'],
        isNot(first.body['avatar_version']),
      );
      expect(
        backend.avatarIfNoneMatch.last,
        '"${first.body['avatar_version']}"',
      );
    });

    test(
      'bad account and extra keys are rejected before any upstream call',
      () async {
        final int before = backend.requests.length;
        final _Response badAccount = await post(
          '/profile/view_nickname',
          <String, dynamic>{'account': '１２３４５６７８'},
        );
        expect(badAccount.status, 422);
        expect(_fieldCode(badAccount), 'format');

        final _Response extra = await post(
          '/profile/view_signature',
          <String, dynamic>{'account': null, 'username': 'x'},
        );
        expect(extra.status, 422);
        expect(_fieldCode(extra), 'extra');
        expect(backend.requests.length, before);
      },
    );
  });

  group('update_nickname', () {
    test('trims and returns the new username', () async {
      final _Response response = await post(
        '/profile/update_nickname',
        <String, dynamic>{'value': '  Alice  '},
      );
      expect(response.status, 200);
      expect(response.body, <String, dynamic>{
        'account': backend.validAccount,
        'username': 'Alice',
      });
      expect(backend.username, 'Alice');
      expect(session.user?.username, 'Alice');
    });

    test(
      'rejects an account argument, null, missing and long values',
      () async {
        expect(
          _fieldCode(
            await post('/profile/update_nickname', <String, dynamic>{
              'value': 'valid',
              'account': '12345678',
            }),
          ),
          'extra',
        );
        expect(
          _fieldCode(
            await post('/profile/update_nickname', <String, dynamic>{
              'value': null,
            }),
          ),
          'type',
        );
        expect(
          _fieldCode(
            await post('/profile/update_nickname', <String, dynamic>{}),
          ),
          'required',
        );
        expect(
          _fieldCode(
            await post('/profile/update_nickname', <String, dynamic>{
              'value': 'x' * 25,
            }),
          ),
          'length',
        );
      },
    );
  });

  group('update_signature', () {
    test('sets, reads and clears', () async {
      final _Response set = await post(
        '/profile/update_signature',
        <String, dynamic>{'value': '  hello  '},
      );
      expect(set.body['signature'], 'hello');

      final _Response read = await post(
        '/profile/view_signature',
        <String, dynamic>{},
      );
      expect(read.body['signature'], 'hello');

      final _Response clear = await post(
        '/profile/update_signature',
        <String, dynamic>{},
      );
      expect(clear.body['signature'], isNull);
    });

    test('rejects 50 code points and account arguments', () async {
      expect(
        _fieldCode(
          await post('/profile/update_signature', <String, dynamic>{
            'value': '🌏' * 50,
          }),
        ),
        'length',
      );
      expect(
        _fieldCode(
          await post('/profile/update_signature', <String, dynamic>{
            'value': 'ok',
            'account': '12345678',
          }),
        ),
        'extra',
      );
    });
  });

  group('update_avatar', () {
    test('accepts raw base64 and returns a new version', () async {
      final _Response response = await post(
        '/profile/update_avatar',
        <String, dynamic>{'base64': base64Encode(_png)},
      );
      expect(response.status, 200);
      expect(
        response.body['avatar_url'],
        '/avatars/${backend.validAccount}.png',
      );
      expect(response.body['avatar_version'], isNotEmpty);
      expect(backend.avatarUploaded, isTrue);
    });

    test('accepts a data URI and a local absolute path', () async {
      expect(
        (await post('/profile/update_avatar', <String, dynamic>{
          'base64': 'data:image/png;base64,${base64Encode(_png)}',
        })).status,
        200,
      );
      final File file = File('${directory.path}/avatar.png');
      await file.writeAsBytes(_png);
      expect(
        (await post('/profile/update_avatar', <String, dynamic>{
          'path': file.path,
        })).status,
        200,
      );
    });

    test('downloads a url source itself', () async {
      final HttpServer imageServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      imageServer.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_png);
        await request.response.close();
      });
      addTearDown(() => imageServer.close(force: true));
      final _Response response = await post(
        '/profile/update_avatar',
        <String, dynamic>{'url': 'http://127.0.0.1:${imageServer.port}/a.png'},
      );
      expect(response.status, 200);
    });

    test('enforces exactly one non-empty source', () async {
      expect(
        _fieldCode(await post('/profile/update_avatar', <String, dynamic>{})),
        'one_source',
      );
      expect(
        _fieldCode(
          await post('/profile/update_avatar', <String, dynamic>{
            'path': '/x',
            'url': 'https://example.invalid/x',
          }),
        ),
        'one_source',
      );
      expect(
        _fieldCode(
          await post('/profile/update_avatar', <String, dynamic>{
            'base64': 'a',
            'path': null,
          }),
        ),
        'one_source',
      );
      expect(
        _fieldCode(
          await post('/profile/update_avatar', <String, dynamic>{
            'path': 'relative.png',
          }),
        ),
        'format',
      );
      expect(
        _fieldCode(
          await post('/profile/update_avatar', <String, dynamic>{
            'url': 'file:///tmp/x',
          }),
        ),
        'format',
      );
      expect(
        _fieldCode(
          await post('/profile/update_avatar', <String, dynamic>{'base64': ''}),
        ),
        'required',
      );
      expect(
        _fieldCode(
          await post('/profile/update_avatar', <String, dynamic>{
            'base64': null,
          }),
        ),
        'required',
      );
    });

    test('accepts a body larger than 16 KiB (8 MiB route)', () async {
      final Uint8List big = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        ...List<int>.filled(200 * 1024, 0),
      ]);
      final _Response response = await post(
        '/profile/update_avatar',
        <String, dynamic>{'base64': base64Encode(big)},
      );
      expect(response.status, 200);
    });
  });

  group('bounds and errors', () {
    test('small routes keep the 16 KiB request bound', () async {
      final _Response response = await post(
        '/profile/view_nickname',
        <String, dynamic>{'account': null, 'padding': 'x' * 20000},
      );
      expect(response.status, 413);
      expect(_fieldCode(response), 'too_large');
    });

    test('profile routes require a signed-in client session', () async {
      final AuthService anonymous = AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: AuthSession(),
        store: SessionStore.atPath('${directory.path}/anonymous.json'),
      );
      final LocalAuthServer anonymousServer = LocalAuthServer(
        service: anonymous,
        profile: ProfileService(
          api: ProfileApiClient(baseUri: backend.baseUri),
          auth: anonymous,
        ),
        port: 0,
      );
      final Uri anonymousAddress = await anonymousServer.start();
      addTearDown(anonymousServer.close);

      final _Response response = await _post(
        anonymousAddress.resolve('/profile/view_nickname'),
        <String, dynamic>{},
      );
      expect(response.status, 401);
      expect(response.body['error'], containsPair('code', 'unauthenticated'));
    });

    test('non-POST profile calls return 405', () async {
      final HttpClient client = HttpClient();
      addTearDown(() => client.close(force: true));
      final HttpClientRequest request = await client.getUrl(
        address.resolve('/profile/view_nickname'),
      );
      final HttpClientResponse response = await request.close();
      final String raw = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 405);
      expect(raw, contains('method_not_allowed'));
    });
  });
}

String? _fieldCode(_Response response) {
  final Object? error = response.body['error'];
  if (error is! Map<String, dynamic>) {
    return null;
  }
  final Object? fields = error['fields'];
  if (fields is! List || fields.isEmpty) {
    return null;
  }
  return (fields.first as Map<String, dynamic>)['code'] as String?;
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
