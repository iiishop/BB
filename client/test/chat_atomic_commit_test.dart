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

/// Controlled-pause tests for the identity-check → durable-write window.
const String _account = '10000001';
const String _peer = '10000002';
const String _other = '10000009';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService service;
  Future<void> Function()? onBeforeCommit;

  AuthUser user(String account) => AuthUser(
    account: account,
    username: account == _account ? 'alice' : 'bob',
  );

  Matcher failure(int status, String code) => isA<AuthFailure>()
      .having((AuthFailure f) => f.status, 'status', status)
      .having((AuthFailure f) => f.code, 'code', code);

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_account: 'alice', _peer: 'bob'},
    );
    root = await Directory.systemTemp.createTemp('bb-atomic-commit-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    onBeforeCommit = null;
    service = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
      beforeCommit: () async {
        final Future<void> Function()? hook = onBeforeCommit;
        if (hook != null) {
          await hook();
        }
      },
    );
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> seedAndConfirm() async {
    await backend.seedMessage(sender: _peer, target: _account, text: 'm1');
    await backend.seedMessage(sender: _peer, target: _account, text: 'm2');
    final VisibleMessagePage page = await service.readMessages(
      peerAccount: _peer,
      consumerSession: 'dsh-a',
    );
    await service.confirmPresentation(
      consumerSession: 'dsh-a',
      attemptId: 'attempt-a',
      requestDigest: 'digest-a',
      receiptIds: <String>[
        for (final VisibleMessage item in page.items)
          item.presentation!.receiptId,
      ],
    );
  }

  test('ACK switched at the commit pause writes no watermark', () async {
    await seedAndConfirm();
    final String consumerId = (await service.identityFor('dsh-a')).consumerId;

    onBeforeCommit = () async {
      session.establish(token: backend.tokenFor(_other), user: user(_other));
    };
    await expectLater(
      service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'dsh-a',
        throughPosition: 2,
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    expect(
      await service.ledger.consumedThrough(
        _account,
        _peer,
        consumerId: consumerId,
      ),
      0,
      reason: 'the watermark must not be written after the identity changed',
    );
  });

  test('ACK same-account re-login at the pause also writes nothing', () async {
    await seedAndConfirm();
    final String consumerId = (await service.identityFor('dsh-a')).consumerId;

    onBeforeCommit = () async {
      session.establish(token: backend.tokenFor(_account), user: user(_account));
    };
    await expectLater(
      service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'dsh-a',
        throughPosition: 2,
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    expect(
      await service.ledger.consumedThrough(
        _account,
        _peer,
        consumerId: consumerId,
      ),
      0,
    );
  });

  test('ACK without a pause commits and stays idempotent', () async {
    await seedAndConfirm();
    expect(
      await service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'dsh-a',
        throughPosition: 2,
      ),
      2,
    );
    expect(
      await service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'dsh-a',
        throughPosition: 2,
      ),
      2,
    );
  });

  test('confirm switched at the pause writes no confirmation', () async {
    await backend.seedMessage(sender: _peer, target: _account, text: 'only');
    final VisibleMessagePage page = await service.readMessages(
      peerAccount: _peer,
      consumerSession: 'dsh-b',
    );
    final String receiptId = page.items.single.presentation!.receiptId;

    onBeforeCommit = () async {
      session.establish(token: backend.tokenFor(_other), user: user(_other));
    };
    await expectLater(
      service.confirmPresentation(
        consumerSession: 'dsh-b',
        attemptId: 'attempt-switch',
        requestDigest: 'digest-switch',
        receiptIds: <String>[receiptId],
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    expect(
      (await service.ledger.receipt(_account, receiptId))!.confirmed,
      isFalse,
    );
    expect(
      await service.ledger.confirmation(_account, 'attempt-switch'),
      isNull,
    );
  });

  test('an already committed fact is preserved for the original account',
      () async {
    await seedAndConfirm();
    expect(
      await service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'dsh-a',
        throughPosition: 2,
      ),
      2,
    );
    final String consumerId = (await service.identityFor('dsh-a')).consumerId;

    session.establish(token: backend.tokenFor(_other), user: user(_other));
    await expectLater(
      service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'dsh-a',
        throughPosition: 2,
      ),
      throwsA(failure(409, staleIdentityCode)),
    );
    expect(
      await service.ledger.consumedThrough(
        _account,
        _peer,
        consumerId: consumerId,
      ),
      2,
      reason: 'the original account keeps the fact it already committed',
    );
    expect(
      await service.ledger.consumedThrough(
        _other,
        _peer,
        consumerId: (await service.identityFor('human:$_other')).consumerId,
      ),
      0,
    );
  });
}
