import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_query.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

/// Query service over the shared server query layer: direct lookup/context
/// (never local scans), consumer enrichment, identity fencing and no ACK.
const String _a = '10000001';
const String _b = '10000002';
const String _c = '10000003';
const String _d = '10000004';
const String _e = '10000005';

class _Gate {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  Future<void> pause() async {
    if (!entered.isCompleted) {
      entered.complete();
    }
    await release.future;
  }
}

class _GatedQueryApi extends ChatApiClient {
  _GatedQueryApi({required super.baseUri, required this.gate});

  final _Gate gate;

  @override
  Future<ConversationRecordPage> conversations({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    final ConversationRecordPage page = await super.conversations(
      token: token,
      afterAccount: afterAccount,
      limit: limit,
    );
    await gate.pause();
    return page;
  }

  @override
  Future<ChatMessage?> messageById({
    required String token,
    required String messageId,
  }) async {
    final ChatMessage? message = await super.messageById(
      token: token,
      messageId: messageId,
    );
    await gate.pause();
    return message;
  }

  @override
  Future<MessageContextRecord?> messageContext({
    required String token,
    required String messageId,
    int beforeLimit = 10,
    int afterLimit = 10,
  }) async {
    final MessageContextRecord? record = await super.messageContext(
      token: token,
      messageId: messageId,
      beforeLimit: beforeLimit,
      afterLimit: afterLimit,
    );
    await gate.pause();
    return record;
  }

  @override
  Future<MessagePage> conversation({
    required String token,
    required String account,
    int? afterPosition = 0,
    int? beforePosition,
    int limit = 50,
  }) async {
    final MessagePage page = await super.conversation(
      token: token,
      account: account,
      afterPosition: afterPosition,
      beforePosition: beforePosition,
      limit: limit,
    );
    await gate.pause();
    return page;
  }
}

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
    // A↔C and a self-only A↔E conversation; D has no messages.
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

  test('conversations are existing private chats with consumer enrichment',
      () async {
    final String consumer = (await service.identityFor('q-reader')).consumerId;
    final ConversationPage page = await service.query.listConversations(
      consumerId: consumer,
    );
    expect(
      page.items.map((ConversationSummary item) => item.peerAccount).toList(),
      <String>[_b, _c, _e],
      reason: 'D has no messages; peer-account keyset order',
    );
    final ConversationSummary b = page.items.first;
    expect(b.lastMessage.senderAccount, _b);
    expect(b.latestPosition, 3);
    expect(b.consumedThrough, 0);
    expect(b.unconsumedPositions, 3);
    expect(b.lastActivityAt.isUtc, isTrue);
    expect(page.nextCursor, isNull);

    await service.ledger.setConsumedThrough(
      _a,
      _b,
      3,
      consumerId: consumer,
    );
    final ConversationPage after = await service.query.listConversations(
      consumerId: consumer,
    );
    final ConversationSummary bAfter = after.items.first;
    expect(bAfter.consumedThrough, 3);
    expect(bAfter.unconsumedPositions, 0);
    // Enrichment never ACKs the other conversation.
    expect(
      await service.ledger.consumedThrough(_a, _c, consumerId: consumer),
      0,
    );

    final ConversationPage firstPage = await service.query.listConversations(
      consumerId: consumer,
      limit: 1,
    );
    expect(firstPage.items.map((ConversationSummary i) => i.peerAccount), <String>[_b]);
    expect(firstPage.nextCursor, _b);
    final ConversationPage secondPage = await service.query.listConversations(
      consumerId: consumer,
      afterAccount: firstPage.nextCursor!,
      limit: 1,
    );
    expect(secondPage.items.map((ConversationSummary i) => i.peerAccount), <String>[_c]);
    expect(secondPage.nextCursor, _c);
  });

  test('a consumer id must be bound to the authenticated account', () async {
    await expectLater(
      service.query.listConversations(consumerId: 'c-not-a-binding'),
      throwsA(failure(409, 'stale_binding')),
    );
    final ConsumerBinding other = await service.ledger.bindConsumer(
      account: _b,
      authGeneration: 'g-other',
      consumerSession: 'b-query',
    );
    await expectLater(
      service.query.listConversations(consumerId: other.consumerId),
      throwsA(failure(409, 'stale_binding')),
    );
  });

  test('message lookup is direct, ordered and uniformly safe on miss',
      () async {
    final ChatMessage message = (await service.query.messageById(a2Id))!;
    expect(message.position, 2);
    expect(message.parts, hasLength(2));
    expect((message.parts[0] as TextPart).text, 'a2');
    expect((message.parts[1] as ImagePart).mediaId, mediaId);

    expect(await service.query.messageById('missing'), isNull);
    final String third = await backend.seedMessage(
      sender: _c,
      target: _d,
      text: 'third-party',
    );
    expect(await service.query.messageById(third), isNull);
  });

