import 'dart:async';
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

/// Identity generation / binding / commit-validation tests for the second real
/// client counterexample: an old send plan replayed under the swapped account.
const String _alice = '10000001';
const String _bob = '10000002';

class _BlockingChatApi extends ChatApiClient {
  _BlockingChatApi({required super.baseUri});

  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    if (!entered.isCompleted) {
      entered.complete();
    }
    await release.future;
    return super.sendMessage(
      token: token,
      targetAccount: targetAccount,
      clientNonce: clientNonce,
      content: content,
    );
  }
}

class _UncertainChatApi extends ChatApiClient {
  _UncertainChatApi({required super.baseUri});

  int attempts = 0;

  @override
  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    attempts += 1;
    throw upstreamUnavailable;
  }
}

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late String ledgerPath;
  late AuthSession session;
  late ChatService service;

  AuthUser user(String account) => AuthUser(
    account: account,
    username: account == _alice ? 'alice' : 'bob',
  );

  ChatService build(AuthSession auth, {ChatApiClient? api}) {
    return ChatService(
      api: api ?? ChatApiClient(baseUri: backend.baseUri),
      session: auth,
      ledger: ChatLedger.atPath(ledgerPath),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
  }

  Matcher failure(int status, String code) => isA<AuthFailure>()
      .having((AuthFailure f) => f.status, 'status', status)
      .having((AuthFailure f) => f.code, 'code', code);

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_alice: 'alice', _bob: 'bob'},
    );
    root = await Directory.systemTemp.createTemp('bb-identity-generation-');
    ledgerPath = '${root.path}/ledger.json';
    session = AuthSession()
      ..establish(token: backend.tokenFor(_alice), user: user(_alice));
    service = build(session);
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('expected_identity is validated at the business layer', () async {
    final ExpectedIdentity current = await service.identityFor(
      'human:$_alice',
    );

    final SendOutcome sent = await service.sendBody(
      targetAccount: _bob,
      content: const <OutgoingPart>[OutgoingText('hello')],
      expectedIdentity: current,
    );
    expect(sent.succeeded, isTrue);
    expect(backend.sendRequests, 1);

    // A re-login rotates auth_generation and bumps the binding revision, so
    // the identity captured above can never authorize another call.
    final ExpectedIdentity before = current;
    session.establish(token: backend.tokenFor(_alice), user: user(_alice));
    final ExpectedIdentity after = await service.identityFor('human:$_alice');
    expect(after.authGeneration, isNot(before.authGeneration));
    expect(after.bindingRevision, greaterThan(before.bindingRevision));

    await expectLater(
      service.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText('must not send')],
        expectedIdentity: before,
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    expect(backend.sendRequests, 1);

    // Same account and generation but another consumer is a binding conflict.
    final ExpectedIdentity foreignConsumer = ExpectedIdentity(
      account: after.account,
      authGeneration: after.authGeneration,
      consumerId: 'c-00000000000000000000000000000000',
      bindingRevision: after.bindingRevision,
    );
    await expectLater(
      service.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText('still must not send')],
        expectedIdentity: foreignConsumer,
      ),
      throwsA(failure(409, staleBindingCode)),
    );
    expect(backend.sendRequests, 1);
  });

  test(
    'a plan accepted under A commits under A and never resumes under B',
    () async {
      final _BlockingChatApi api = _BlockingChatApi(baseUri: backend.baseUri);
      final ChatService blocking = build(session, api: api);
      addTearDown(blocking.dispose);

      final Future<SendOutcome> pending = blocking.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText('plan text')],
        operationId: 'plan-accepted-under-a',
      );
      await api.entered.future;
      // The switch happens while the captured request is in flight.
      session.establish(token: backend.tokenFor(_bob), user: user(_bob));
      api.release.complete();
      await expectLater(
        pending,
        throwsA(failure(409, staleIdentityCode)),
      );

      // The commit belonged to A and its success fact stays in A's ledger.
      expect(backend.sendRequests, 1);
      expect(backend.sendRequestAccounts, <String>[_alice]);
      final ChatOperationRecord? stored = await blocking.ledger.operation(
        _alice,
        'plan-accepted-under-a',
      );
      expect(stored, isNotNull);
      expect(stored!.state, 'succeeded');

      // Replaying the same plan as B is rejected before any send side effect.
      await expectLater(
        blocking.sendBody(
          targetAccount: _bob,
          content: const <OutgoingPart>[OutgoingText('plan text')],
          operationId: 'plan-accepted-under-a',
        ),
        throwsA(failure(409, staleIdentityCode)),
      );
      expect(backend.sendRequests, 1);
      expect(backend.sendRequestAccounts, <String>[_alice]);
      expect(
        await blocking.getOperation('plan-accepted-under-a'),
        isNull,
        reason: 'the switched account cannot read the old operation result',
      );
      expect(
        await blocking.ledger.operation(_bob, 'plan-accepted-under-a'),
        isNull,
      );
    },
  );

  test('A→B→A does not resume the old plan and sends nothing', () async {
    final _UncertainChatApi api = _UncertainChatApi(baseUri: backend.baseUri);
    final ChatService uncertain = build(session, api: api);
    addTearDown(uncertain.dispose);

    await expectLater(
      uncertain.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText('uncertain plan')],
        operationId: 'plan-uncertain',
      ),
      throwsA(failure(502, 'upstream_unavailable')),
    );
    final int attemptsAfterFailure = api.attempts;
    expect(attemptsAfterFailure, greaterThan(0));
    final ChatOperationRecord? stored = await uncertain.ledger.operation(
      _alice,
      'plan-uncertain',
    );
    expect(stored!.state, 'uncertain');
    expect(stored.expectedIdentity, isNotNull);

    session.establish(token: backend.tokenFor(_bob), user: user(_bob));
    session.establish(token: backend.tokenFor(_alice), user: user(_alice));

    await expectLater(
      uncertain.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText('uncertain plan')],
        operationId: 'plan-uncertain',
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    expect(
      api.attempts,
      attemptsAfterFailure,
      reason: 'a stale plan is reconciled, never resent',
    );
    expect(backend.sendRequests, 0);
  });

  test(
    'recovering a succeeded plan queries the original operation and resends 0',
    () async {
      const String text = 'recover me';
      const String operationId = 'recover-succeeded';
      await service.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText(text)],
        operationId: operationId,
      );
      expect(backend.sendRequests, 1);
      final ChatOperationRecord stored = (await service.ledger.operation(
        _alice,
        operationId,
      ))!;
      expect(stored.state, 'succeeded');

      // Simulate a crash after the remote commit but before the local success
      // fact was written: the plan is still `prepared` with its original
      // identity.
      await service.ledger.saveOperation(
        _alice,
        ChatOperationRecord(
          operationId: stored.operationId,
          kind: stored.kind,
          targetAccount: stored.targetAccount,
          state: 'prepared',
          sourceDigest: stored.sourceDigest,
          parts: stored.parts,
          resolvedMediaIds: stored.resolvedMediaIds,
          attempts: stored.attempts,
          expectedIdentity: stored.expectedIdentity,
        ),
      );

      session.establish(token: backend.tokenFor(_alice), user: user(_alice));
      final SendOutcome recovered = await service.sendBody(
        targetAccount: _bob,
        content: const <OutgoingPart>[OutgoingText(text)],
        operationId: operationId,
      );
      expect(recovered.succeeded, isTrue);
      expect(recovered.operationId, operationId);
      expect(
        backend.sendRequests,
        1,
        reason: 'recovery must query the server, not resend',
      );
      final ChatOperationRecord after = (await service.ledger.operation(
        _alice,
        operationId,
      ))!;
      expect(after.state, 'succeeded');
    },
  );

  test('ACK validates the expected identity before its scope check', () async {
    await backend.seedMessage(sender: _bob, target: _alice, text: 'm1');
    final ExpectedIdentity identity = await service.identityFor('dsh-x');
    final VisibleMessagePage page = await service.readMessages(
      peerAccount: _bob,
      consumerSession: 'dsh-x',
    );
    await service.confirmPresentation(
      consumerSession: 'dsh-x',
      attemptId: 'attempt-1',
      requestDigest: 'digest-1',
      receiptIds: <String>[page.items.single.presentation!.receiptId],
    );
    expect(
      await service.ackMessages(
        peerAccount: _bob,
        consumerSession: 'dsh-x',
        throughPosition: 1,
        expectedIdentity: identity,
      ),
      1,
    );

    session.establish(token: backend.tokenFor(_alice), user: user(_alice));
    await expectLater(
      service.ackMessages(
        peerAccount: _bob,
        consumerSession: 'dsh-x',
        throughPosition: 2,
        expectedIdentity: identity,
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    // The stale alias cannot continue without an explicit rebind either.
    await expectLater(
      service.ackMessages(
        peerAccount: _bob,
        consumerSession: 'dsh-x',
        throughPosition: 1,
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    final ConsumerBinding old = (await service.ledger.bindingById(
      identity.consumerId,
    ))!;
    await service.ledger.bindConsumer(
      account: _alice,
      authGeneration: session.identity!.authGeneration,
      consumerSession: 'dsh-x',
      expectedBindingRevision: old.bindingRevision,
    );
    expect(
      await service.ackMessages(
        peerAccount: _bob,
        consumerSession: 'dsh-x',
        throughPosition: 1,
      ),
      1,
    );
  });

  test('binding revision comparison rejects a competing takeover', () async {
    final ChatLedger ledger = ChatLedger.atPath('${root.path}/binding.json');
    final ConsumerBinding first = await ledger.bindConsumer(
      account: _alice,
      authGeneration: 'g-first',
      consumerSession: 's1',
    );
    expect(first.bindingRevision, 1);

    final ConsumerBinding same = await ledger.bindConsumer(
      account: _alice,
      authGeneration: 'g-first',
      consumerSession: 's1',
    );
    expect(same.bindingRevision, 1);
    expect(same.consumerId, first.consumerId);

    // A plain legacy bind after re-login is stale, not an implicit rebind.
    await expectLater(
      ledger.bindConsumer(
        account: _alice,
        authGeneration: 'g-second',
        consumerSession: 's1',
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    final ConsumerBinding relogin = await ledger.bindConsumer(
      account: _alice,
      authGeneration: 'g-second',
      consumerSession: 's1',
      expectedBindingRevision: first.bindingRevision,
    );
    expect(relogin.bindingRevision, 2);
    expect(relogin.consumerId, first.consumerId);

    // A new host session claiming the consumer id needs the current revision.
    await expectLater(
      ledger.bindConsumer(
        account: _alice,
        authGeneration: 'g-third',
        consumerSession: 's2',
        consumerId: first.consumerId,
      ),
      throwsA(failure(409, staleBindingCode)),
    );
    await expectLater(
      ledger.bindConsumer(
        account: _alice,
        authGeneration: 'g-third',
        consumerSession: 's2',
        consumerId: first.consumerId,
        expectedBindingRevision: 1,
      ),
      throwsA(failure(409, staleBindingCode)),
    );
    final ConsumerBinding adopted = await ledger.bindConsumer(
      account: _alice,
      authGeneration: 'g-third',
      consumerSession: 's2',
      consumerId: first.consumerId,
      expectedBindingRevision: 2,
    );
    expect(adopted.consumerId, first.consumerId);
    expect(adopted.bindingRevision, 3);
    expect(adopted.aliases, containsAll(<String>['s1', 's2']));

    // Another account can never adopt this consumer.
    await expectLater(
      ledger.bindConsumer(
        account: _bob,
        authGeneration: 'g-fourth',
        consumerSession: 's3',
        consumerId: first.consumerId,
        expectedBindingRevision: 3,
      ),
      throwsA(failure(409, staleBindingCode)),
    );
  });

  test('auth generation is opaque and never repeats', () {
    final AuthSession auth = AuthSession();
    final Set<String> generations = <String>{};
    for (int i = 0; i < 5; i++) {
      auth.establish(
        token: 'tok-$i',
        user: const AuthUser(account: _alice, username: 'alice'),
      );
      final String generation = auth.identity!.authGeneration;
      expect(generation, isNotEmpty);
      expect(generation, isNot('${auth.generation}'));
      generations.add(generation);
    }
    expect(generations, hasLength(5));
    final AuthIdentity captured = auth.identity!;
    auth.clear();
    expect(auth.identity, isNull);
    auth.establish(
      token: 'tok-again',
      user: const AuthUser(account: _alice, username: 'alice'),
    );
    expect(auth.identity!.sameAs(captured), isFalse);
  });
}
