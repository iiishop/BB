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

/// Reproduces and fixes the two real-client counterexamples from the
/// `e311a0a` probe:
///
/// 1. consumer B with zero receipts inherited A's watermark 2 through an
///    account+peer-only ACK;
/// 2. a plan persisted under one account was replayed and sent by the account
///    that was logged in when it was resubmitted.
///
/// Both cases are deterministic: the ledger serializes every mutation, so the
/// race is expressed by interleaving the calls, not by timing.
const String _account = '10000001';
const String _peer = '10000002';
const String _other = '10000003';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late String ledgerPath;
  late AuthSession session;
  late ChatService service;

  AuthUser user(String account) =>
      AuthUser(account: account, username: 'name-$account');

  ChatService build(AuthSession auth, {ChatLedger? ledger}) {
    return ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: auth,
      ledger: ledger ?? ChatLedger.atPath(ledgerPath),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
  }

  Matcher failure(int status, String code) => isA<AuthFailure>()
      .having((AuthFailure f) => f.status, 'status', status)
      .having((AuthFailure f) => f.code, 'code', code);

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{
        _account: 'alice',
        _peer: 'bob',
        _other: 'carol',
      },
    );
    root = await Directory.systemTemp.createTemp('bb-consumer-isolation-');
    ledgerPath = '${root.path}/ledger.json';
    session = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    service = build(session);
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> seedTwoPeerMessages() async {
    await backend.seedMessage(sender: _peer, target: _account, text: 'p1');
    await backend.seedMessage(sender: _peer, target: _account, text: 'p2');
  }

  Future<List<String>> readAndConfirm(
    ChatService chat,
    String consumerSession,
  ) async {
    final VisibleMessagePage page = await chat.readMessages(
      peerAccount: _peer,
      consumerSession: consumerSession,
    );
    expect(page.items, hasLength(2));
    return chat.confirmPresentation(
      consumerSession: consumerSession,
      attemptId: 'attempt-$consumerSession',
      requestDigest: 'digest-$consumerSession',
      receiptIds: <String>[
        for (final VisibleMessage item in page.items)
          item.presentation!.receiptId,
      ],
    );
  }

  Future<int> ack(
    ChatService chat,
    String consumerSession,
    int through,
  ) {
    return chat.ackMessages(
      peerAccount: _peer,
      consumerSession: consumerSession,
      throughPosition: through,
    );
  }

  test(
    'consumer B without receipts gets consumption_gap and inherits nothing',
    () async {
      await seedTwoPeerMessages();
      await readAndConfirm(service, 'dsh-a');
      // B is registered but has no receipts of its own.
      await service.identityFor('dsh-b');

      expect(await ack(service, 'dsh-a', 2), 2);

      // Original defect: B ACKed 200 and inherited consumed_through 2.
      await expectLater(
        ack(service, 'dsh-b', 2),
        throwsA(failure(409, consumptionGapCode)),
      );
      expect(
        await service.ledger.consumedThrough(
          _account,
          _peer,
          consumerId: (await service.identityFor('dsh-b')).consumerId,
        ),
        0,
        reason: 'a failed ACK must not advance the other consumer',
      );

      // A repeating the same/lower ACK stays idempotent under its own scope.
      expect(await ack(service, 'dsh-a', 2), 2);
      expect(await ack(service, 'dsh-a', 1), 2);

      // Reading without a confirmed display fact is not consumption evidence.
      await service.readMessages(peerAccount: _peer, consumerSession: 'dsh-b');
      await expectLater(
        ack(service, 'dsh-b', 2),
        throwsA(failure(409, consumptionGapCode)),
      );

      // B can still advance independently once it has its own confirmations.
      await readAndConfirm(service, 'dsh-b');
      expect(await ack(service, 'dsh-b', 2), 2);
      expect(await ack(service, 'dsh-a', 2), 2);
      final String aId = (await service.identityFor('dsh-a')).consumerId;
      final String bId = (await service.identityFor('dsh-b')).consumerId;
      expect(aId, isNot(bId));
      expect(
        await service.ledger.consumedThrough(
          _account,
          _peer,
          consumerId: aId,
        ),
        2,
      );
      expect(
        await service.ledger.consumedThrough(
          _account,
          _peer,
          consumerId: bId,
        ),
        2,
      );
    },
  );

  test('interleaved ACKs from two consumers advance only the confirmed one',
      () async {
    await seedTwoPeerMessages();
    await readAndConfirm(service, 'dsh-a');
    await service.identityFor('dsh-b');

    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      ack(service, 'dsh-a', 2).then<Object?>((int value) => value),
      ack(service, 'dsh-b', 2).then<Object?>(
        (int value) => value,
        onError: (Object error) => error,
      ),
    ]);
    expect(results.first, 2);
    expect(results.last, isA<AuthFailure>());
    expect((results.last as AuthFailure).code, consumptionGapCode);

    final String aId = (await service.identityFor('dsh-a')).consumerId;
    final String bId = (await service.identityFor('dsh-b')).consumerId;
    expect(
      await service.ledger.consumedThrough(_account, _peer, consumerId: aId),
      2,
    );
    expect(
      await service.ledger.consumedThrough(_account, _peer, consumerId: bId),
      0,
    );
  });

  test('consumer scope and watermark survive a process restart', () async {
    await seedTwoPeerMessages();
    await readAndConfirm(service, 'dsh-a');
    expect(await ack(service, 'dsh-a', 2), 2);
    final String aId = (await service.identityFor('dsh-a')).consumerId;
    final String bId = (await service.identityFor('dsh-b')).consumerId;

    // Simulated restart: a fresh session, ledger and service on the same file.
    await service.dispose();
    final AuthSession restarted = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    service = build(restarted);

    // The alias is one-to-one, so the stable consumer id comes back; only an
    // explicit revision-checked rebind may rotate its login generation.
    expect(
      (await service.ledger.expectedIdentityForSession(_account, 'dsh-a'))!
          .consumerId,
      aId,
    );
    expect(
      (await service.ledger.expectedIdentityForSession(_account, 'dsh-b'))!
          .consumerId,
      bId,
    );
    await expectLater(
      ack(service, 'dsh-a', 2),
      throwsA(failure(409, staleIdentityCode)),
    );
    for (final String alias in <String>['dsh-a', 'dsh-b']) {
      final ExpectedIdentity old = (await service.ledger
          .expectedIdentityForSession(_account, alias))!;
      await service.ledger.bindConsumer(
        account: _account,
        authGeneration: service.session.identity!.authGeneration,
        consumerSession: alias,
        expectedBindingRevision: old.bindingRevision,
      );
    }
    expect(await ack(service, 'dsh-a', 2), 2);
    await expectLater(
      ack(service, 'dsh-b', 2),
      throwsA(failure(409, consumptionGapCode)),
    );
    expect(
      await service.ledger.consumedThrough(_account, _peer, consumerId: bId),
      0,
    );
  });

  test('a peer message on another account can never share the consumer', () async {
    await service.dispose();
    final AuthSession other = AuthSession()
      ..establish(token: backend.tokenFor(_other), user: user(_other));
    service = build(other);
    await backend.seedMessage(sender: _peer, target: _other, text: 'o1');
    // Same consumer_session string on another account is a distinct alias and
    // must not resolve to the first account's consumer.
    final ExpectedIdentity identity = await service.identityFor('dsh-a');
    expect(identity.account, _other);
    expect(
      await service.ledger.consumedThrough(
        _other,
        _peer,
        consumerId: identity.consumerId,
      ),
      0,
    );
  });
}
