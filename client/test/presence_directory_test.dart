import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/presence_directory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

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

void main() {
  late FakeChatService chat;

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[
        _peer('10000002', 'bob', Presence.online),
        _peer('10000003', 'carol', Presence.offline),
      ],
    );
  });

  tearDown(() => chat.dispose());

  test('presenceOf reads the single row directly before the peer', () async {
    expect(await chat.presenceOf('10000002'), Presence.online);
    expect(chat.listUsersCalls.last, (afterAccount: '10000001', limit: 1));

    expect(await chat.presenceOf('10000003'), Presence.offline);
    expect(chat.listUsersCalls.last, (afterAccount: '10000002', limit: 1));

    // The smallest account has no predecessor cursor; a missing account must
    // stay unknown rather than be read as offline.
    expect(await chat.presenceOf('10000009'), isNull);
    expect(await chat.presenceOf('10000000'), isNull);
  });

  test('a watched account refreshes from the shared source', () async {
    final PresenceDirectory directory = PresenceDirectory(chat: chat);
    addTearDown(directory.dispose);
    // The list page this directory adopted still said both peers were offline;
    // only bob is watched now, so carol must not be refreshed by bob's page.
    chat.users[1] = _peer('10000003', 'carol', Presence.online);
    directory.seed(<ChatUser>[
      _peer('10000002', 'bob', Presence.offline),
      _peer('10000003', 'carol', Presence.offline),
    ]);
    expect(directory.valueFor('10000002'), Presence.offline);

    int notifications = 0;
    directory.addListener(() => notifications += 1);
    directory.watch('10000002');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(directory.valueFor('10000002'), Presence.online);
    expect(notifications, greaterThan(0));
    expect(
      directory.valueFor('10000003'),
      Presence.offline,
      reason: 'an unwatched account keeps its last confirmed value',
    );
  });

  test('a disposed directory drops an in-flight refresh', () async {
    final Completer<void> gate = Completer<void>();
    chat.listUsersGate = gate;
    final PresenceDirectory directory = PresenceDirectory(chat: chat);
    int notifications = 0;
    directory.addListener(() => notifications += 1);

    directory.watch('10000002');
    await Future<void>.delayed(Duration.zero);
    directory.dispose();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(notifications, 0);
    expect(directory.valueFor('10000002'), isNull);
  });
}
