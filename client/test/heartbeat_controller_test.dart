import 'dart:io';

import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late AuthSession session;
  late AuthService auth;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-heartbeat-');
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
  });

  tearDown(() async {
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('one beat reports online', () async {
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    await heartbeat.beatNow();
    expect(heartbeat.phase, HeartbeatPhase.online);
    expect(heartbeat.missedBeats, 0);
  });

  test('three failures keep credentials and show reconnecting', () async {
    backend.heartbeatStatus = 500;
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    for (int i = 0; i < 3; i++) {
      await heartbeat.beatNow();
    }
    expect(heartbeat.phase, HeartbeatPhase.reconnecting);
    expect(heartbeat.missedBeats, 3);
    expect(session.hasToken, isTrue, reason: 'network failure is not logout');
    expect(
      await SessionStore.atPath('${directory.path}/session.json').read(),
      isNotNull,
    );
  });

  test('a successful beat clears the banner state', () async {
    backend.heartbeatStatus = 500;
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    for (int i = 0; i < 3; i++) {
      await heartbeat.beatNow();
    }
    expect(heartbeat.phase, HeartbeatPhase.reconnecting);

    backend.heartbeatStatus = 200;
    await heartbeat.beatNow();
    expect(heartbeat.phase, HeartbeatPhase.online);
    expect(heartbeat.missedBeats, 0);
  });

  test('401 is unauthorized, not a missed beat', () async {
    backend.heartbeatStatus = 401;
    final HeartbeatController heartbeat = HeartbeatController(auth: auth);
    addTearDown(heartbeat.dispose);
    await heartbeat.beatNow();
    expect(heartbeat.phase, HeartbeatPhase.unauthorized);
    expect(heartbeat.missedBeats, 0);
  });

  test('periodic timer sends beats while signed in', () async {
    final HeartbeatController heartbeat = HeartbeatController(
      auth: auth,
      interval: const Duration(milliseconds: 20),
    );
    addTearDown(heartbeat.dispose);
    heartbeat.start();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    heartbeat.stop();
    expect(backend.heartbeatCalls, greaterThanOrEqualTo(2));
  });

  test('stop returns to idle and cancels the timer', () async {
    final HeartbeatController heartbeat = HeartbeatController(
      auth: auth,
      interval: const Duration(milliseconds: 20),
    );
    addTearDown(heartbeat.dispose);
    heartbeat.start();
    heartbeat.stop();
    final int calls = backend.heartbeatCalls;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(backend.heartbeatCalls, calls);
    expect(heartbeat.phase, HeartbeatPhase.idle);
  });
}
