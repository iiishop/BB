import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/presence_directory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

/// DEA-476 rework: the presence chain must be exercised across an actual
/// account switch, not inferred from unrelated identity tests. The old
/// account's in-flight `GET /users` is rejected by `ChatService` after the
/// session moved on, and the new session's directory resolves the same peer
/// under its own identity.
const String _alice = '10000001';
const String _bob = '10000002';
const String _carol = '10000003';

AuthUser _user(String account, String username) =>
    AuthUser(account: account, username: username);

class _GatedApi extends ChatApiClient {
  _GatedApi({required super.baseUri});

  Completer<void>? gate;

  /// Completes when a read is parked at [gate], so the test switches accounts
  /// at a known point instead of sleeping.
  Completer<void>? entered;

  /// Completes once the parked read leaves the HTTP layer.
  Completer<void>? released;
  int held = 0;

  @override
  Future<UserPage> listUsers({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    final UserPage page = await super.listUsers(
      token: token,
      afterAccount: afterAccount,
      limit: limit,
    );
    final Completer<void>? waiting = gate;
    if (waiting != null && !waiting.isCompleted) {
      held += 1;
      final Completer<void>? started = entered;
      if (started != null && !started.isCompleted) {
        started.complete();
      }
      await waiting.future;
      final Completer<void>? done = released;
      if (done != null && !done.isCompleted) {
        done.complete();
      }
    }
    return page;
  }
}

/// Waits for an async side effect instead of assuming a fixed sleep is enough
/// under a loaded parallel test run.
Future<void> _waitFor(bool Function() condition) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached before timeout');
}

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late _GatedApi api;
  late AuthSession session;
  late ChatService service;

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_alice: 'alice', _bob: 'bob', _carol: 'carol'},
    );
    backend.setPresence(_carol, online: true);
    root = await Directory.systemTemp.createTemp('bb-presence-switch-');
    api = _GatedApi(baseUri: backend.baseUri);
    session = AuthSession()
      ..establish(
        token: backend.tokenFor(_alice),
        user: _user(_alice, 'alice'),
      );
    service = ChatService(
      api: api,
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('a presence read in flight cannot cross an account switch', () async {
    final PresenceDirectory aliceView = PresenceDirectory(chat: service);
    addTearDown(aliceView.dispose);

    api
      ..gate = Completer<void>()
      ..entered = Completer<void>()
      ..released = Completer<void>();
    aliceView.watch(_carol);
    await api.entered!.future;
    expect(api.held, 1, reason: 'alice\'s read reached the server');

    // A different account logs in while alice's response is still in flight.
    session.establish(token: backend.tokenFor(_bob), user: _user(_bob, 'bob'));
    api.gate!.complete();
    await api.released!.future;
    // Let every queued microtask (identity check, rejection, refresh finish)
    // drain before asserting; a timer runs after the microtask queue.
    await Future<void>.delayed(Duration.zero);
    expect(
      aliceView.valueFor(_carol),
      isNull,
      reason: 'the old account read must be rejected, not applied',
    );

    // The new session's directory resolves the same peer from its own token,
    // including the value the server now reports for bob.
    backend.setPresence(_carol, online: false);
    final PresenceDirectory bobView = PresenceDirectory(chat: service);
    addTearDown(bobView.dispose);
    bobView.watch(_carol);
    await _waitFor(() => bobView.valueFor(_carol) != null);
    expect(bobView.valueFor(_carol), Presence.offline);
  });
}
