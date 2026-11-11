import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

void main() {
  late FakeAuthBackend backend;
  late AuthSession session;
  late AuthService service;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    session = AuthSession();
    service = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
    );
  });

  tearDown(() => backend.close());

  test('register returns the server-assigned account', () async {
    final AuthUser user = await service.register(
      username: '  muse  ',
      password: 'Secret42',
    );

    expect(user.account, '87654321');
    expect(user.username, 'muse');
    expect(backend.requests.single['username'], 'muse');
    expect(backend.requests.single['password'], 'Secret42');
    expect(session.hasToken, isFalse, reason: 'register must not sign in');
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
    'login keeps the token in the session and returns identity only',
    () async {
      final AuthUser user = await service.login(
        account: ' 40218765 ',
        password: 'Secret42',
      );

      expect(user.account, '40218765');
      expect(user.username, 'muse.tester');
      expect(session.hasToken, isTrue);
      expect(session.tokenForRequest, backend.issuedToken);
      expect(session.user?.account, '40218765');
    },
  );

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
  });

  test('slow upstream maps to 504 upstream_timeout', () async {
    backend.delay = const Duration(milliseconds: 500);
    final AuthService slow = AuthService(
      api: AuthApiClient(
        baseUri: backend.baseUri,
        timeout: const Duration(milliseconds: 60),
      ),
      session: AuthSession(),
    );

    final AuthFailure failure = await _captureFailure(
      () => slow.login(account: '40218765', password: 'Secret42'),
    );

    expect(failure.status, 504);
    expect(failure.code, 'upstream_timeout');
    expect(failure.message, '请求超时，请稍后重试');
  });

  test('signOut clears the in-memory session', () async {
    await service.login(account: '40218765', password: 'Secret42');
    service.signOut();

    expect(session.hasToken, isFalse);
    expect(session.user, isNull);
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
