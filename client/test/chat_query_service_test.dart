import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_query.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

/// Unified client query semantics: only the current account's conversations,
/// stable pagination, uniform safe misses, ordered/bounded history and context,
/// and no implicit ACK/consumption. The shared v2 query routes will delegate to
/// this service; wire routing stays with Forge's exact contract commit.
const String _a = '10000001';
const String _b = '10000002';
const String _c = '10000003';
const String _d = '10000004';
const String _e = '10000005';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService service;
  late String mediaId;
  late String b1Id;
  late String a2Id;
  late String b3Id;

  AuthUser user(String account) => AuthUser(
    account: account,
    username: 'user-$account',
  );

  Matcher failure(int status, String code) => isA<AuthFailure>()
      .having((AuthFailure f) => f.status, 'status', status)
      .having((AuthFailure f) => f.code, 'code', code);

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{
        _a: 'alice',
        _b: 'bob',
        _c: 'carol',
        _d: 'dave',
        _e: 'erin',
      },
    );
    root = await Directory.systemTemp.createTemp('bb-query-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_a), user: user(_a));
    service = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
    mediaId = await backend.addImage(
      owner: _a,
      peer: _b,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    // A↔B has an ordered text→image message at position 2.
    b1Id = await backend.seedMessage(sender: _b, target: _a, text: 'b1');
    a2Id = await backend.seedMessage(
      sender: _a,
      target: _b,
      text: 'a2',
      mediaId: mediaId,
    );
    b3Id = await backend.seedMessage(sender: _b, target: _a, text: 'b3');
    // A↔C, a self-only A↔E conversation, and a silent directory user D.
    await backend.seedMessage(sender: _c, target: _a, text: 'c1');
    await backend.seedMessage(sender: _a, target: _e, text: 'hello-e');
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('conversations are only existing private chats with stable pages',
      () async {
    final ConversationPage page = await service.query.listConversations(
      limit: 50,
    );
    expect(
      page.items.map((ConversationSummary item) => item.peer.account).toList(),
      <String>[_b, _c, _e],
      reason: 'D has no conversation; no third-party chat is visible',
    );
    final ConversationSummary b = page.items.first;
    expect(b.lastMessage!.senderAccount, _b);
    expect(b.lastMessage!.previewBody, contains('b3'));
    expect(b.lastActivityAt, isNotNull);
    expect(b.unread, ConversationUnread.unknown);
    expect(page.nextCursor, isNull);
    expect(page.hasMore, isFalse);

    final List<String> seen = <String>[];
    String cursor = '';
    for (int i = 0; i < 10; i++) {
      final ConversationPage chunk = await service.query.listConversations(
        afterAccount: cursor,
        limit: 1,
      );
      seen.addAll(
        chunk.items.map((ConversationSummary item) => item.peer.account),
      );
      if (!chunk.hasMore || chunk.nextCursor == null) {
        break;
      }
      cursor = chunk.nextCursor!;
    }
    expect(seen, <String>[_b, _c, _e], reason: 'no duplicates or gaps');
  });

  test('unread is the consumer watermark, never a read receipt', () async {
    final String consumer = (await service.identityFor('q-reader')).consumerId;
    ConversationPage page = await service.query.listConversations(
      limit: 50,
      consumerId: consumer,
    );
    ConversationSummary unread(String account) =>
        page.items.firstWhere((ConversationSummary item) => item.peer.account == account);
    expect(unread(_b).unread, ConversationUnread.unread);
    expect(unread(_b).firstUnreadPosition, 1);
    expect(unread(_c).unread, ConversationUnread.unread);
    expect(
      unread(_e).unread,
      ConversationUnread.none,
      reason: 'a self-only conversation has nothing for the consumer',
    );

    await service.ledger.setConsumedThrough(
      _a,
      _b,
      3,
      consumerId: consumer,
    );
    page = await service.query.listConversations(
      limit: 50,
      consumerId: consumer,
    );
    expect(unread(_b).unread, ConversationUnread.none);
    expect(unread(_c).unread, ConversationUnread.unread);
    // Querying did not ACK: only the explicit watermark moved.
    expect(
      await service.ledger.consumedThrough(
        _a,
        _c,
        consumerId: consumer,
      ),
      0,
    );
  });

  test('history is bidirectional, ordered and mutually exclusive', () async {
    final HistoryPage first = await service.query.readHistory(
      peerAccount: _b,
      afterPosition: 0,
      limit: 2,
    );
    expect(first.items.map((ChatMessage m) => m.position), <int>[1, 2]);
    expect(first.hasMore, isTrue);
    expect(first.order, HistoryOrder.ascending);
    expect(first.truncated, isFalse);

    final HistoryPage second = await service.query.readHistory(
      peerAccount: _b,
      afterPosition: 2,
      limit: 2,
    );
    expect(second.items.map((ChatMessage m) => m.position), <int>[3]);
    expect(second.hasMore, isFalse);

    final HistoryPage before = await service.query.readHistory(
      peerAccount: _b,
      beforePosition: 3,
      limit: 2,
    );
    expect(before.items.map((ChatMessage m) => m.position), <int>[1, 2]);
    expect(before.hasMore, isFalse);

    final HistoryPage beforeOne = await service.query.readHistory(
      peerAccount: _b,
      beforePosition: 1,
    );
    expect(beforeOne.items, isEmpty);

    final HistoryPage tail = await service.query.readHistory(
      peerAccount: _b,
      beforePosition: 1000,
      limit: 2,
    );
    expect(tail.items.map((ChatMessage m) => m.position), <int>[2, 3]);
    expect(tail.hasMore, isTrue);

    await expectLater(
      service.query.readHistory(
        peerAccount: _b,
        afterPosition: 0,
        beforePosition: 3,
      ),
      throwsA(failure(422, 'validation_error')),
    );
    await expectLater(
      service.query.readHistory(peerAccount: _b, beforePosition: -1),
      throwsA(failure(422, 'validation_error')),
    );
    await expectLater(
      service.query.readHistory(peerAccount: _a),
      throwsA(isA<MessageNotVisible>()),
    );
  });

  test('getMessage preserves ordered media and reports a safe bounded miss',
      () async {
    final MessageLookup lookup = await service.query.getMessage(
      peerAccount: _b,
      messageId: a2Id,
    );
    expect(lookup.truncated, isFalse);
    final ChatMessage message = lookup.message!;
    expect(message.position, 2);
    expect(message.parts, hasLength(2));
    expect((message.parts[0] as TextPart).text, 'a2');
    expect((message.parts[1] as ImagePart).mediaId, mediaId);

    expect(
      (await service.query.getMessage(peerAccount: _b, messageId: 'missing'))
          .message,
      isNull,
    );

    // A third-party conversation is not visible through A's peer scope.
    final String third = await backend.seedMessage(
      sender: _c,
      target: _d,
      text: 'third-party',
    );
    expect(
      (await service.query.getMessage(peerAccount: _b, messageId: third))
          .message,
      isNull,
    );

    // The scan bound is explicit: not finding the id inside it is truncated,
    // not a claim that the message does not exist.
    final ChatQueryService bounded = ChatQueryService(
      api: service.api,
      session: service.session,
      ledger: service.ledger,
      maxScanMessages: 1,
    );
    final MessageLookup truncated = await bounded.getMessage(
      peerAccount: _b,
      messageId: a2Id,
    );
    expect(truncated.message, isNull);
    expect(truncated.truncated, isTrue);

    await expectLater(
      service.query.getMessage(peerAccount: _a, messageId: a2Id),
      throwsA(isA<MessageNotVisible>()),
    );
  });

  test('context is ordered with explicit range and no fabricated replies',
      () async {
    final ContextResult middle = await service.query.getContext(
      peerAccount: _b,
      messageId: a2Id,
      before: 1,
      after: 1,
    );
    expect(middle.message!.position, 2);
    expect(
      middle.items.map((ChatMessage m) => m.position),
      <int>[1, 2, 3],
    );
    expect(middle.truncated, isFalse);
    expect(middle.truncatedBefore, isFalse);
    expect(middle.truncatedAfter, isFalse);
    expect(middle.replySupport, ReplySupport.unsupported);
    expect(middle.toJson()['replies'], isEmpty);

    final ContextResult start = await service.query.getContext(
      peerAccount: _b,
      messageId: b1Id,
      before: 5,
      after: 0,
    );
    expect(start.items.map((ChatMessage m) => m.position), <int>[1]);
    expect(start.truncatedBefore, isFalse);

    final ContextResult end = await service.query.getContext(
      peerAccount: _b,
      messageId: b3Id,
      before: 2,
      after: 5,
    );
    expect(end.items.map((ChatMessage m) => m.position), <int>[1, 2, 3]);
    expect(end.truncatedAfter, isFalse);

    final ContextResult missing = await service.query.getContext(
      peerAccount: _b,
      messageId: 'missing',
    );
    expect(missing.message, isNull);
    expect(missing.items, isEmpty);

    final ChatQueryService bounded = ChatQueryService(
      api: service.api,
      session: service.session,
      ledger: service.ledger,
      maxScanMessages: 1,
    );
    final ContextResult truncated = await bounded.getContext(
      peerAccount: _b,
      messageId: a2Id,
    );
    expect(truncated.message, isNull);
    expect(truncated.truncated, isTrue);
  });

  test('queries never ACK, confirm or create receipts', () async {
    final String consumer = (await service.identityFor('q-reader')).consumerId;
    final int consumedBefore = await service.ledger.consumedThrough(
      _a,
      _b,
      consumerId: consumer,
    );
    final int receiptsBefore = (await service.ledger.receiptsForPeer(
      account: _a,
      consumerSession: 'q-reader',
      peerAccount: _b,
      consumerId: consumer,
    )).length;

    await service.query.listConversations(limit: 50, consumerId: consumer);
    await service.query.readHistory(peerAccount: _b, afterPosition: 0);
    await service.query.readHistory(peerAccount: _b, beforePosition: 3);
    await service.query.getMessage(peerAccount: _b, messageId: a2Id);
    await service.query.getContext(
      peerAccount: _b,
      messageId: a2Id,
      before: 1,
      after: 1,
    );

    expect(
      await service.ledger.consumedThrough(_a, _b, consumerId: consumer),
      consumedBefore,
    );
    expect(
      (await service.ledger.receiptsForPeer(
        account: _a,
        consumerSession: 'q-reader',
        peerAccount: _b,
        consumerId: consumer,
      )).length,
      receiptsBefore,
    );
  });
}
