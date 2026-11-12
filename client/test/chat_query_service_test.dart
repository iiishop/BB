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

/// Unified client query semantics: only the current account's conversations,
/// stable pagination, uniform safe misses, ordered/bounded history and context,
/// and no implicit ACK/consumption. The shared v2 query routes will delegate to
/// this service; wire routing stays with Forge's exact contract commit.
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
  Future<MessagePage> conversation({
    required String token,
    required String account,
    int afterPosition = 0,
    int limit = 50,
  }) async {
    final MessagePage page = await super.conversation(
      token: token,
      account: account,
      afterPosition: afterPosition,
      limit: limit,
    );
    await gate.pause();
    return page;
  }

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
    await gate.pause();
    return page;
  }
}

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

  test('getMessage truncation distinguishes complete and bounded scans',
      () async {
    // C has exactly one message: a one-record scan is complete, not truncated.
    final ChatQueryService one = ChatQueryService(
      api: service.api,
      session: service.session,
      ledger: service.ledger,
      maxScanMessages: 1,
    );
    final MessageLookup exhausted = await one.getMessage(
      peerAccount: _c,
      messageId: 'missing',
    );
    expect(exhausted.message, isNull);
    expect(
      exhausted.truncated,
      isFalse,
      reason: 'has_more=false and the complete page was scanned',
    );

    // B has three messages; a one-record bound leaves records unscanned.
    final MessageLookup bounded = await one.getMessage(
      peerAccount: _b,
      messageId: 'missing',
    );
    expect(bounded.message, isNull);
    expect(bounded.truncated, isTrue);

    // A hit inside the bound is a complete lookup.
    final ChatQueryService two = ChatQueryService(
      api: service.api,
      session: service.session,
      ledger: service.ledger,
      maxScanMessages: 2,
    );
    final MessageLookup hit = await two.getMessage(
      peerAccount: _b,
      messageId: a2Id,
    );
    expect(hit.message!.position, 2);
    expect(hit.truncated, isFalse);
    final MessageLookup firstHit = await one.getMessage(
      peerAccount: _b,
      messageId: b1Id,
    );
    expect(firstHit.message!.position, 1);
    expect(firstHit.truncated, isFalse);
  });

  test('a query rejects an account switch before returning an old result',
      () async {
    final _Gate gate = _Gate();
    final ChatQueryService gated = ChatQueryService(
      api: _GatedQueryApi(baseUri: backend.baseUri, gate: gate),
      session: session,
      ledger: service.ledger,
    );
    final Future<MessageLookup> pending = gated.getMessage(
      peerAccount: _b,
      messageId: a2Id,
    );
    await gate.entered.future;
    session.establish(token: backend.tokenFor(_b), user: user(_b));
    gate.release.complete();
    await expectLater(pending, throwsA(same(staleIdentityFailure)));
  });

  test('a query rejects a same-account re-login before returning old data',
      () async {
    final _Gate gate = _Gate();
    final ChatQueryService gated = ChatQueryService(
      api: _GatedQueryApi(baseUri: backend.baseUri, gate: gate),
      session: session,
      ledger: service.ledger,
    );
    final Future<HistoryPage> pending = gated.readHistory(
      peerAccount: _b,
      afterPosition: 0,
    );
    await gate.entered.future;
    session.establish(token: backend.tokenFor(_a), user: user(_a));
    gate.release.complete();
    await expectLater(pending, throwsA(same(staleIdentityFailure)));
  });

  test('conversation listing rejects a switch during the directory page',
      () async {
    final _Gate gate = _Gate();
    final ChatQueryService gated = ChatQueryService(
      api: _GatedQueryApi(baseUri: backend.baseUri, gate: gate),
      session: session,
      ledger: service.ledger,
    );
    final Future<ConversationPage> pending = gated.listConversations();
    await gate.entered.future;
    session.establish(token: backend.tokenFor(_b), user: user(_b));
    gate.release.complete();
    await expectLater(pending, throwsA(same(staleIdentityFailure)));
  });

  test('a caller-supplied consumer id must belong to the account', () async {
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
    final String own = (await service.identityFor('q-reader')).consumerId;
    expect(
      (await service.query.listConversations(consumerId: own)).items,
      isNotEmpty,
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
