import 'dart:convert';
import 'dart:io';

import 'package:bb_client/foreground_recovery.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/http_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sends the same platform message a real foreground resume produces, so the
/// observer path (not a hand-called method) is what the test exercises.
Future<void> _lifecycle(AppLifecycleState state) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemChannels.lifecycle.name,
        SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
        (ByteData? _) {},
      );
}

Future<void> _pausedThenResumed() async {
  await _lifecycle(AppLifecycleState.paused);
  await _lifecycle(AppLifecycleState.resumed);
}

void main() {
  // Created before the test binding installs its blocking HttpOverrides; the
  // integration case needs one real loopback connection.
  final HttpClient realClient = HttpClient();
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a real foreground resume runs the catch-up once and detach stops it',
    () async {
      int calls = 0;
      final ForegroundRecovery recovery = ForegroundRecovery(
        onResumed: () async {
          calls += 1;
        },
      )..attach();
      addTearDown(recovery.detach);
      await _pausedThenResumed();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'resume must trigger exactly one catch-up');

      await _lifecycle(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'pausing is not a resume');

      recovery.detach();
      await _pausedThenResumed();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'a detached host must stop observing');
    },
  );

  test(
    'a failing catch-up is contained and never escapes the observer',
    () async {
      final ForegroundRecovery recovery = ForegroundRecovery(
        onResumed: () async => throw StateError('synthetic resume failure'),
      )..attach();
      addTearDown(recovery.detach);
      await _pausedThenResumed();
      await Future<void>.delayed(Duration.zero);
      // Reaching here without an unhandled error is the assertion.
    },
  );

  test('resume replays durable events through the real chat service', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    int eventRequests = 0;
    server.listen((HttpRequest request) async {
      if (request.uri.path != '/events') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      eventRequests += 1;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object>{
          'items': <Object>[],
          'next_event_id': 0,
          'has_more': false,
        }),
      );
      await request.response.close();
    });
    final Directory root = await Directory.systemTemp.createTemp(
      'bb-foreground-',
    );
    final AuthSession session = AuthSession()
      ..establish(
        token: 'synthetic',
        user: const AuthUser(account: '10000001', username: 'alice'),
      );
    final HttpTransport transport = HttpTransport(factory: () => realClient);
    addTearDown(() => transport.client.close(force: true));
    final ChatService chat = ChatService(
      api: ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        transport: transport,
      ),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
      cacheRoot: root,
      eventPollInterval: const Duration(minutes: 5),
      webSocketHints: false,
    );
    addTearDown(() async {
      await chat.dispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    await chat.subscribeEvents(
      consumerSession: 'consumer',
      peerAccount: '10000002',
    );
    final int before = eventRequests;
    final ForegroundRecovery recovery = ForegroundRecovery(
      onResumed: chat.resumeForCurrentSession,
    )..attach();
    addTearDown(recovery.detach);

    await _pausedThenResumed();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 2));
    while (eventRequests == before && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      eventRequests,
      before + 1,
      reason: 'resume must replay the durable event feed immediately',
    );
  });
}
