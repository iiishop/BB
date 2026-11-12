import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _accountA = '10000001';
const String _accountB = '10000002';

void main() {
  late Directory root;
  late ChatLedger ledger;
  late AuthSession session;
  late ChatService chat;

  AuthUser user(String account) => AuthUser(
    account: account,
    username: account == _accountA ? 'alice' : 'bob',
  );

  DownloadTask task(
    String id, {
    DownloadStatus status = DownloadStatus.succeeded,
  }) {
    return DownloadTask(
      taskId: id,
      operationId: 'op-$id',
      consumerSession: 'origin-consumer',
      status: status,
      plannedPath: '${root.path}/file-$id.pdf',
      actualPath: status == DownloadStatus.succeeded
          ? '${root.path}/file-$id.pdf'
          : null,
      mediaId: 'media-$id',
      kind: AttachmentKind.document,
      filename: 'file-$id.pdf',
    );
  }

  LocalEvent event(String taskId, {bool succeeded = true}) => LocalEvent(
    eventId: 'download:$taskId:${succeeded ? 'succeeded' : 'failed'}',
    account: _accountA,
    consumerSession: 'origin-consumer',
    type: succeeded
        ? LocalEventType.downloadSucceeded
        : LocalEventType.downloadFailed,
    taskId: taskId,
    operationId: 'op-$taskId',
    actualPath: succeeded ? '${root.path}/file-$taskId.pdf' : null,
    errorCode: succeeded ? null : 'download_failed',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-download-event-');
    ledger = ChatLedger.atPath('${root.path}/ledger.json');
    session = AuthSession()..establish(token: 'token-a', user: user(_accountA));
    chat = ChatService(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: ledger,
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
  });

  tearDown(() async {
    await chat.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'terminal event belongs to origin account, not the current B login',
    () async {
      final DownloadTask done = task('a1');
      final LocalEvent terminal = event('a1');
      await ledger.finishDownload(
        account: _accountA,
        task: done,
        event: terminal,
      );

      session.establish(token: 'token-b', user: user(_accountB));
      expect(
        (await chat.readEvents(
          consumerSession: 'origin-consumer',
          afterCursor: 0,
        )).items,
        isEmpty,
      );

      session.establish(token: 'token-a2', user: user(_accountA));
      final LocalEventPage page = await chat.readEvents(
        consumerSession: 'origin-consumer',
        afterCursor: 0,
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.event.eventId, terminal.eventId);
      expect(page.items.single.event.account, _accountA);
    },
  );

  test(
    'get repairs a saved task whose terminal event was never delivered',
    () async {
      final DownloadTask saved = task('a2');
      await ledger.saveDownload(_accountA, saved);

      session.establish(token: 'token-b', user: user(_accountB));
      expect(
        await chat.downloads.get(
          taskId: saved.taskId,
          consumerSession: 'origin-consumer',
        ),
        isNull,
        reason: 'public get is scoped to the current B account',
      );

      session.establish(token: 'token-a2', user: user(_accountA));
      final DownloadTask? repaired = await chat.downloads.get(
        taskId: saved.taskId,
        consumerSession: 'origin-consumer',
      );
      expect(repaired?.status, DownloadStatus.succeeded);
      final LocalEventPage page = await chat.readEvents(
        consumerSession: 'origin-consumer',
        afterCursor: 0,
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.event.taskId, saved.taskId);
    },
  );

  test('failed terminal event is also durable and origin-scoped', () async {
    final DownloadTask failed = task(
      'a3',
      status: DownloadStatus.failed,
    ).copyWith(errorCode: 'download_failed');
    await ledger.finishDownload(
      account: _accountA,
      task: failed,
      event: event('a3', succeeded: false),
    );
    session.establish(token: 'token-b', user: user(_accountB));
    expect(
      (await chat.readEvents(
        consumerSession: 'origin-consumer',
        afterCursor: 0,
      )).items,
      isEmpty,
    );
    session.establish(token: 'token-a2', user: user(_accountA));
    final LocalEventPage page = await chat.readEvents(
      consumerSession: 'origin-consumer',
      afterCursor: 0,
    );
    expect(page.items, hasLength(1));
    expect(page.items.single.event.type, LocalEventType.downloadFailed);
  });
}
