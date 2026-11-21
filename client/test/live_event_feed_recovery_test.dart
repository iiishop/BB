import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/event_feed.dart';
import 'package:flutter_test/flutter_test.dart';

const _stepTimeout = Duration(seconds: 10);

class _ObservedApi extends ChatApiClient {
  _ObservedApi({required super.baseUri, required this.record});

  final void Function(String, String) record;
  final first = Completer<WebSocket>();
  final reconnectStarted = Completer<void>();
  final resumeReconnect = Completer<void>();
  final second = Completer<WebSocket>();
  int attempts = 0;

  void releaseReconnect() {
    if (!resumeReconnect.isCompleted) resumeReconnect.complete();
  }

  @override
  Future<WebSocket> connectEvents(String token) async {
    final attempt = ++attempts;
    if (attempt == 2) {
      reconnectStarted.complete();
      await resumeReconnect.future;
    }
    final milestone = switch (attempt) {
      1 => first,
      2 => second,
      _ => null,
    };
    try {
      final socket = await super.connectEvents(token);
      milestone?.complete(socket);
      return socket;
    } catch (error) {
      final stage = attempt == 1 ? 'first_handshake' : 'reconnect';
      final kind = error.runtimeType.toString();
      record(stage, kind);
      // Complete the milestone with a safe summary. EventFeed handles the
      // original error and retries according to its normal policy.
      milestone?.completeError(StateError('$stage failed ($kind)'));
      rethrow;
    }
  }
}

Future<void> _until(Future<bool> Function() ready) async {
  final timer = Stopwatch()..start();
  do {
    if (await ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  } while (timer.elapsed < _stepTimeout);
  fail('the live recovery milestone did not complete');
}

void main() {
  final configured = Platform.environment['BB_LIVE_WSS_URL'];
  final seeds = (Platform.environment['BB_LIVE_WSS_SEEDS'] ?? '41,101,2026')
      .split(',')
      .map(int.parse);
  final baseUri = Uri.parse(configured ?? 'https://invalid.example');
  final secure = Random.secure();
  String nonce() => List.generate(
    6,
    (_) => secure.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  for (final seed in seeds) {
    test(
      'live WSS reconnect, replay and dispose seed=$seed',
      () async {
        void record(String stage, String result) {
          Zone.current.print(
            jsonEncode({'seed': seed, 'stage': stage, 'result': result}),
          );
        }

        final auth = AuthApiClient(baseUri: baseUri);
        Future<LoginResult> login() async {
          final password = 'Secure-${nonce()}-${nonce()}';
          final user = await auth.register(
            username: 'qa487_${nonce()}',
            password: password,
          );
          final login = await auth.login(
            account: user.account,
            password: password,
          );
          addTearDown(() => auth.logout(login.token));
          return login;
        }

        final receiver = await login();
        final root = await Directory.systemTemp.createTemp('bb-live-wss-');
        addTearDown(() => root.delete(recursive: true));
        final path = '${root.path}/ledger.json';
        final api = _ObservedApi(baseUri: baseUri, record: record);
        // Observe errors immediately even when a failed stage precedes the
        // second attempt and its future is never awaited by the test.
        unawaited(api.second.future.then<void>((_) {}, onError: (Object _) {}));
        final feed = EventFeed(
          api: api,
          session: AuthSession()
            ..establish(token: receiver.token, user: receiver.user),
          ledger: ChatLedger.atPath(path),
          pollInterval: const Duration(minutes: 2),
        );
        addTearDown(() async {
          await feed.dispose();
          api.releaseReconnect();
        });
        final random = Random(seed);
        const consumer = 'live-wss';
        record('first_handshake', 'started');
        feed.start();
        final first = await api.first.future.timeout(_stepTimeout);
        record('first_handshake', 'passed');

        final sender = await login();
        await feed.subscribe(
          consumerSession: consumer,
          peerAccount: sender.user.account,
        );
        await first.close().timeout(_stepTimeout);
        await api.reconnectStarted.future.timeout(_stepTimeout);
        final texts = <String>[];
        for (
          var remaining = 1 + random.nextInt(3);
          remaining > 0;
          remaining--
        ) {
          await Future<void>.delayed(
            Duration(milliseconds: 20 + random.nextInt(80)),
          );
          final text = 'synthetic-$seed-$remaining';
          await api.sendMessage(
            token: sender.token,
            targetAccount: receiver.user.account,
            clientNonce: nonce(),
            content: [TextPart(text)],
          );
          texts.add(text);
        }
        expect(feed.revision, 0);
        api.releaseReconnect();

        final second = await api.second.future.timeout(_stepTimeout);
        record('reconnect', 'passed');
        await _until(() async => feed.revision >= texts.length);
        final page = await feed.read(consumerSession: consumer, afterCursor: 0);
        final positions = List.generate(texts.length, (index) => index + 1);
        expect(page.items.map((entry) => entry.cursor), positions);
        expect(page.items.map((entry) => entry.event.position), positions);
        expect(page.items.map((entry) => entry.event.account).toSet(), {
          receiver.user.account,
        });
        expect(page.items.map((entry) => entry.event.consumerSession).toSet(), {
          consumer,
        });
        expect(page.items.map((entry) => entry.event.peerAccount).toSet(), {
          sender.user.account,
        });
        expect(
          page.items.map((entry) => entry.event.eventId).toSet(),
          hasLength(texts.length),
        );
        expect(page.hasMore, isFalse);
        final history = await api.conversation(
          token: receiver.token,
          account: sender.user.account,
          limit: 20,
        );
        expect(history.items.map((message) => message.position), positions);
        expect(
          history.items.map(
            (message) => (message.parts.single as TextPart).text,
          ),
          texts,
        );
        record('replay', 'passed');

        await feed.dispose();
        await _until(() async => second.readyState == WebSocket.closed);
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(api.attempts, 2);
        final cold = await ChatLedger.atPath(path).readLocalEvents(
          account: receiver.user.account,
          consumerSession: consumer,
          afterCursor: 0,
        );
        expect(cold.items.map((entry) => entry.cursor), positions);
        expect(
          cold.items.map((entry) => entry.event.eventId),
          page.items.map((entry) => entry.event.eventId),
        );
        record('dispose', 'passed');
      },
      skip: configured == null
          ? 'Set BB_LIVE_WSS_URL to run the live probe'
          : false,
    );
  }
}
