import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/event_feed.dart';
import 'package:flutter_test/flutter_test.dart';

const _account = '10000001';
const _peer = '10000002';
const _consumer = 'lifecycle';
const _events = '/events';
const _history = '/conversations/$_peer/messages';
const _conversations = '/conversations';
const _time = '2026-11-21T00:00:00Z';
const _message = {
  'id': 'message-1',
  'position': 1,
  'sender_account': _peer,
  'target_account': _account,
  'created_at': _time,
  'kind': 'body',
  'content': [
    {'type': 'text', 'text': 'synthetic'},
  ],
};

class _Barrier {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> pause() async {
    entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  late EventFeed feed;
  late ChatLedger ledger;
  late String path;
  late List<String> requests;
  late bool hasMessage;
  _Barrier? heldResponse;
  String? heldPath;
  _Barrier? heldCommit;

  setUp(() async {
    requests = [];
    hasMessage = false;
    heldResponse = null;
    heldPath = null;
    heldCommit = null;
    final root = await Directory.systemTemp.createTemp('bb-feed-lifecycle-');
    addTearDown(() => root.delete(recursive: true));
    path = '${root.path}/ledger.json';
    ledger = ChatLedger.atPath(
      path,
      beforeReplace: () async {
        final barrier = heldCommit;
        heldCommit = null;
        await barrier?.pause();
      },
    );

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final route = request.uri.path;
      requests.add(route);
      // Capture the response before blocking so a restarted feed can receive
      // a fresh empty snapshot while the older snapshot remains in flight.
      final response = switch (route) {
        _events => {
          'items': [
            if (hasMessage)
              {
                'version': 1,
                'event_id': 1,
                'type': 'message.available',
                'occurred_at': _time,
                'message_id': 'message-1',
                'peer_account': _peer,
                'position': 1,
              },
          ],
          'next_event_id': hasMessage ? 1 : 0,
          'has_more': false,
        },
        _history => {
          'items': [_message],
          'next_position': 1,
          'has_more': false,
        },
        _conversations => {
          'items': [
            if (hasMessage)
              {
                'peer_account': _peer,
                'last_message': _message,
                'last_activity_at': _time,
                'latest_position': 1,
              },
          ],
          'next_cursor': null,
        },
        _ => throw StateError('Unexpected replay request $route'),
      };
      if (route == heldPath) {
        heldPath = null;
        await heldResponse!.pause();
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    feed = EventFeed(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:${server.port}')),
      session: AuthSession()
        ..establish(
          token: 'synthetic',
          user: const AuthUser(account: _account, username: 'alice'),
        ),
      ledger: ledger,
      webSocketHints: false,
      pollInterval: const Duration(minutes: 2),
    );
    addTearDown(feed.dispose);
  });

  Future<int> coldHead() =>
      ChatLedger.atPath(path).localEventHead(_account, _consumer);

  for (final route in [_events, _history, _conversations]) {
    test('dispose fences a late $route response', () async {
      final discover = route == _conversations;
      await feed.subscribe(
        consumerSession: _consumer,
        peerAccount: discover ? null : _peer,
        discover: discover,
      );
      hasMessage = true;
      final barrier = _Barrier();
      addTearDown(barrier.open);
      heldResponse = barrier;
      heldPath = route;
      final pending = feed.pollOnce();
      await barrier.entered.future.timeout(const Duration(seconds: 3));
      final requestsBeforeDispose = requests.toList();
      await feed.dispose().timeout(const Duration(seconds: 3));
      barrier.open();
      await pending;

      expect(requests, requestsBeforeDispose);
      expect(feed.revision, 0);
      expect(await coldHead(), 0);
      final coldLedger = ChatLedger.atPath(path);
      if (discover) {
        expect((await coldLedger.subscriptions(_account))[_consumer], isEmpty);
      } else {
        expect(
          await coldLedger.subscriptionCursor(_account, _consumer, _peer),
          0,
        );
      }
    });
  }

  test('stop/start gives a held replay a distinct lifetime', () async {
    await feed.subscribe(consumerSession: _consumer, peerAccount: _peer);
    hasMessage = true;
    final barrier = _Barrier();
    addTearDown(barrier.open);
    heldResponse = barrier;
    heldPath = _events;
    feed.start();
    final old = feed.pollOnce();
    await barrier.entered.future.timeout(const Duration(seconds: 3));
    feed.stop();

    hasMessage = false;
    feed.start();
    final newReplay = feed.pollOnce();
    try {
      await newReplay.timeout(const Duration(seconds: 3));
      final requestsBeforeRelease = requests.toList();
      barrier.open();
      await old;
      expect(requests, requestsBeforeRelease);
      expect(await coldHead(), 0);
    } finally {
      barrier.open();
      await old;
    }

    hasMessage = true;
    await feed.pollOnce();
    expect(requests.where((route) => route == _history), hasLength(1));
    expect(feed.revision, 1);
    expect(await coldHead(), 1);
  });

  test('dispose settles an admitted replay write before returning', () async {
    await feed.subscribe(consumerSession: _consumer, peerAccount: _peer);
    hasMessage = true;
    final barrier = _Barrier();
    addTearDown(barrier.open);
    heldCommit = barrier;
    final pending = feed.pollOnce();
    await barrier.entered.future.timeout(const Duration(seconds: 3));

    var returned = false;
    final disposing = feed.dispose().then((_) => returned = true);
    try {
      await Future<void>.delayed(Duration.zero);
      expect(returned, isFalse);
    } finally {
      barrier.open();
      await disposing;
      await pending;
    }

    expect(await coldHead(), 1);
    expect(feed.revision, 1);
    expect(
      await ChatLedger.atPath(path)
          .subscriptionCursor(_account, _consumer, _peer),
      0,
    );
  });
}
