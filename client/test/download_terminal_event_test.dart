import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

const String _accountA = '10000001';
const String _accountB = '10000002';

class _FailFirstFinishLedger implements ChatLedger {
  _FailFirstFinishLedger(this.backing, {this.failures = 1});

  final ChatLedger backing;
  final int failures;
  int attempts = 0;
  bool failed = false;

  @override
  Future<void> saveDownload(String account, DownloadTask task) =>
      backing.saveDownload(account, task);

  @override
  Future<DownloadTask?> download(String account, String taskId) =>
      backing.download(account, taskId);

  @override
  Future<List<DownloadTask>> downloads(String account) =>
      backing.downloads(account);

  @override
  Future<void> saveDownloadOperation(
    String account,
    String operationId,
    String taskId,
  ) => backing.saveDownloadOperation(account, operationId, taskId);

  @override
  Future<String?> downloadTaskForOperation(
    String account,
    String operationId,
  ) => backing.downloadTaskForOperation(account, operationId);

  @override
  Future<int> deliverPendingEvents(String account) =>
      backing.deliverPendingEvents(account);

  @override
  Future<void> finishDownload({
    required String account,
    required DownloadTask task,
    required LocalEvent event,
  }) {
    if (attempts < failures && task.status == DownloadStatus.succeeded) {
      attempts++;
      failed = true;
      throw const FileSystemException('injected permission failure');
    }
    return backing.finishDownload(account: account, task: task, event: event);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used by this test');
}

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

