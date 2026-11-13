import 'dart:io';

import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

const String _account = '10000001';
const String _peer = '10000002';

void main() {
  late Directory root;
  late String path;
  late ChatLedger ledger;
  late ConsumerBinding binding;
  late PresentationReceipt receipt;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-io-rollback-');
    path = '${root.path}/ledger.json';
    ledger = ChatLedger.atPath(path);
    binding = await ledger.enrollConsumer(
      account: _account,
      authGeneration: 'g-one',
      ownerKeyHash: 'owner',
      sessionId: 'session',
    );
    receipt = await ledger.prepareReceipt(
      account: _account,
      consumerId: binding.consumerId,
      consumerSession: 'session',
      peerAccount: _peer,
      messageId: 'm1',
      position: 1,
      contentDigest: 'digest',
    );
    await ledger.confirmPresentationAttempt(
      account: _account,
      consumerSession: 'session',
      consumerId: binding.consumerId,
      attemptId: 'attempt',
      requestDigest: 'req',
      receiptIds: <String>[receipt.receiptId],
      expectedIdentity: binding.identity,
      stillCurrent: () => true,
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  /// Make the ledger path a directory so the next atomic flush fails with a
  /// real filesystem error while keeping the previous file as `.saved`.
  Future<void> breakFlush() async {
    await File(path).rename('$path.saved');
    await Directory(path).create();
  }

  Future<void> restoreFlush() async {
    await Directory(path).delete();
    await File('$path.saved').rename(path);
  }

  test('failed ACK flush does not publish an unpersisted watermark', () async {
    await breakFlush();
    await expectLater(
      ledger.commitAck(
        account: _account,
        consumerSession: 'session',
        consumerId: binding.consumerId,
        peerAccount: _peer,
        throughPosition: 1,
        expectedIdentity: binding.identity,
        stillCurrent: () => true,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await ledger.consumedThrough(_account, _peer, consumerId: binding.consumerId),
      0,
      reason: 'memory must roll back with the failed flush',
    );
    await restoreFlush();
    expect(
      await ledger.commitAck(
        account: _account,
        consumerSession: 'session',
        consumerId: binding.consumerId,
        peerAccount: _peer,
        throughPosition: 1,
        expectedIdentity: binding.identity,
        stillCurrent: () => true,
      ),
      1,
    );
    final ChatLedger cold = ChatLedger.atPath(path);
    expect(
      await cold.consumedThrough(_account, _peer, consumerId: binding.consumerId),
      1,
      reason: 'the committed watermark must survive a cold reopen',
    );
  });

  test('failed bind flush does not publish an unpersisted revision', () async {
    await breakFlush();
    await expectLater(
      ledger.bindConsumerOwner(
        account: _account,
        authGeneration: 'g-two',
        ownerKeyHash: 'owner',
        consumerId: binding.consumerId,
        expectedBindingRevision: 1,
        sessionId: 'session2',
      ),
      throwsA(isA<FileSystemException>()),
    );
    final ConsumerBinding memory =
        (await ledger.bindingById(binding.consumerId))!;
    expect(memory.bindingRevision, 1);
    expect(memory.authGeneration, 'g-one');
    expect(memory.sessionId, 'session');
    await restoreFlush();
    final ConsumerBinding rebound = await ledger.bindConsumerOwner(
      account: _account,
      authGeneration: 'g-two',
      ownerKeyHash: 'owner',
      consumerId: binding.consumerId,
      expectedBindingRevision: 1,
      sessionId: 'session2',
    );
    expect(rebound.bindingRevision, 2);
    final ChatLedger cold = ChatLedger.atPath(path);
    final ConsumerBinding persisted = (await cold.bindingById(
      binding.consumerId,
    ))!;
    expect(persisted.bindingRevision, 2);
    expect(persisted.authGeneration, 'g-two');
    expect(persisted.sessionId, 'session2');
  });
}
