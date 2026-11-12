import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedApi extends AuthApiClient {
  DelayedApi() : super(baseUri: Uri.parse('http://127.0.0.1:1'));
  final reply = Completer<void>();
  @override
  Future<void> heartbeat(String token) => reply.future;
  @override
  Future<LoginResult> login({
    required String account,
    required String password,
  }) async => LoginResult(
    user: AuthUser(account: account, username: 'new-user'),
    token: 'new-token',
  );
}

void main() {
  test(
    'late old-session 401 must preserve newly logged-in memory and disk',
    () async {
      final dir = await Directory.systemTemp.createTemp('qa-race-');
      final store = SessionStore.atPath('${dir.path}/session.json');
      final api = DelayedApi();
      final session = AuthSession()
        ..establish(
          token: 'old-token',
          user: const AuthUser(account: '12345678', username: 'old-user'),
        );
      final auth = AuthService(api: api, session: session, store: store);
      final heartbeat = HeartbeatController(auth: auth);
      Future<void>? cleanup;
      // Same unauthorized listener behavior as bb_client_api.dart.
      heartbeat.addListener(() {
        if (heartbeat.phase == HeartbeatPhase.unauthorized) {
          heartbeat.stop();
          cleanup = auth.signOut();
        }
      });
      try {
        heartbeat.start();
        final oldBeat = heartbeat.beatNow();
        heartbeat.stop();
        await auth.login(account: '87654321', password: 'Secret42');
        heartbeat.start();
        expect(session.tokenForRequest, 'new-token');
        expect(await store.read(), isNotNull);
        api.reply.completeError(unauthenticated);
        await oldBeat;
        await cleanup;
        expect(
          [session.tokenForRequest, (await store.read())?.token],
          ['new-token', 'new-token'],
          reason: 'old request cannot revoke the new memory or disk session',
        );
      } finally {
        heartbeat.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
