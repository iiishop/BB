import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/event_feed.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  for (final holdSnapshot in [false, true]) {
    test(
      holdSnapshot
          ? 'reconnect replays after an active old snapshot completes'
          : 'reconnect immediately replays missed events with the durable cursor',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final cursors = <int>[];
        bool available = false;
        bool holdNextSnapshot = false;
        final snapshotHeld = Completer<void>();
        final releaseSnapshot = Completer<void>();
        addTearDown(() async {
          for (final socket in sockets) {
            await socket.close();
          }
          await server.close(force: true);
        });
        server.listen((request) async {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            final socket = await WebSocketTransformer.upgrade(request);
            socket.listen((_) {});
            sockets.add(socket);
            return;
          }
          final after = int.parse(
            request.uri.queryParameters['after_event_id'] ?? '0',
          );
          final isEvents = request.uri.path == '/events';
          if (isEvents) cursors.add(after);
          final value = isEvents
              ? {
                  'items': [
                    if (available && after == 0)
                      {
                        'event_id': 1,
                        'type': 'message_available',
                        'occurred_at': '2026-11-21T00:00:00Z',
                        'message_id': 'm',
                        'peer_account': 'b',
                        'position': 1,
                      },
                  ],
                  'next_event_id': available ? 1 : 0,
                  'has_more': false,
                }
              : {
                  'items': [
                    {
                      'id': 'm',
                      'position': 1,
                      'sender_account': 'b',
                      'target_account': 'a',
                      'created_at': '2026-11-21T00:00:00Z',
                      'kind': 'body',
                      'content': [
                        {'type': 'text', 'text': 'missed'},
                      ],
                    },
                  ],
                  'next_position': 1,
                  'has_more': false,
                };
          if (isEvents && holdNextSnapshot) {
            holdNextSnapshot = false;
            snapshotHeld.complete();
            await releaseSnapshot.future;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(value));
          await request.response.close();
        });
        final ledger = ChatLedger.inMemory();
        final feed = EventFeed(
          api: ChatApiClient(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          ),
          session: AuthSession()
            ..establish(
              token: 'private',
              user: const AuthUser(account: 'a', username: 'a'),
            ),
          ledger: ledger,
          pollInterval: const Duration(seconds: 30),
        );
        addTearDown(feed.dispose);
        await feed.subscribe(consumerSession: 'consumer', peerAccount: 'b');
        feed.start();
        await until(() => sockets.length == 1);
        await feed.pollOnce();
        Future<void>? oldPoll;
        if (holdSnapshot) {
          holdNextSnapshot = true;
          oldPoll = feed.pollOnce();
          await snapshotHeld.future.timeout(const Duration(seconds: 5));
        }
        available = true;
        await sockets.first.close();
        await until(() => sockets.length == 2);
        if (holdSnapshot) {
          // Let the client process the handshake while the old HTTP snapshot
          // remains blocked; no hint is sent and the timer is still 30 s away.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(feed.revision, 0);
          releaseSnapshot.complete();
          await oldPoll;
        }
        await until(() => feed.revision == 1);
        expect(
          (await feed.read(consumerSession: 'consumer', afterCursor: 0)).items,
          hasLength(1),
        );
        expect(await ledger.subscriptionCursor('a', 'consumer', 'b'), 1);
        await feed.pollOnce();
        expect(cursors.last, 1);
        expect(
          (await feed.read(consumerSession: 'consumer', afterCursor: 0)).items,
          hasLength(1),
        );
      },
    );
  }
  test(
    'failed handshakes back off with jitter while polling remains alive',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final attempts = <DateTime>[];
      final sockets = <WebSocket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      server.listen((request) async {
        attempts.add(DateTime.now());
        if (attempts.length <= 2) {
          request.response.statusCode = 503;
          await request.response.close();
        } else {
          sockets.add(await WebSocketTransformer.upgrade(request));
        }
      });
      final feed = EventFeed(
        api: ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        ),
        session: AuthSession()
          ..establish(
            token: 'private',
            user: const AuthUser(account: 'a', username: 'a'),
          ),
        ledger: ChatLedger.inMemory(),
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(feed.dispose);
      feed.start();
      await until(() => sockets.length == 1);
      expect(attempts.length, 3);
      expect(
        attempts[1].difference(attempts[0]).inMilliseconds,
        greaterThanOrEqualTo(490),
      );
      expect(
        attempts[2].difference(attempts[1]).inMilliseconds,
        greaterThanOrEqualTo(990),
      );
      expect(feed.lastFailure, isNull);
    },
  );

  test(
    'dispose rejects a late successful handshake without reconnecting',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final pending = Completer<HttpRequest>();
      int attempts = 0;
      server.listen((request) {
        attempts++;
        pending.complete(request);
      });
      addTearDown(() => server.close(force: true));
      final feed = EventFeed(
        api: ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        ),
        session: AuthSession()
          ..establish(
            token: 'private',
            user: const AuthUser(account: 'a', username: 'a'),
          ),
        ledger: ChatLedger.inMemory(),
      );
      addTearDown(feed.dispose);
      feed.start();
      final request = await pending.future;
      await feed.dispose();
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((_) {});
      addTearDown(socket.close);
      await until(() => socket.readyState == WebSocket.closed);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(attempts, 1);
    },
  );
  test(
    'WebSocket handshake timeout closes the underlying TCP connection',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closed = Completer<void>();
      final accepted = <Socket>[];
      server.listen((socket) {
        accepted.add(socket);
        socket.listen(
          (_) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object _) {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      addTearDown(() async {
        for (final socket in accepted) {
          socket.destroy();
        }
        await server.close();
      });
      final api = ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        api.connectEvents('private'),
        throwsA(isA<TimeoutException>()),
      );
      await closed.future.timeout(const Duration(seconds: 1));
    },
  );
  test(
    'running feed follows login and account changes without duplicate sockets',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final tokens = <String?>[];
      final sockets = <WebSocket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      server.listen((request) async {
        tokens.add(request.headers.value(HttpHeaders.authorizationHeader));
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((_) {});
      });
      final session = AuthSession();
      final feed = EventFeed(
        api: ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        ),
        session: session,
        ledger: ChatLedger.inMemory(),
        pollInterval: const Duration(milliseconds: 20),
      );
      addTearDown(feed.dispose);
      feed.start();
      session.establish(
        token: 'first',
        user: const AuthUser(account: 'a', username: 'a'),
      );
      await until(() => sockets.length == 1);
      session.establish(
        token: 'second',
        user: const AuthUser(account: 'b', username: 'b'),
      );
      await until(() => sockets.length == 2);
      expect(tokens, ['Bearer first', 'Bearer second']);
      session.clear();
      await until(() => sockets.every((s) => s.readyState == WebSocket.closed));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(tokens.length, 2);
    },
  );
  test(
    'real WebSocket disconnect reconnects once and dispose cancels retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      server.listen((request) async {
        sockets.add(await WebSocketTransformer.upgrade(request));
      });
      final feed = EventFeed(
        api: ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        ),
        session: AuthSession()
          ..establish(
            token: 'private',
            user: const AuthUser(account: 'a', username: 'a'),
          ),
        ledger: ChatLedger.inMemory(),
        pollInterval: const Duration(milliseconds: 50),
      );
      addTearDown(feed.dispose);
      feed.start();
      feed.start();
      await until(() => sockets.length == 1);
      await sockets.first.close();
      await until(() => sockets.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        sockets.length,
        2,
        reason: 'poll ticks must not duplicate an open connection',
      );
      await sockets.last.close();
      await feed.dispose();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(sockets.length, 2);
    },
  );
}