  test(
    'terminal ledger write failure retries success, never failure',
    () async {
      final HttpServer upstream = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      upstream.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'pdf',
        );
        request.response.headers.set(
          'content-disposition',
          'attachment; filename="qa.pdf"',
        );
        request.response.write('%PDF-1.4 saved-before-ledger-fault');
        await request.response.close();
      });
      final String ledgerPath = '${root.path}/fault-ledger.json';
      final _FailFirstFinishLedger fault = _FailFirstFinishLedger(
        ChatLedger.atPath(ledgerPath),
      );
      final DownloadManager manager = DownloadManager(
        api: ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${upstream.port}'),
        ),
        session: session,
        ledger: fault,
        cacheRoot: Directory('${root.path}/fault-cache'),
        onEvent: (LocalEvent event) =>
            fault.deliverPendingEvents(event.account),
      );
      try {
        final DownloadTask task = await manager.start(
          operationId: 'fault-op',
          consumerSession: 'origin-consumer',
          mediaId: 'qa-media',
        );
        await manager.dispose();
        expect(fault.failed, isTrue, reason: 'fault must be injected');
        final ChatLedger restored = ChatLedger.atPath(ledgerPath);
        await restored.deliverPendingEvents(_accountA);
        final DownloadTask? saved = await restored.download(
          _accountA,
          task.taskId,
        );
        expect(saved?.status, DownloadStatus.succeeded);
        final File file = File(saved!.actualPath!);
        expect(
          await file.readAsString(),
          contains('saved-before-ledger-fault'),
        );
        final LocalEventPage events = await restored.readLocalEvents(
          account: _accountA,
          consumerSession: 'origin-consumer',
          afterCursor: 0,
        );
        expect(events.items, hasLength(1));
        expect(
          events.items.single.event.type,
          LocalEventType.downloadSucceeded,
        );
      } finally {
        await manager.dispose();
        await upstream.close(force: true);
      }
    },
  );

  test('three ledger failures recover the original file after restart', () async {
    final HttpServer upstream = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    upstream.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      request.response.headers.set(
        'content-disposition',
        'attachment; filename="qa.pdf"',
      );
      request.response.write('%PDF-1.4 saved-before-ledger-fault');
      await request.response.close();
    });
    final String ledgerPath = '${root.path}/restart-ledger.json';
    final _FailFirstFinishLedger fault = _FailFirstFinishLedger(
      ChatLedger.atPath(ledgerPath),
      failures: 3,
    );
    final Directory cacheRoot = Directory('${root.path}/restart-cache');
    final DownloadManager first = DownloadManager(
      api: ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}'),
      ),
      session: session,
      ledger: fault,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) => fault.deliverPendingEvents(event.account),
    );
    DownloadTask? firstTask;
    try {
      firstTask = await first.start(
        operationId: 'restart-op',
        consumerSession: 'origin-consumer',
        mediaId: 'qa-media',
      );
      await first.dispose();
    } finally {
      await first.dispose();
      await upstream.close(force: true);
    }
    expect(fault.attempts, 3);
    final DownloadTask pending = (await fault.backing.download(
      _accountA,
      firstTask.taskId,
    ))!;
    expect(pending.status, DownloadStatus.pending);
    expect(
      await File(pending.plannedPath).readAsString(),
      contains('saved-before'),
    );

    // A brand-new manager/ledger process-like recovery with the upstream gone.
    final DownloadManager second = DownloadManager(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: fault,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) => fault.deliverPendingEvents(event.account),
    );
    try {
      await second.resumePending();
      await second.dispose();
    } finally {
      await second.dispose();
    }
    final DownloadTask recovered = (await fault.backing.download(
      _accountA,
      firstTask.taskId,
    ))!;
    expect(recovered.status, DownloadStatus.succeeded);
    expect(recovered.actualPath, firstTask.plannedPath);
    expect(File(recovered.actualPath!).existsSync(), isTrue);
    final LocalEventPage page = await fault.backing.readLocalEvents(
      account: _accountA,
      consumerSession: 'origin-consumer',
      afterCursor: 0,
    );
    expect(page.items, hasLength(1));
    expect(page.items.single.event.type, LocalEventType.downloadSucceeded);
  });

  test(
    'prepare write failure blocks placement and recovers from staging',
    () async {
      if (!Platform.isLinux) {
        return; // The permission-fault probe is Unix-only.
      }
      final HttpServer upstream = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      upstream.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'pdf',
        );
        request.response.headers.set(
          'content-disposition',
          'attachment; filename="qa.pdf"',
        );
        request.response.write('%PDF-1.4 staged-before-record');
        await request.response.close();
      });
      final String ledgerPath = '${root.path}/prepare-ledger.json';
      final ChatLedger backing = ChatLedger.atPath(ledgerPath);
      final Directory cacheRoot = Directory('${root.path}/prepare-cache');
      final Directory terminal = Directory('${cacheRoot.path}/.terminal');
      await terminal.create(recursive: true);
      await Process.run('chmod', <String>['500', terminal.path]);
      final DownloadManager first = DownloadManager(
        api: ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${upstream.port}'),
        ),
        session: session,
        ledger: backing,
        cacheRoot: cacheRoot,
        onEvent: (LocalEvent event) =>
            backing.deliverPendingEvents(event.account),
      );
      DownloadTask? task;
      try {
        task = await first.start(
          operationId: 'prepare-fail',
          consumerSession: 'origin-consumer',
          mediaId: 'qa-media',
        );
        await first.dispose();
      } finally {
        await first.dispose();
        await Process.run('chmod', <String>['700', terminal.path]);
        await upstream.close(force: true);
      }
      final DownloadTask pending = (await backing.download(
        _accountA,
        task.taskId,
      ))!;
      expect(pending.status, DownloadStatus.pending);
      expect(await File(pending.plannedPath).length(), 0);
      expect(
        await File('${cacheRoot.path}/.staging/${task.taskId}.part').exists(),
        isTrue,
        reason: 'staging bytes must be preserved when prepare fails',
      );

      // A later user file at the old predictable name has no ownership record
      // and must not be deleted by terminal cleanup.
      final File partial = File('${pending.plannedPath}.part-${task.taskId}');
      await partial.writeAsString('USER OWNED FILE', flush: true);
      final DownloadManager second = DownloadManager(
        api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: session,
        ledger: backing,
        cacheRoot: cacheRoot,
        onEvent: (LocalEvent event) =>
            backing.deliverPendingEvents(event.account),
      );
      try {
        await second.resumePending();
        await second.dispose();
      } finally {
        await second.dispose();
      }
      expect(await partial.exists(), isTrue);
      expect(await partial.readAsString(), 'USER OWNED FILE');
      final DownloadTask recovered = (await backing.download(
        _accountA,
        task.taskId,
      ))!;
      expect(recovered.status, DownloadStatus.succeeded);
      expect(recovered.actualPath, pending.plannedPath);
      expect(
        await File(recovered.actualPath!).readAsString(),
        contains('staged'),
      );
      final LocalEventPage page = await backing.readLocalEvents(
        account: _accountA,
        consumerSession: 'origin-consumer',
        afterCursor: 0,
      );
      expect(page.items, hasLength(1));
      expect(page.items.single.event.type, LocalEventType.downloadSucceeded);
    },
  );

  test('replaced final file blocks recovery without overwrite', () async {
    final HttpServer upstream = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    upstream.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      request.response.headers.set(
        'content-disposition',
        'attachment; filename="qa.pdf"',
      );
      request.response.write('%PDF-1.4 original');
      await request.response.close();
    });
    final String ledgerPath = '${root.path}/replaced-ledger.json';
    final _FailFirstFinishLedger fault = _FailFirstFinishLedger(
      ChatLedger.atPath(ledgerPath),
      failures: 3,
    );
    final Directory cacheRoot = Directory('${root.path}/replaced-cache');
    final DownloadManager first = DownloadManager(
      api: ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}'),
      ),
      session: session,
      ledger: fault,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) => fault.deliverPendingEvents(event.account),
    );
    DownloadTask? task;
    try {
      task = await first.start(
        operationId: 'replaced-op',
        consumerSession: 'origin-consumer',
        mediaId: 'qa-media',
      );
      await first.dispose();
    } finally {
      await first.dispose();
      await upstream.close(force: true);
    }
    await File(task.plannedPath).writeAsString('third-party replacement');
    final DownloadManager second = DownloadManager(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: fault,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) => fault.deliverPendingEvents(event.account),
    );
    try {
      await second.resumePending();
      await second.dispose();
    } finally {
      await second.dispose();
    }
    final DownloadTask pending = (await fault.backing.download(
      _accountA,
      task.taskId,
    ))!;
    expect(pending.status, DownloadStatus.pending);
    expect(
      await File(task.plannedPath).readAsString(),
      'third-party replacement',
    );
    final LocalEventPage page = await fault.backing.readLocalEvents(
      account: _accountA,
      consumerSession: 'origin-consumer',
      afterCursor: 0,
    );
    expect(page.items, isEmpty);
  });

  test('truncated staging without prepare record never succeeds', () async {
    if (!Platform.isLinux) {
      return;
    }
    final HttpServer upstream = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    upstream.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType('application', 'pdf');
      request.response.headers.set(
        'content-disposition',
        'attachment; filename="qa.pdf"',
      );
      request.response.write('%PDF-1.4 trusted staged bytes');
      await request.response.close();
    });
    final String ledgerPath = '${root.path}/corrupt-ledger.json';
    final ChatLedger backing = ChatLedger.atPath(ledgerPath);
    final Directory cacheRoot = Directory('${root.path}/corrupt-cache');
    final Directory terminal = Directory('${cacheRoot.path}/.terminal');
    await terminal.create(recursive: true);
    await Process.run('chmod', <String>['500', terminal.path]);
    final DownloadManager first = DownloadManager(
      api: ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}'),
      ),
      session: session,
      ledger: backing,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) =>
          backing.deliverPendingEvents(event.account),
    );
    DownloadTask? task;
    try {
      task = await first.start(
        operationId: 'corrupt-op',
        consumerSession: 'origin-consumer',
        mediaId: 'qa-media',
      );
      await first.dispose();
    } finally {
      await first.dispose();
      await Process.run('chmod', <String>['700', terminal.path]);
      await upstream.close(force: true);
    }
    final File staging = File('${cacheRoot.path}/.staging/${task.taskId}.part');
    await staging.writeAsString('%PDF', flush: true);
    final DownloadManager second = DownloadManager(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: backing,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) =>
          backing.deliverPendingEvents(event.account),
    );
    try {
      await second.resumePending();
      await second.dispose();
    } finally {
      await second.dispose();
    }
    final DownloadTask pending = (await backing.download(
      _accountA,
      task.taskId,
    ))!;
    expect(pending.status, DownloadStatus.pending);
    expect(pending.actualPath, isNull);
    final LocalEventPage page = await backing.readLocalEvents(
      account: _accountA,
      consumerSession: 'origin-consumer',
      afterCursor: 0,
    );
    expect(page.items, isEmpty);
  });
}
