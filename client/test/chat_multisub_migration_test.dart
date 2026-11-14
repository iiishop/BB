import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const account = '10000001';
  const peer = '10000002';
  late Directory root;
  late File file;
  late Map<String, dynamic> old;
  late String original;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-multisub-migrate-');
    file = File('${root.path}/ledger.json');
    final ledger = ChatLedger.atPath(file.path);
    final binding = await ledger.enrollConsumer(
      account: account,
      authGeneration: 'generation',
      ownerKeyHash: 'synthetic-owner',
      sessionId: 'session',
    );
    await ledger.subscribe(account, binding.consumerId, peer);
    final receipt = await ledger.prepareReceipt(
      account: account,
      consumerSession: 'session',
      consumerId: binding.consumerId,
      peerAccount: peer,
      messageId: 'message',
      position: 1,
      contentDigest: 'digest',
    );
    await ledger.confirmPresentationAttempt(
      account: account,
      consumerSession: 'session',
      consumerId: binding.consumerId,
      attemptId: 'attempt',
      requestDigest: 'digest',
      receiptIds: [receipt.receiptId],
    );
    await ledger.setConsumedThrough(
      account,
      peer,
      1,
      consumerId: binding.consumerId,
    );
    await ledger.saveOperation(
      account,
      const ChatOperationRecord(
        operationId: 'send',
        kind: 'body',
        targetAccount: peer,
        state: 'uncertain',
        sourceDigest: 'digest',
        parts: [],
      ),
    );
    await ledger.saveDownload(
      account,
      const DownloadTask(
        taskId: 'download',
        operationId: 'download-op',
        consumerSession: 'session',
        status: DownloadStatus.pending,
        plannedPath: 'synthetic-file',
      ),
    );
    await ledger.appendLocalEvent(
      account: account,
      consumerSession: binding.consumerId,
      event: LocalEvent(
        eventId: 'server:7',
        account: account,
        consumerSession: binding.consumerId,
        type: LocalEventType.messageAvailable,
        peerAccount: peer,
        messageId: 'message',
        position: 1,
        originIdentity: binding.identity.toJson(),
      ),
    );
    await ledger.setConsumerEventCursor(account, binding.consumerId, 12);
    old = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    old['version'] = 2;
    old['accounts'][account]['subscriptions'][binding.consumerId] =
        <String, dynamic>{'peer_account': peer, 'created_at': 'synthetic-time'};
    original = jsonEncode(old);
    await file.writeAsString(original, flush: true);
  });

  tearDown(() => root.delete(recursive: true));

  test(
    'v2 migrates once without losing receipts, operations, downloads or dedup',
    () async {
      final ledger = ChatLedger.atPath(file.path);
      final subscriptions = await ledger.subscriptions(account);
      final consumer = subscriptions.keys.single;
      expect(subscriptions[consumer], [peer]);
      expect(await ledger.subscriptionCursor(account, consumer, peer), 12);
      expect(await ledger.discoversConversations(account, consumer), false);
      expect(await File('${file.path}.v2.bak').readAsString(), original);
      final migrated =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(migrated['version'], 3);
      for (final key in ['consumers', 'consumer_owners']) {
        expect(migrated[key], old[key]);
      }
      for (final key
          in (old['accounts'][account] as Map<String, dynamic>).keys.where(
            (key) => key != 'subscriptions',
          )) {
        expect(
          migrated['accounts'][account][key],
          old['accounts'][account][key],
          reason: key,
        );
      }
      await ledger.subscribe(account, consumer, '10000003');
      expect(await ledger.subscriptionCursor(account, consumer, '10000003'), 0);
      final bytes = await file.readAsString();
      final reopened = ChatLedger.atPath(file.path);
      expect((await reopened.subscriptions(account))[consumer], [
        peer,
        '10000003',
      ]);
      expect(await reopened.displayedMessageIds(account), {'message'});
      expect(await file.readAsString(), bytes);
      expect(
        await reopened.hasDeliveredEvent(
          account: account,
          consumerSession: consumer,
          eventId: 'server:7',
        ),
        true,
      );
    },
  );

  test(
    'failed migration preserves old bytes, retries and cold opens',
    () async {
      bool fail = true;
      final ledger = ChatLedger.atPath(
        file.path,
        beforeReplace: () async {
          if (fail)
            throw const FileSystemException('injected replacement failure');
        },
      );
      await expectLater(
        ledger.subscriptions(account),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), original);
      expect(await File('${file.path}.v2.bak').readAsString(), original);
      fail = false;
      final migrated = await ledger.subscriptions(account);
      expect(
        await ChatLedger.atPath(file.path).subscriptions(account),
        migrated,
      );
    },
  );

  test('unsupported version is retained and never overwritten', () async {
    old['version'] = 99;
    final bytes = jsonEncode(old);
    await file.writeAsString(bytes);
    final ledger = ChatLedger.atPath(file.path);
    await expectLater(
      ledger.subscribe(account, 'consumer', peer),
      throwsFormatException,
    );
    expect(await file.readAsString(), bytes);
  });
}