  test('context comes from the server with explicit range and gaps', () async {
    final ContextResult middle = (await service.query.getContext(
      messageId: a2Id,
      beforeLimit: 1,
      afterLimit: 1,
    ))!;
    expect(
      middle.items.map((ChatMessage message) => message.position).toList(),
      <int>[1, 2, 3],
    );
    expect(middle.anchorMessageId, a2Id);
    expect(middle.peerAccount, _b);
    expect(middle.startPosition, 1);
    expect(middle.endPosition, 3);
    expect(middle.beforeHasMore, isFalse);
    expect(middle.afterHasMore, isFalse);
    expect(middle.missingPositions, isEmpty);
    expect(middle.missingTruncated, isFalse);
    expect(middle.replyRelations, 'unsupported');

    final ContextResult start = (await service.query.getContext(
      messageId: b1Id,
      beforeLimit: 5,
      afterLimit: 0,
    ))!;
    expect(start.items.map((ChatMessage m) => m.position), <int>[1]);
    expect(start.afterHasMore, isTrue);

    final ContextResult end = (await service.query.getContext(
      messageId: b3Id,
      beforeLimit: 1,
      afterLimit: 0,
    ))!;
    expect(end.items.map((ChatMessage m) => m.position), <int>[2, 3]);
    expect(end.beforeHasMore, isTrue);
    expect(end.afterHasMore, isFalse);

    expect(
      await service.query.getContext(messageId: 'missing'),
      isNull,
    );

    // A real storage gap inside the returned range is explicit.
    await backend.seedMessageAtPosition(
      sender: _c,
      target: _a,
      text: 'c2',
      position: 2,
    );
    await backend.seedMessageAtPosition(
      sender: _c,
      target: _a,
      text: 'c4',
      position: 4,
    );
    final ContextResult gap = (await service.query.getContext(
      messageId: 'm6',
      beforeLimit: 0,
      afterLimit: 2,
    ))!;
    expect(gap.items, hasLength(2));
    expect(gap.missingPositions, <int>[3]);
    expect(gap.missingTruncated, isFalse);
  });

  test('history is bidirectional, ascending and mutually exclusive', () async {
    final HistoryPage after = await service.query.readHistory(
      peerAccount: _b,
      afterPosition: 0,
      limit: 2,
    );
    expect(after.items.map((ChatMessage m) => m.position), <int>[1, 2]);
    expect(after.nextPosition, 2);
    expect(after.hasMore, isTrue);

    final HistoryPage afterTail = await service.query.readHistory(
      peerAccount: _b,
      afterPosition: 2,
      limit: 2,
    );
    expect(afterTail.items.map((ChatMessage m) => m.position), <int>[3]);
    expect(afterTail.nextPosition, 3);
    expect(afterTail.hasMore, isFalse);

    final HistoryPage before = await service.query.readHistory(
      peerAccount: _b,
      beforePosition: 3,
      limit: 2,
    );
    expect(before.items.map((ChatMessage m) => m.position), <int>[1, 2]);
    expect(before.nextPosition, 1);
    expect(before.hasMore, isFalse);

    final HistoryPage tail = await service.query.readHistory(
      peerAccount: _b,
      beforePosition: 1000,
      limit: 2,
    );
    expect(tail.items.map((ChatMessage m) => m.position), <int>[2, 3]);
    expect(tail.nextPosition, 2);
    expect(tail.hasMore, isTrue);

    final HistoryPage empty = await service.query.readHistory(
      peerAccount: _b,
      beforePosition: 1,
    );
    expect(empty.items, isEmpty);
    expect(empty.nextPosition, 1);

    await expectLater(
      service.query.readHistory(
        peerAccount: _b,
        afterPosition: 0,
        beforePosition: 3,
      ),
      throwsA(failure(422, 'validation_error')),
    );
    await expectLater(
      service.query.readHistory(peerAccount: _b, beforePosition: 0),
      throwsA(failure(422, 'validation_error')),
    );
  });

  test('queries revalidate identity before returning', () async {
    Future<void> expectStale(
      Future<Object?> Function(ChatQueryService query) run, {
      required Future<void> Function() switchSession,
    }) async {
      final _Gate gate = _Gate();
      final ChatQueryService gated = ChatQueryService(
        api: _GatedQueryApi(baseUri: backend.baseUri, gate: gate),
        session: session,
        ledger: service.ledger,
      );
      final Future<Object?> pending = run(gated);
      await gate.entered.future;
      await switchSession();
      gate.release.complete();
      await expectLater(pending, throwsA(same(staleIdentityFailure)));
    }

    final String consumer = (await service.identityFor('q-reader')).consumerId;
    void asAlice() {
      session.establish(token: backend.tokenFor(_a), user: user(_a));
    }

    asAlice();
    await expectStale(
      (ChatQueryService query) =>
          query.listConversations(consumerId: consumer),
      switchSession: () async {
        session.establish(token: backend.tokenFor(_b), user: user(_b));
      },
    );
    asAlice();
    await expectStale(
      (ChatQueryService query) => query.messageById(a2Id),
      switchSession: () async {
        // Same-account re-login also invalidates the captured generation.
        session.establish(token: backend.tokenFor(_a), user: user(_a));
      },
    );
    asAlice();
    await expectStale(
      (ChatQueryService query) => query.getContext(messageId: a2Id),
      switchSession: () async {
        session.establish(token: backend.tokenFor(_b), user: user(_b));
      },
    );
    asAlice();
    await expectStale(
      (ChatQueryService query) => query.readHistory(peerAccount: _b),
      switchSession: () async {
        session.establish(token: backend.tokenFor(_b), user: user(_b));
      },
    );
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

    await service.query.listConversations(consumerId: consumer);
    await service.query.readHistory(peerAccount: _b, afterPosition: 0);
    await service.query.readHistory(peerAccount: _b, beforePosition: 3);
    await service.query.messageById(a2Id);
    await service.query.getContext(messageId: a2Id);

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
