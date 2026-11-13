import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

const account = '10000001';
const peer = '10000002';
const operation = ChatOperationRecord(
  operationId: 'op',
  kind: 'body',
  targetAccount: peer,
  state: 'prepared',
  sourceDigest: 'digest',
  parts: [],
);
const task = DownloadTask(
  taskId: 'task',
  operationId: 'download-op',
  consumerSession: 'session',
  status: DownloadStatus.pending,
  plannedPath: 'synthetic-file',
);
const event = LocalEvent(
  eventId: 'event',
  account: account,
  consumerSession: 'session',
  type: LocalEventType.downloadSucceeded,
  taskId: 'task',
);

void main() {
  late Directory root;
  late String path;
  late ChatLedger ledger;
  late ConsumerBinding binding;
  late PresentationReceipt confirmed;
  late PresentationReceipt unconfirmed;
  ConsumerBinding? createdBinding;
  Future<void> Function()? beforeReplace;
  final createdReceipts = <String>{};

  Future<void> breakFile() async {
    await File(path).rename('$path.saved');
    await Directory(path).create();
  }

  Future<void> restoreFile() async {
    await Directory(path).delete();
    await File('$path.saved').rename(path);
  }

  Future<ConsumerBinding> enroll(
    ChatLedger target,
    String owner, {
    String session = 'new-session',
  }) => target.enrollConsumer(
    account: account,
    authGeneration: 'generation',
    ownerKeyHash: owner,
    sessionId: session,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-ledger-commit-');
    path = '${root.path}/ledger.json';
    beforeReplace = null;
    createdBinding = null;
    createdReceipts.clear();
    ledger = ChatLedger.atPath(
      path,
      beforeReplace: () async {
        await beforeReplace?.call();
      },
    );
    binding = await enroll(ledger, 'existing-owner', session: 'session');
    confirmed = await ledger.prepareReceipt(
      account: account,
      consumerSession: 'session',
      consumerId: binding.consumerId,
      peerAccount: peer,
      messageId: 'confirmed',
      position: 1,
      contentDigest: 'one',
    );
    unconfirmed = await ledger.prepareReceipt(
      account: account,
      consumerSession: 'session',
      consumerId: binding.consumerId,
      peerAccount: peer,
      messageId: 'unconfirmed',
      position: 2,
      contentDigest: 'two',
    );
    await ledger.confirmReceipts(
      account: account,
      receiptIds: [confirmed.receiptId],
    );
    await ledger.saveOperation(account, operation);
    await ledger.saveDownload(account, task);
    await ledger.subscribe(account, 'session', peer);
    // Pending event fixture; no feed delivery yet.
    await ledger.finishDownload(account: account, task: task, event: event);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Object? bindingView(ConsumerBinding? value) => value == null
      ? null
      : {
          'identity': value.identity.toJson(),
          'session': value.sessionId,
          'aliases': value.aliases.toList()..sort(),
        };

  Future<Map<String, dynamic>> view(ChatLedger target) async => {
    'binding': bindingView(await target.bindingById(binding.consumerId)),
    'newBinding': createdBinding == null
        ? null
        : bindingView(await target.bindingById(createdBinding!.consumerId)),
    'serverCursor': await target.serverEventCursor(account),
    'consumerCursor': await target.consumerEventCursor(account, 'session'),
    'subscriptions': await target.subscriptions(account),
    'operation': (await target.operation(account, 'op'))?.toJson(),
    'download': (await target.download(account, 'task'))?.toJson(),
    'downloadOperation': await target.downloadTaskForOperation(
      account,
      'download-op',
    ),
    'consumed': await target.consumedThrough(
      account,
      peer,
      consumerId: binding.consumerId,
    ),
    'receipts': (await target.receiptsForPeer(
      account: account,
      consumerSession: 'session',
      peerAccount: peer,
      consumerId: binding.consumerId,
    )).map((r) => r.toJson()).toList(),
    'confirmation': await target.confirmation(
      account,
      'new-attempt',
      consumerId: binding.consumerId,
    ),
    'events': (await target.readLocalEvents(
      account: account,
      consumerSession: 'session',
      afterCursor: 0,
    )).items.map((e) => e.toJson()).toList(),
    'head': await target.localEventHead(account, 'session'),
  };

  Future<void> write(String entry) async {
    switch (entry) {
      case 'setServerEventCursor':
        await ledger.setServerEventCursor(account, 5);
      case 'setConsumerEventCursor':
        await ledger.setConsumerEventCursor(account, 'session', 5);
      case 'subscribe':
        await ledger.subscribe(account, 'another-session', peer);
      case 'saveOperation':
        await ledger.saveOperation(
          account,
          operation.copyWith(state: 'uncertain'),
        );
      case 'saveDownload':
        await ledger.saveDownload(
          account,
          task.copyWith(status: DownloadStatus.uncertain),
        );
      case 'saveDownloadOperation':
        await ledger.saveDownloadOperation(account, 'download-op', 'task');
      case 'enrollConsumer':
        createdBinding = await enroll(ledger, 'new-owner');
      case 'bindConsumerOwner':
        await ledger.bindConsumerOwner(
          account: account,
          authGeneration: 'new-generation',
          ownerKeyHash: 'existing-owner',
          consumerId: binding.consumerId,
          expectedBindingRevision: 1,
          sessionId: 'new-session',
        );
      case 'bindConsumer-create':
        createdBinding = await ledger.bindConsumer(
          account: account,
          authGeneration: 'new-generation',
          consumerSession: 'new-session',
        );
      case 'bindConsumer-update':
        await ledger.bindConsumer(
          account: account,
          authGeneration: 'new-generation',
          consumerSession: 'session',
          expectedBindingRevision: 1,
        );
      case 'setConsumedThrough':
        await ledger.setConsumedThrough(
          account,
          peer,
          1,
          consumerId: binding.consumerId,
        );
      case 'commitAck':
        await ledger.commitAck(
          account: account,
          consumerSession: 'session',
          consumerId: binding.consumerId,
          peerAccount: peer,
          throughPosition: 1,
          expectedIdentity: binding.identity,
          stillCurrent: () => true,
        );
      case 'prepareReceipt':
        await ledger.prepareReceipt(
          account: account,
          consumerSession: 'session',
          consumerId: binding.consumerId,
          peerAccount: peer,
          messageId: 'new-message',
          position: 3,
          contentDigest: 'three',
          createdReceiptIds: createdReceipts,
        );
      case 'discardUnconfirmedReceipts':
        await ledger.discardUnconfirmedReceipts(account, [
          unconfirmed.receiptId,
        ]);
      case 'confirmPresentationAttempt':
        await ledger.confirmPresentationAttempt(
          account: account,
          consumerSession: 'session',
          consumerId: binding.consumerId,
          attemptId: 'new-attempt',
          requestDigest: 'request',
          receiptIds: [unconfirmed.receiptId],
          expectedIdentity: binding.identity,
          stillCurrent: () => true,
        );
      case 'confirmReceipts':
        await ledger.confirmReceipts(
          account: account,
          receiptIds: [unconfirmed.receiptId],
        );
      case 'recordConfirmation':
        await ledger.recordConfirmation(
          account: account,
          consumerSession: 'session',
          attemptId: 'new-attempt',
          requestDigest: 'request',
          receiptIds: [confirmed.receiptId],
        );
      case 'finishDownload':
        await ledger.finishDownload(
          account: account,
          task: task.copyWith(status: DownloadStatus.succeeded),
          event: event,
        );
      case 'deliverPendingEvents':
        await ledger.deliverPendingEvents(account);
      case 'appendLocalEvent':
        await ledger.appendLocalEvent(
          account: account,
          consumerSession: 'session',
          event: event,
        );
      default:
        throw StateError(entry);
    }
  }

  for (final entry in [
    'setServerEventCursor',
    'setConsumerEventCursor',
    'subscribe',
    'saveOperation',
    'saveDownload',
    'saveDownloadOperation',
    'enrollConsumer',
    'bindConsumerOwner',
    'bindConsumer-create',
    'bindConsumer-update',
    'setConsumedThrough',
    'commitAck',
    'prepareReceipt',
    'discardUnconfirmedReceipts',
    'confirmPresentationAttempt',
    'confirmReceipts',
    'recordConfirmation',
    'finishDownload',
    'deliverPendingEvents',
    'appendLocalEvent',
  ]) {
    test('$entry: repeated failure, retry and cold reopen agree', () async {
      final before = await view(ledger);
      final durableBefore = await File(path).readAsString();
      await breakFile();
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(write(entry), throwsA(isA<FileSystemException>()));
        expect(
          await view(ledger),
          before,
          reason: 'no uncommitted in-memory facts',
        );
        expect(
          createdReceipts,
          isEmpty,
          reason: 'no external receipt publication',
        );
        expect(await File('$path.saved').readAsString(), durableBefore);
        expect(root.listSync().where((f) => f.path.contains('.tmp-')), isEmpty);
      }
      await restoreFile();
      await write(entry);
      final after = await view(ledger);
      expect(
        after,
        isNot(equals(before)),
        reason: 'retry must perform the mutation',
      );
      final cold = ChatLedger.atPath(path);
      expect(await view(cold), after, reason: 'success must survive reopen');
      expect(
        await cold.consumedThrough(account, peer, consumerId: 'other-consumer'),
        0,
      );
      expect(await cold.operation('10000009', 'op'), isNull);
      if (entry == 'appendLocalEvent' || entry == 'deliverPendingEvents') {
        await write(entry);
        expect(await view(ledger), after, reason: 'delivery is idempotent');
      }
      if (entry == 'enrollConsumer') {
        final again = await enroll(cold, 'new-owner');
        expect(again.consumerId, createdBinding!.consumerId);
      }
    });
  }

  test(
    'ready failure retains durable pending and cold retry finishes it',
    () async {
      var commits = 0;
      beforeReplace = () async {
        if (++commits == 2) {
          await breakFile(); // pending succeeded, ready cannot rename.
        }
      };
      await expectLater(
        enroll(ledger, 'pending-owner'),
        throwsA(isA<FileSystemException>()),
      );
      beforeReplace = null;
      final pendingText = await File('$path.saved').readAsString();
      final pending = jsonDecode(pendingText) as Map<String, dynamic>;
      expect(pending['consumer_owners']['pending-owner']['status'], 'pending');
      expect(
        pending['consumer_owners']['pending-owner']['consumer_id'],
        isNull,
      );
      expect((pending['consumers'] as Map).length, 1);
      // Still broken: another call must attempt ready persistence, never return ready.
      await expectLater(
        enroll(ledger, 'pending-owner'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('$path.saved').readAsString(), pendingText);
      await restoreFile();
      final cold = ChatLedger.atPath(path);
      await expectLater(
        cold.enrollConsumer(
          account: '10000009',
          authGeneration: 'g',
          ownerKeyHash: 'pending-owner',
          sessionId: 'other',
        ),
        throwsA(isA<AuthFailure>()),
      );
      final ready = await enroll(cold, 'pending-owner');
      final restart = ChatLedger.atPath(path);
      expect(
        (await restart.bindingById(ready.consumerId))?.identity.toJson(),
        ready.identity.toJson(),
      );
      expect(
        (await enroll(restart, 'pending-owner')).consumerId,
        ready.consumerId,
      );
      expect(
        (await restart.bindingById(binding.consumerId))?.identity.toJson(),
        binding.identity.toJson(),
      );
    },
  );

  test(
    'readers wait for pending/ready commit and cannot see failed ready',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var commits = 0;
      String? proposedId;
      beforeReplace = () async {
        if (++commits != 2) return;
        final stagedFile = root.listSync().whereType<File>().singleWhere(
          (f) => f.path.contains('.tmp-'),
        );
        final staged = jsonDecode(await stagedFile.readAsString());
        proposedId =
            staged['consumer_owners']['paused-owner']['consumer_id'] as String;
        entered.complete();
        await release.future;
        await breakFile();
      };
      final failed = expectLater(
        enroll(ledger, 'paused-owner'),
        throwsA(isA<FileSystemException>()),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      expect(
        await ChatLedger.atPath(path).bindingById(proposedId!),
        isNull,
        reason: 'a fresh reader sees pending only before ready commits',
      );
      var readFinished = false;
      final read = ledger.bindingById(proposedId!).then((value) {
        readFinished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(readFinished, isFalse);
      release.complete();
      await failed;
      expect(await read, isNull);
      beforeReplace = null;
      await restoreFile();
      final ready = await enroll(ledger, 'paused-owner');
      expect(
        (await ChatLedger.atPath(path).bindingById(ready.consumerId))
            ?.consumerId,
        ready.consumerId,
      );
    },
  );

  test('validation error rolls back implicit consumer creation', () async {
    final bytes = await File(path).readAsString();
    await expectLater(
      ledger.confirmPresentationAttempt(
        account: account,
        consumerSession: 'not-created',
        attemptId: 'invalid',
        requestDigest: 'x',
        receiptIds: ['missing'],
      ),
      throwsA(isA<AuthFailure>()),
    );
    await expectLater(
      ledger.bindConsumer(
        account: account,
        authGeneration: 'g',
        consumerSession: 'not-created',
        requireExisting: true,
      ),
      throwsA(isA<AuthFailure>()),
    );
    expect(await File(path).readAsString(), bytes);
  });

  test('failed initial load remains retryable', () async {
    final cold = ChatLedger.atPath(path);
    await breakFile();
    await expectLater(
      cold.bindingById(binding.consumerId),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      cold.bindingById(binding.consumerId),
      throwsA(isA<FileSystemException>()),
    );
    await restoreFile();
    expect(
      (await cold.bindingById(binding.consumerId))?.consumerId,
      binding.consumerId,
    );
  });
}
