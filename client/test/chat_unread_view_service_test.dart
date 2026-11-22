import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/ui/chat/chat_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

/// DEA-489: the conversation list's incoming unread and the human UI's view
/// record. The count stays the shared `ChatQueryService.incomingUnread`
/// derivation; only an entry (or a rendered arrival) confirms display facts.
/// Consumption progress and the outbound read receipt keep their own meaning.
const String _a = '10000001';
const String _b = '10000002';
const String _c = '10000003';

AuthUser _user(String account) =>
    AuthUser(account: account, username: 'user-$account');

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService service;
  late String b1Id;
  late String a2Id;
  late String b3Id;
  late String c1Id;

  Future<ChatService> openService() async {
    final ChatService opened = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
    return opened;
  }

  Future<ConsumerBinding> humanBinding() async {
    final ExpectedIdentity identity = await service.identityFor('human:$_a');
    return (await service.ledger.bindingById(identity.consumerId))!;
  }

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_a: 'alice', _b: 'bob', _c: 'carol'},
    );
    root = await Directory.systemTemp.createTemp('bb-unread-view-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_a), user: _user(_a));
    service = await openService();
    b1Id = await backend.seedMessage(sender: _b, target: _a, text: 'b1');
    a2Id = await backend.seedMessage(sender: _a, target: _b, text: 'a2');
    b3Id = await backend.seedMessage(sender: _b, target: _a, text: 'b3');
    c1Id = await backend.seedMessage(sender: _c, target: _a, text: 'c1');
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'own sends never count; each conversation keeps its own count',
    () async {
      final Map<String, int> unread = await service.incomingUnreadByPeer();
      expect(unread[_b], 2, reason: 'a2 is outgoing and must not be counted');
      expect(unread[_c], 1);
      expect(unread.containsKey(_b), isTrue);
      // Listing is not viewing: no display receipt and no consumption movement.
      expect(await service.ledger.displayedMessageIds(_a), isEmpty);
      expect((await humanBinding()).consumerId, isNotEmpty);
      expect(
        await service.ledger.consumedThrough(
          _a,
          _b,
          consumerId: (await humanBinding()).consumerId,
        ),
        0,
      );
      // A message the account sends itself also leaves the count unchanged.
      final SendOutcome sent = await service.sendBody(
        targetAccount: _b,
        content: const <OutgoingPart>[OutgoingText('mine')],
      );
      expect(sent.succeeded, isTrue);
      expect((await service.incomingUnreadByPeer())[_b], 2);
    },
  );

  test(
    'entering clears only that conversation and never ACKs consumption',
    () async {
      final ConsumerBinding binding = await humanBinding();
      expect(await service.markConversationViewed(_b), 2);

      final Map<String, int> unread = await service.incomingUnreadByPeer();
      expect(unread[_b], 0);
      expect(unread[_c], 1, reason: 'reading B must not clear C');

      final Set<String> displayed = await service.ledger.displayedMessageIds(
        _a,
      );
      expect(displayed, <String>{b1Id, b3Id});
      expect(
        displayed,
        isNot(contains(a2Id)),
        reason: 'outgoing gets no view fact',
      );
      expect(displayed, isNot(contains(c1Id)));

      expect(
        await service.ledger.consumedThrough(
          _a,
          _b,
          consumerId: binding.consumerId,
        ),
        0,
        reason: 'enter-to-clear is not the consumer recovery watermark',
      );
      // Re-entering is idempotent and adds no second fact.
      expect(await service.markConversationViewed(_b), 0);
    },
  );

  test('leaving then receiving one new message shows 1 again', () async {
    await service.markConversationViewed(_b);
    expect((await service.incomingUnreadByPeer())[_b], 0);
    final String b4Id = await backend.seedMessage(
      sender: _b,
      target: _a,
      text: 'after leaving',
    );
    final Map<String, int> unread = await service.incomingUnreadByPeer();
    expect(unread[_b], 1);
    expect(unread[_c], 1, reason: 'other conversations are untouched');
    // The new arrival is the only unread fact.
    expect(await service.ledger.displayedMessageIds(_a), <String>{b1Id, b3Id});
    await service.markConversationViewed(_b);
    expect(await service.ledger.displayedMessageIds(_a), <String>{
      b1Id,
      b3Id,
      b4Id,
    });
    expect((await service.incomingUnreadByPeer())[_b], 0);
  });

  test('a rendered arrival is recorded without touching consumption', () async {
    final ConsumerBinding binding = await humanBinding();
    final ChatMessage arrival = (await service.query.messageById(b3Id))!;
    expect(
      await service.ledger.consumedThrough(
        _a,
        _b,
        consumerId: binding.consumerId,
      ),
      0,
    );
    expect(
      await service.recordDisplayedIncoming(
        peerAccount: _b,
        messages: <ChatMessage>[arrival],
      ),
      1,
    );
    final Map<String, int> unread = await service.incomingUnreadByPeer();
    expect(unread[_b], 1, reason: 'only position 3 was rendered');
    expect(
      await service.ledger.consumedThrough(
        _a,
        _b,
        consumerId: binding.consumerId,
      ),
      0,
      reason: 'a rendered arrival is still not an ACK',
    );
  });

  test('view facts survive a cold restart of the ledger', () async {
    await service.markConversationViewed(_b);
    await service.dispose();
    service = await openService();
    final Map<String, int> unread = await service.incomingUnreadByPeer();
    expect(unread[_b], 0);
    expect(unread[_c], 1);
  });

  test('badge label is absent at zero, exact to 99, capped above', () {
    expect(unreadBadgeLabel(0), isNull);
    expect(unreadBadgeLabel(1), '1');
    expect(unreadBadgeLabel(99), '99');
    expect(unreadBadgeLabel(100), '99+');
    expect(unreadBadgeLabel(1000), '99+');
  });
}
