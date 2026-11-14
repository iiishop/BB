import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

const String _accountA = '10000001';
const String _accountB = '10000002';
const String _accountC = '10000003';

class _FaultApi extends ChatApiClient {
  _FaultApi({required super.baseUri});
  Object? failure;
  @override
  Future<MessagePage> conversation({required String token, required String account, int? afterPosition = 0, int? beforePosition, int limit = 50}) {
    if (account == _accountB && failure != null) throw failure!;
    return super.conversation(token: token, account: account, afterPosition: afterPosition, beforePosition: beforePosition, limit: limit);
  }
}

void main() {
  late FakeChatBackend backend;
  late Directory root;

  ChatService service(String account) {
    final AuthSession session = AuthSession()
      ..establish(
        token: backend.tokenFor(account),
        user: AuthUser(
          account: account,
          username: account == _accountA ? 'alice' : 'bob',
        ),
      );
    return ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger-$account.json'),
      cacheRoot: Directory('${root.path}/cache-$account'),
      webSocketHints: false,
    );
  }

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_accountA: 'alice', _accountB: 'bob', _accountC: 'carol'},
    );
    root = await Directory.systemTemp.createTemp('bb-consumer-backfill-');
  });

  tearDown(() async {
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('notification metadata failure is deferred without starving another peer', () async {
    final api = _FaultApi(baseUri: backend.baseUri);
    final session = AuthSession()..establish(token: backend.tokenFor(_accountA), user: const AuthUser(account: _accountA, username: 'a'));
    final alice = ChatService(api: api, session: session, ledger: ChatLedger.atPath('${root.path}/retry.json'), cacheRoot: Directory('${root.path}/cache'), webSocketHints: false);
    addTearDown(alice.dispose);
    await backend.seedMessage(sender: _accountB, target: _accountA, text: 'b');
    await backend.seedMessage(sender: _accountC, target: _accountA, text: 'c');
    final identity = await alice.identityFor('notification-fault');
    await alice.subscribeEventsFor(expectedIdentity: identity, discover: true);
    api.failure = const AuthFailure(status: 503, code: 'upstream_unavailable', message: 'peer B');
    final page = await alice.notificationChanges(expectedIdentity: identity, afterCursor: 0);
    expect((page['items'] as List).map((i) => i['peer_account']), [_accountC]);
    expect((page['deferred'] as List).single['peer_account'], _accountB);
    expect(await alice.ledger.displayedMessageIds(_accountA), isEmpty);
    final retry = [(page['deferred'] as List).single['cursor'] as int];
    api.failure = null;
    final resumed = await alice.notificationChanges(expectedIdentity: identity, afterCursor: page['next_cursor'] as int, retryCursors: retry);
    expect((resumed['items'] as List).map((i) => i['peer_account']), [_accountB]);
    expect(resumed['deferred'], isEmpty);
    for (final code in ['stale_identity', 'stale_binding', 'storage_unavailable']) {
      api.failure = AuthFailure(status: 409, code: code, message: 'shared');
      await expectLater(alice.notificationChanges(expectedIdentity: identity, afterCursor: page['next_cursor'] as int, retryCursors: retry), throwsA(isA<AuthFailure>().having((e) => e.code, 'code', code)));
    }
  });

  test('one consumer backfills a second peer after the first advanced', () async {
    await backend.seedMessage(sender: _accountC, target: _accountA, text: 'c-old');
    await backend.seedMessage(sender: _accountB, target: _accountA, text: 'b-new');
    final ChatService alice = service(_accountA);
    addTearDown(alice.dispose);
    await alice.subscribeEvents(consumerSession: 'multi', peerAccount: _accountB);
    final LocalEventPage first = await alice.readEvents(consumerSession: 'multi', afterCursor: 0);
    expect(first.items.map((e) => e.event.peerAccount), <String>[_accountB]);
    await alice.subscribeEvents(consumerSession: 'multi', peerAccount: _accountC);
    await alice.subscribeEvents(consumerSession: 'multi', peerAccount: _accountC);
    final LocalEventPage second = await alice.readEvents(consumerSession: 'multi', afterCursor: first.nextCursor);
    expect(second.items.map((e) => e.event.peerAccount), <String>[_accountC]);
    await backend.seedMessage(sender: _accountB, target: _accountA, text: 'b-later');
    await alice.eventFeed.pollOnce();
    final LocalEventPage rest = await alice.readEvents(consumerSession: 'multi', afterCursor: second.nextCursor);
    expect(rest.items.map((e) => e.event.peerAccount), <String>[_accountB]);
  });

  test('discovery includes first contact and explicit subscription stays narrow', () async {
    final ChatService alice = service(_accountA);
    addTearDown(alice.dispose);
    final ExpectedIdentity identity = await alice.identityFor('all-chats');
    await alice.subscribeEventsFor(expectedIdentity: identity, discover: true);
    await alice.subscribeEvents(consumerSession: 'explicit', peerAccount: _accountB);
    await backend.seedMessage(sender: _accountB, target: _accountA, text: 'b');
    await backend.seedMessage(sender: _accountC, target: _accountA, text: 'new c');
    await alice.eventFeed.pollOnce();
    final all = await alice.readEventsFor(expectedIdentity: identity, afterCursor: 0);
    expect(all.items.map((e) => e.event.peerAccount).toSet(), {_accountB, _accountC});
    expect((await alice.readEvents(consumerSession: 'explicit', afterCursor: 0)).items.map((e) => e.event.peerAccount), [_accountB]);
    expect(await alice.ledger.displayedMessageIds(_accountA), isEmpty);
    await alice.eventFeed.pollOnce();
    expect((await alice.readEventsFor(expectedIdentity: identity, afterCursor: all.nextCursor)).items, isEmpty);
    expect(await alice.ledger.discoversConversations(_accountA, identity.consumerId), true);
  });

  test('peer failure does not starve others; identity and storage errors propagate', () async {
    final session = AuthSession()..establish(token: backend.tokenFor(_accountA), user: const AuthUser(account: _accountA, username: 'alice'));
    final api = _FaultApi(baseUri: backend.baseUri);
    final alice = ChatService(api: api, session: session, ledger: ChatLedger.inMemory(), cacheRoot: root, webSocketHints: false);
    addTearDown(alice.dispose);
    await alice.subscribeEvents(consumerSession: 'multi', peerAccount: _accountB);
    await alice.subscribeEvents(consumerSession: 'multi', peerAccount: _accountC);
    await backend.seedMessage(sender: _accountB, target: _accountA, text: 'b');
    await backend.seedMessage(sender: _accountC, target: _accountA, text: 'c');
    api.failure = const AuthFailure(status: 404, code: 'not_found', message: 'synthetic peer fault');
    await alice.eventFeed.pollOnce();
    expect((await alice.readEvents(consumerSession: 'multi', afterCursor: 0)).items.map((e) => e.event.peerAccount), [_accountC]);
    for (final code in ['stale_binding', 'stale_identity', 'storage_unavailable', 'storage_io_error', 'unauthenticated']) {
      api.failure = AuthFailure(status: 503, code: code, message: 'synthetic shared failure');
      await expectLater(alice.eventFeed.pollOnce(), throwsA(isA<AuthFailure>().having((e) => e.code, 'code', code)));
    }
    api.failure = const FileSystemException('shared file failure');
    await expectLater(alice.eventFeed.pollOnce(), throwsA(isA<FileSystemException>()));
    api.failure = null;
    await alice.eventFeed.pollOnce();
    expect((await alice.readEvents(consumerSession: 'multi', afterCursor: 0)).items.map((e) => e.event.peerAccount), [_accountC, _accountB]);
  });

  test('failure after event append retries scan without duplicating the event', () async {
    final session = AuthSession()..establish(token: backend.tokenFor(_accountA), user: const AuthUser(account: _accountA, username: 'alice'));
    final path = '${root.path}/crash-ledger.json';
    int commits = 0;
    bool inject = false;
    final ledger = ChatLedger.atPath(path, beforeReplace: () async {
      if (inject && ++commits == 2) throw const FileSystemException('after append before scan commit');
    });
    final alice = ChatService(api: ChatApiClient(baseUri: backend.baseUri), session: session, ledger: ledger, cacheRoot: root, webSocketHints: false);
    addTearDown(alice.dispose);
    final identity = await alice.identityFor('crash-reader');
    await alice.subscribeEventsFor(expectedIdentity: identity, peerAccount: _accountB);
    await backend.seedMessage(sender: _accountB, target: _accountA, text: 'one event');
    inject = true;
    await expectLater(alice.eventFeed.pollOnce(), throwsA(isA<FileSystemException>()));
    expect(await ledger.subscriptionCursor(_accountA, identity.consumerId, _accountB), 0);
    expect((await alice.readEventsFor(expectedIdentity: identity, afterCursor: 0)).items, hasLength(1));
    inject = false;
    await alice.eventFeed.pollOnce();
    final cold = ChatLedger.atPath(path);
    expect(await cold.subscriptionCursor(_accountA, identity.consumerId, _accountB), greaterThan(0));
    expect((await cold.readLocalEvents(account: _accountA, consumerSession: identity.consumerId, afterCursor: 0)).items, hasLength(1));
    expect(await cold.displayedMessageIds(_accountA), isEmpty);
  });

  test(
    'a new consumer recovers pre-registration backlog independently',
    () async {
      await backend.seedMessage(
        sender: _accountB,
        target: _accountA,
        text: 'incoming-1',
      );
      await backend.seedMessage(
        sender: _accountB,
        target: _accountA,
        text: 'incoming-2',
      );

      final ChatService alice = service(_accountA);
      addTearDown(alice.dispose);
      await alice.subscribeEvents(
        consumerSession: 'consumer-a',
        peerAccount: _accountB,
      );
      await alice.eventFeed.pollOnce();
      final LocalEventPage aPage = await alice.readEvents(
        consumerSession: 'consumer-a',
        afterCursor: 0,
      );
      expect(aPage.items, hasLength(2));

      // Consumer B starts at its own persisted source cursor (0), not A's.
      await alice.subscribeEvents(
        consumerSession: 'consumer-b',
        peerAccount: _accountB,
      );
      await alice.eventFeed.pollOnce();
      final LocalEventPage bFirst = await alice.readEvents(
        consumerSession: 'consumer-b',
        afterCursor: 0,
        limit: 1,
      );
      expect(bFirst.items, hasLength(1));
      expect(bFirst.hasMore, isTrue);
      final LocalEventPage bRest = await alice.readEvents(
        consumerSession: 'consumer-b',
        afterCursor: bFirst.nextCursor,
        limit: 100,
      );
      expect(bRest.items, hasLength(1));
      expect(bFirst.items.single.event.peerAccount, _accountB);
      expect(bRest.items.single.event.peerAccount, _accountB);

      // A is not replayed or marked differently by B's backfill.
      expect(
        (await alice.readEvents(
          consumerSession: 'consumer-a',
          afterCursor: 0,
        )).items,
        hasLength(2),
      );

      // Duplicate registration must not reset B's cursor or duplicate events.
      await alice.subscribeEvents(
        consumerSession: 'consumer-b',
        peerAccount: _accountB,
      );
      await alice.eventFeed.pollOnce();
      expect(
        (await alice.readEvents(
          consumerSession: 'consumer-b',
          afterCursor: 0,
        )).items,
        hasLength(2),
      );

      // A message arriving after registration is appended once.
      await backend.seedMessage(
        sender: _accountB,
        target: _accountA,
        text: 'incoming-3',
      );
      await alice.eventFeed.pollOnce();
      final LocalEventPage bAfter = await alice.readEvents(
        consumerSession: 'consumer-b',
        afterCursor: bRest.nextCursor,
      );
      expect(bAfter.items, hasLength(1));
      expect(
        (await alice.readEvents(
          consumerSession: 'consumer-b',
          afterCursor: 0,
        )).items,
        hasLength(3),
      );

      // Restart with the same ledger: a new login does not silently rebind the
      // old consumer alias; an explicit revision-checked rebind is required.
      final String consumerB =
          (await alice.identityFor('consumer-b')).consumerId;
      final ChatService restarted = service(_accountA);
      addTearDown(restarted.dispose);
      await expectLater(
        restarted.subscribeEvents(
          consumerSession: 'consumer-b',
          peerAccount: _accountB,
        ),
        throwsA(
          isA<AuthFailure>().having(
            (AuthFailure failure) => failure.code,
            'code',
            staleIdentityCode,
          ),
        ),
      );
      final ConsumerBinding oldIdentity = (await restarted.ledger.bindingById(
        consumerB,
      ))!;
      await restarted.ledger.bindConsumer(
        account: _accountA,
        authGeneration: restarted.session.identity!.authGeneration,
        consumerSession: 'consumer-b',
        expectedBindingRevision: oldIdentity.bindingRevision,
      );
      await restarted.subscribeEvents(
        consumerSession: 'consumer-b',
        peerAccount: _accountB,
      );
      await restarted.eventFeed.pollOnce();
      expect(
        (await restarted.readEvents(
          consumerSession: 'consumer-b',
          afterCursor: 0,
        )).items,
        hasLength(3),
      );
    },
  );
}
