import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late SessionStore store;
  late AuthSession session;
  late AuthService service;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-auth-service-');
    store = SessionStore.atPath('${directory.path}/session.json');
    session = AuthSession();
    service = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
      store: store,
    );
  });

  tearDown(() async {
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  AuthService serviceWithNewSession() {
    return AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: AuthSession(),
      store: SessionStore.atPath(store.file.path),
    );
  }

  test('register returns the server-assigned account', () async {
    final AuthUser user = await service.register(
      username: '  muse  ',
      password: 'Secret42',
    );

    expect(user.account, '87654321');
    expect(user.username, 'muse');
    expect(backend.requests.first['username'], 'muse');
    expect(backend.requests.first['password'], 'Secret42');
    expect(session.hasToken, isFalse, reason: 'register must not sign in');
    expect(await store.read(), isNull, reason: 'register must not persist');
  });

  test('register surfaces every 422 field reason', () async {
    final AuthFailure failure = await _captureFailure(
      () => service.register(username: 'ab', password: 'abc'),
    );

    expect(failure.status, 422);
    expect(failure.code, 'validation_error');
    expect(
      failure.fields.map((AuthFieldError field) => field.code),
      containsAll(<String>[
        'length',
        'min_length',
        'missing_uppercase',
        'missing_digit',
      ]),
    );
    expect(
      failure.fields
          .firstWhere((AuthFieldError field) => field.field == 'password')
          .message,
      '密码至少 6 位',
    );
  });

  test(
    'login keeps the token in the session and persists no password',
    () async {
      final AuthUser user = await service.login(
        account: ' 40218765 ',
        password: 'Secret42',
      );

      expect(user.account, '40218765');
      expect(user.username, 'muse.tester');
      expect(session.hasToken, isTrue);
      expect(session.tokenForRequest, backend.issuedToken);

      final PersistedSession? stored = await store.read();
      expect(stored?.account, '40218765');
      expect(stored?.username, 'muse.tester');
      expect(stored?.token, backend.issuedToken);
      final String raw = await store.file.readAsString();
      expect(raw.contains('password'), isFalse);
      expect(raw.contains('Secret42'), isFalse);
    },
  );

  test(
    'restoreSession verifies the stored token with GET /auth/session',
    () async {
      await service.login(account: '40218765', password: 'Secret42');

      final AuthService restarted = serviceWithNewSession();
      final AuthUser? user = await restarted.restoreSession();

      expect(user?.account, '40218765');
      expect(user?.username, 'muse.tester');
      expect(restarted.session.hasToken, isTrue);
      expect(backend.log.last.method, 'GET');
      expect(backend.log.last.path, '/auth/session');
      expect(backend.log.last.authorization, 'Bearer ${backend.issuedToken}');
    },
  );

  test('restoreSession returns null when nothing is stored', () async {
    expect(await service.restoreSession(), isNull);
    expect(session.hasToken, isFalse);
  });

  test('restoreSession clears the credential on 401', () async {
    await store.write(
      const PersistedSession(
        account: '40218765',
        username: 'muse.tester',
        token: 'expired-token',
      ),
    );

    final AuthFailure failure = await _captureFailure(
      () => service.restoreSession(),
    );

    expect(failure.status, 401);
    expect(failure.code, 'unauthenticated');
    expect(await store.read(), isNull, reason: 'invalid credential removed');
    expect(session.hasToken, isFalse);
  });

  test('restoreSession keeps the credential on a network failure', () async {
    await store.write(
      PersistedSession(
        account: '40218765',
        username: 'muse.tester',
        token: backend.issuedToken,
      ),
    );
    await backend.close();

    final AuthFailure failure = await _captureFailure(
      () => service.restoreSession(),
    );

    expect(failure.status, 502);
    expect(failure.code, 'upstream_unavailable');
    final PersistedSession? kept = await store.read();
    expect(kept?.token, backend.issuedToken, reason: 'credential kept');
    expect(session.hasToken, isFalse, reason: 'not verified, not signed in');
  });

  test('a corrupt stored credential is treated as no session', () async {
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('{"account": "40218765"}');

    expect(await service.restoreSession(), isNull);
    expect(session.hasToken, isFalse);
  });

  test(
    'wrong password and unknown account share the same 401 failure',
    () async {
      final AuthFailure wrongPassword = await _captureFailure(
        () => service.login(account: '40218765', password: 'Wrong42'),
      );
      final AuthFailure unknownAccount = await _captureFailure(
        () => service.login(account: '00000000', password: 'Secret42'),
      );

      expect(wrongPassword.status, 401);
      expect(wrongPassword.code, 'invalid_credentials');
      expect(unknownAccount.status, 401);
      expect(
        unknownAccount.toEnvelope(),
        equals(wrongPassword.toEnvelope()),
        reason: 'no account enumeration',
      );
      expect(session.hasToken, isFalse);
      expect(await store.read(), isNull);
    },
  );

  test('unreachable upstream maps to 502 upstream_unavailable', () async {
    await backend.close();

    final AuthFailure failure = await _captureFailure(
      () => service.login(account: '40218765', password: 'Secret42'),
    );

    expect(failure.status, 502);
    expect(failure.code, 'upstream_unavailable');
    expect(failure.message, '无法连接服务器，请检查服务地址或网络后重试');
    expect(failure.fields, isEmpty);
    expect(await store.read(), isNull);
  });

  test('slow upstream maps to 504 upstream_timeout', () async {
    backend.delay = const Duration(milliseconds: 500);
    final AuthService slow = AuthService(
      api: AuthApiClient(
        baseUri: backend.baseUri,
        timeout: const Duration(milliseconds: 60),
      ),
      session: AuthSession(),
      store: store,
    );

    final AuthFailure failure = await _captureFailure(
      () => slow.login(account: '40218765', password: 'Secret42'),
    );

    expect(failure.status, 504);
    expect(failure.code, 'upstream_timeout');
    expect(failure.message, '请求超时，请稍后重试');
  });

  test(
    'login reports session_storage_unavailable when the write fails',
    () async {
      final AuthService failing = AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: session,
        store: SessionStore.atPath(
          store.file.path,
          replace: (File temporary, File target) async {
            throw FileSystemException(
              'injected replace failure',
              temporary.path,
            );
          },
        ),
      );

      final AuthFailure failure = await _captureFailure(
        () => failing.login(account: '40218765', password: 'Secret42'),
      );

      expect(failure.status, 500);
      expect(failure.code, 'session_storage_unavailable');
      expect(failure.message, '会话存储不可用');
      expect(
        session.hasToken,
        isFalse,
        reason: 'no durable session means no reported success',
      );
      expect(await store.read(), isNull);
    },
  );

  test('restoreSession reports session_storage_unavailable on an unreadable '
      'credential', () async {
    await service.login(account: '40218765', password: 'Secret42');
    if (Platform.isWindows) {
      return;
    }
    await Process.run('chmod', <String>['000', store.file.path]);
    addTearDown(() => Process.run('chmod', <String>['600', store.file.path]));

    final AuthFailure failure = await _captureFailure(service.restoreSession);

    expect(failure.status, 500);
    expect(failure.code, 'session_storage_unavailable');
    expect(session.hasToken, isFalse);
  });

  test('signOut keeps the session and reports when deletion fails', () async {
    await service.login(account: '40218765', password: 'Secret42');
    if (Platform.isWindows) {
      return;
    }
    final String parent = store.file.parent.path;
    await Process.run('chmod', <String>['500', parent]);
    addTearDown(() => Process.run('chmod', <String>['700', parent]));

    final AuthFailure failure = await _captureFailure(service.signOut);

    expect(failure.status, 500);
    expect(failure.code, 'session_storage_unavailable');
    expect(
      session.hasToken,
      isTrue,
      reason: 'the credential is still on disk, so the UI must stay signed in',
    );
    expect(await store.read(), isNotNull);
  });

  test('signOut clears the session and the stored credential', () async {
    await service.login(account: '40218765', password: 'Secret42');
    expect(await store.read(), isNotNull);

    await service.signOut();

    expect(session.hasToken, isFalse);
    expect(session.user, isNull);
    expect(await store.read(), isNull);
  });
}

Future<AuthFailure> _captureFailure(Future<Object?> Function() action) async {
  try {
    await action();
  } on AuthFailure catch (failure) {
    return failure;
  }
  fail('expected an AuthFailure');
}
