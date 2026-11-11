import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Optional live check against a running FastAPI server.
///
/// Default `flutter test` runs this file with a SKIP because no server is
/// assumed. To execute the real link (no stub), start the service and run:
///
///   BB_LIVE_SERVER_URL=http://127.0.0.1:8171 flutter test test/live_auth_test.dart
void main() {
  final String? configured = Platform.environment['BB_LIVE_SERVER_URL'];
  final String? baseUrl = (configured != null && configured.trim().isNotEmpty)
      ? configured.trim()
      : null;
  final Object? skipReason = baseUrl == null
      ? 'BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 链路（SKIP，不算 PASS）'
      : null;

  group('live FastAPI auth', () {
    late Directory directory;
    late SessionStore store;
    late AuthApiClient api;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('bb-live-');
      store = SessionStore.atPath('${directory.path}/session.json');
      api = AuthApiClient(baseUri: Uri.parse(baseUrl!));
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('register → login → persist → restore → expired credential', () async {
      final String username =
          'live_${DateTime.now().microsecondsSinceEpoch % 100000000}';
      final AuthService service = AuthService(
        api: api,
        session: AuthSession(),
        store: store,
      );

      final AuthUser first = await service.register(
        username: username,
        password: 'Secret42',
      );
      expect(first.account, matches(RegExp(r'^[1-9][0-9]{7}$')));
      expect(first.username, username);

      final AuthUser second = await service.register(
        username: username,
        password: 'Secret42',
      );
      expect(
        second.account,
        isNot(first.account),
        reason: 'duplicate username still gets a new unique account',
      );

      final AuthFailure wrongPassword = await _captureFailure(
        () => service.login(account: first.account, password: 'Wrong42'),
      );
      final AuthFailure unknownAccount = await _captureFailure(
        () => service.login(account: '00000000', password: 'Secret42'),
      );
      expect(wrongPassword.status, 401);
      expect(wrongPassword.code, 'invalid_credentials');
      expect(unknownAccount.toEnvelope(), wrongPassword.toEnvelope());

      final AuthUser user = await service.login(
        account: first.account,
        password: 'Secret42',
      );
      expect(user.account, first.account);
      expect(service.session.hasToken, isTrue);
      final String token = service.session.tokenForRequest!;
      expect(token.length, greaterThanOrEqualTo(32));

      final PersistedSession? stored = await store.read();
      expect(stored?.account, first.account);
      expect(stored?.token, token);
      expect(
        (await store.file.readAsString()).contains('Secret42'),
        isFalse,
        reason: 'never persist the password',
      );

      final AuthService restarted = AuthService(
        api: api,
        session: AuthSession(),
        store: SessionStore.atPath(store.file.path),
      );
      final AuthUser? restored = await restarted.restoreSession();
      expect(restored?.account, first.account);
      expect(restored?.username, username);
      expect(restarted.session.hasToken, isTrue);

      await store.write(
        PersistedSession(
          account: first.account,
          username: username,
          token: 'not-a-valid-token',
        ),
      );
      final AuthService expired = AuthService(
        api: api,
        session: AuthSession(),
        store: SessionStore.atPath(store.file.path),
      );
      final AuthFailure failure = await _captureFailure(expired.restoreSession);
      expect(failure.status, 401);
      expect(failure.code, 'unauthenticated');
      expect(await store.read(), isNull);
      expect(expired.session.hasToken, isFalse);
    }, skip: skipReason);
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
