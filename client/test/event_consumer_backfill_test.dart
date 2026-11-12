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
      users: <String, String>{_accountA: 'alice', _accountB: 'bob'},
    );
    root = await Directory.systemTemp.createTemp('bb-consumer-backfill-');
  });

  tearDown(() async {
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
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
      final ExpectedIdentity oldIdentity = (await restarted.ledger
          .expectedIdentityForSession(_accountA, 'consumer-b'))!;
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
