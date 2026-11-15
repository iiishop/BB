import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/presence_directory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

/// DEA-476 P3 rework: request ownership is per account. A subscription that
/// starts while another account's read is still pending must issue its own
/// first read immediately, and reopening the same peer must not wait for (or
/// later accept) the abandoned read.
const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

ChatUser _peer(String account, String username, Presence presence) {
  return ChatUser(
    account: account,
    username: username,
    avatarUrl: '/avatars/$account.png',
    avatarVersion: 'v1',
    presence: presence,
  );
}

/// Takes the reply snapshot first and then delays it, so a held response
/// carries the state from when its read started.
class _SnapshotChat extends FakeChatService {
  _SnapshotChat({required super.self, required super.users});

  Completer<void>? holdTargeted;
  int heldTargeted = 0;

  @override
  Future<UserPage> listUsers({
    String afterAccount = '',
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final UserPage snapshot = await super.listUsers(
      afterAccount: afterAccount,
      limit: limit,
      expectedIdentity: expectedIdentity,
    );
    final Completer<void>? hold = limit == 1 ? holdTargeted : null;
    if (hold != null && !hold.isCompleted) {
      heldTargeted += 1;
      await hold.future;
    }
    return snapshot;
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
  test(
    'a newly watched peer reads while the abandoned peer is still pending',
    () async {
      final FakeChatService chat = FakeChatService(
        self: _self,
        users: const <ChatUser>[],
      );
      addTearDown(chat.dispose);
      final Completer<void> gate = Completer<void>();
      chat.listUsersGate = gate;
      final PresenceDirectory directory = PresenceDirectory(chat: chat);
      addTearDown(directory.dispose);

      directory.watch('10000002');
      await _waitFor(
        () => chat.listUsersCalls.any(
          (({String afterAccount, int limit}) call) =>
              call.afterAccount == '10000001',
        ),
      );

      // The user leaves bob while bob's read is still held, then opens carol.
      directory.unwatch('10000002');
      chat.listUsersGate = null;
      directory.watch('10000003');
      await _waitFor(
        () => chat.listUsersCalls.any(
          (({String afterAccount, int limit}) call) =>
              call.afterAccount == '10000002',
        ),
        // carol's own first read, not a wait for the next timer tick.
      );
      expect(gate.isCompleted, isFalse, reason: 'bob is still pending');

      gate.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'reopening the same peer starts a fresh read and ignores the old reply',
    () async {
      final _SnapshotChat chat = _SnapshotChat(
        self: _self,
        users: <ChatUser>[_peer('10000002', 'bob', Presence.offline)],
      );
      addTearDown(chat.dispose);
      final PresenceDirectory directory = PresenceDirectory(chat: chat);
      addTearDown(directory.dispose);

      final Completer<void> hold = Completer<void>();
      chat.holdTargeted = hold;
      directory.watch('10000002');
      await _waitFor(() => chat.heldTargeted == 1);

      // Close and reopen the same peer: the old read is abandoned, the new
      // subscription must read immediately (the list now says online).
      directory.unwatch('10000002');
      chat.users[0] = _peer('10000002', 'bob', Presence.online);
      chat.holdTargeted = null;
      directory.watch('10000002');
      await _waitFor(() => chat.listUsersCalls.length >= 2);
      await _waitFor(() => directory.valueFor('10000002') == Presence.online);

      // The abandoned read's late "offline" snapshot is fenced.
      hold.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        directory.valueFor('10000002'),
        Presence.online,
        reason: 'the abandoned read must not overwrite the reopened value',
      );
    },
  );
}
