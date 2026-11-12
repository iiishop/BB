import 'dart:async';
import 'dart:io';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';
import 'media_source.dart';

/// Async attachment downloads owned by the client.
///
/// A start call only reserves a path and persists the task; bytes are fetched
/// afterwards. Completion/failure is appended to the originating consumer
/// session's durable local event feed, so a plugin can wake the exact session
/// that asked for the file.
class DownloadManager {
  DownloadManager({
    required this.api,
    required this.session,
    required this.ledger,
    required this.cacheRoot,
    required this.onEvent,
  });

  final ChatApiClient api;
  final AuthSession session;
  final ChatLedger ledger;
  final Directory cacheRoot;
  final Future<void> Function(LocalEvent event) onEvent;

  final Map<String, Future<void>> _active = <String, Future<void>>{};
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  Future<T> _locked<T>(Future<T> Function() action) {
    final Completer<void> gate = Completer<void>();
    final Future<void> previous = _tail;
    _tail = gate.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        gate.complete();
      }
    });
  }

  Future<DownloadTask> start({
    required String operationId,
    required String consumerSession,
    required String mediaId,
    String? directory,
  }) {
    return _locked(() async {
      if (!_operationIdPattern.hasMatch(operationId)) {
        throw _validation('operation_id 只能包含 A-Z a-z 0-9 _ -，长度 1–128');
      }
      if (consumerSession.trim().isEmpty || consumerSession.length > 200) {
        throw _validation('consumer_session 无效');
      }
      final AuthIdentity? captured = session.identity;
      if (captured == null) {
        throw unauthenticated;
      }
      final String account = captured.account;
      final String? existingTaskId = await ledger.downloadTaskForOperation(
        account,
        operationId,
      );
      if (existingTaskId != null) {
        final DownloadTask? prior = await ledger.download(
          account,
          existingTaskId,
        );
        if (prior == null) {
          throw upstreamMalformed;
        }
        if (prior.mediaId != null && prior.mediaId != mediaId) {
          throw _conflict('operation_id 已用于另一份附件');
        }
        if (prior.consumerSession != consumerSession) {
          throw _conflict('operation_id 已绑定另一个会话');
        }
        if (prior.status == DownloadStatus.pending ||
            prior.status == DownloadStatus.running) {
          _spawn(account, captured.token, prior);
        }
        return prior;
      }
      if (mediaId.isEmpty) {
        throw _validation('media_id 不能为空');
      }
      final MediaProbe probe = await api.probeMedia(
        token: captured.token,
        mediaId: mediaId,
      );
      if (!session.isCurrent(captured)) {
        throw unauthenticated;
      }
      final AttachmentKind kind = attachmentKindForMime(probe.mimeType);
      final String filename = sanitizeFilename(
        probe.filename ?? 'attachment-${_short(mediaId)}',
      );
      final Directory targetDirectory = await _resolveDirectory(
        directory,
        kind,
      );
      final File planned = await _reserve(targetDirectory, filename);
      final DownloadTask task = DownloadTask(
        taskId: _taskId(),
        operationId: operationId,
        consumerSession: consumerSession,
        status: DownloadStatus.pending,
        plannedPath: planned.path,
        mediaId: mediaId,
        kind: kind,
        filename: filename,
      );
      await ledger.saveDownload(account, task);
      await ledger.saveDownloadOperation(account, operationId, task.taskId);
      _spawn(account, captured.token, task);
      return task;
    });
  }

  Future<DownloadTask?> get({
    required String taskId,
    required String consumerSession,
  }) {
    return _locked(() async {
      final AuthIdentity? captured = session.identity;
      if (captured == null) {
        throw unauthenticated;
      }
      final String account = captured.account;
      final DownloadTask? task = await ledger.download(account, taskId);
      if (task == null || task.consumerSession != consumerSession) {
        return null;
      }
      if (task.status.terminal && !_active.containsKey(task.taskId)) {
        // Repair a terminal task whose event commit was interrupted, and
        // deliver it if a previous account switch deferred it.
        final LocalEvent event = _terminalEvent(account, task);
        await ledger.finishDownload(account: account, task: task, event: event);
        try {
          await onEvent(event);
        } catch (_) {
          // Pending delivery remains durable for the origin account.
        }
      } else if ((task.status == DownloadStatus.pending ||
              task.status == DownloadStatus.running) &&
          !_active.containsKey(task.taskId)) {
        _spawn(account, captured.token, task);
      }
      if (!session.isCurrent(captured)) {
        throw unauthenticated;
      }
      return task;
    });
  }

  /// Resumes accepted-but-unfinished tasks after a restart.
  Future<void> resumePending() async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      return;
    }
    final List<DownloadTask> tasks = await ledger.downloads(captured.account);
    for (final DownloadTask task in tasks) {
      if (task.status == DownloadStatus.pending ||
          task.status == DownloadStatus.running) {
        _spawn(captured.account, captured.token, task);
      } else if (task.status.terminal) {
        final LocalEvent event = _terminalEvent(captured.account, task);
        await ledger.finishDownload(
          account: captured.account,
          task: task,
          event: event,
        );
        try {
          await onEvent(event);
        } catch (_) {
          // Pending delivery remains durable.
        }
      }
    }
  }

  void _spawn(String account, String token, DownloadTask task) {
    if (_disposed || _active.containsKey(task.taskId)) {
      return;
    }
    final Future<void> work = _run(account, token, task);
    _active[task.taskId] = work;
    unawaited(
      work.whenComplete(() {
        _active.remove(task.taskId);
      }),
    );
  }

  Future<void> _run(String account, String token, DownloadTask task) async {
    File target;
    try {
      final MediaResponse media = await api.fetchMedia(
        token: token,
        mediaId: task.mediaId ?? '',
      );
      if (media.bytes.isEmpty) {
        throw _failure('empty_file');
      }
      target = File(task.plannedPath);
      // Reuse our own reservation only when it is still empty; never overwrite
      // a file the user placed there in the meantime.
      if (!await target.exists() || await target.length() != 0) {
        target = await _reserve(target.parent, task.filename ?? 'attachment');
      }
      final File temporary = File(
        '${target.path}.part-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await temporary.writeAsBytes(media.bytes, flush: true);
        try {
          await temporary.rename(target.path);
        } on FileSystemException {
          // Windows cannot rename over an existing reservation; we own this
          // zero-byte placeholder, so replace it explicitly.
          if (await target.exists() && await target.length() == 0) {
            await target.delete();
            await temporary.rename(target.path);
          } else {
            rethrow;
          }
        }
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
    } catch (error) {
      if (error is AuthFailure &&
          (error.status == 401 || error.status == 403)) {
        // A stale/expired token must not become a permanent business failure;
        // leave the accepted task resumable for the origin account.
        return;
      }
      await _recordFailed(account, task, error);
      return;
    }

    // The bytes are saved. A ledger commit failure below is a persistence
    // problem, not a transfer failure: retry it, and never relabel the file as
    // a failed download.
    final DownloadTask done = task.copyWith(
      status: DownloadStatus.succeeded,
      plannedPath: target.path,
      actualPath: target.path,
    );
    final LocalEvent event = _terminalEvent(account, done);
    bool committed = false;
    for (int attempt = 0; attempt < 3 && !committed; attempt++) {
      try {
        await ledger.finishDownload(account: account, task: done, event: event);
        committed = true;
      } catch (_) {
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
    if (!committed) {
      // Leave the accepted task pending/recoverable rather than inventing a
      // failed download fact. The saved file and task remain for a later
      // repair/read.
      return;
    }
    try {
      await onEvent(event);
    } catch (_) {
      // The durable pending event is retried on the origin account's next
      // read/wait or restart; a successful saved file is never reclassified.
    }
  }

  Future<void> _recordFailed(
    String account,
    DownloadTask task,
    Object error,
  ) async {
    final String code = error is AuthFailure ? error.code : 'download_failed';
    final File planned = File(task.plannedPath);
    try {
      if (await planned.exists() && await planned.length() == 0) {
        await planned.delete();
      }
    } catch (_) {
      // A leftover zero-byte reservation is harmless; report the real error.
    }
    final DownloadTask failed = task.copyWith(
      status: DownloadStatus.failed,
      errorCode: code,
    );
    final LocalEvent event = _terminalEvent(account, failed);
    try {
      await ledger.finishDownload(account: account, task: failed, event: event);
      await onEvent(event);
    } catch (_) {
      // Keep the accepted task resumable rather than inventing a second
      // failure fact when the ledger commit itself failed.
    }
  }

  LocalEvent _terminalEvent(String account, DownloadTask task) {
    final bool succeeded = task.status == DownloadStatus.succeeded;
    return LocalEvent(
      eventId: 'download:${task.taskId}:${succeeded ? 'succeeded' : 'failed'}',
      account: account,
      consumerSession: task.consumerSession,
      type: succeeded
          ? LocalEventType.downloadSucceeded
          : LocalEventType.downloadFailed,
      taskId: task.taskId,
      operationId: task.operationId,
      actualPath: succeeded ? task.actualPath : null,
      errorCode: succeeded ? null : task.errorCode ?? 'download_failed',
    );
  }

  /// Human "另存为": writes to the exact chosen path, never silently
  /// overwriting an existing file (a numeric suffix is used instead).
  Future<String> saveAsCopy({
    required String mediaId,
    required String targetPath,
  }) async {
    if (targetPath.trim().isEmpty) {
      throw _validation('保存路径不能为空');
    }
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final String account = captured.account;
    final MediaResponse media = await api.fetchMedia(
      token: captured.token,
      mediaId: mediaId,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    final File chosen = await _uniqueFile(File(targetPath));
    final Directory parent = chosen.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final File temporary = File(
      '${chosen.path}.part-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(media.bytes, flush: true);
      await temporary.rename(chosen.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
    // Persist the human-visible copy as a completed task too, so the UI can
    // show a durable record and the agent can query it.
    final DownloadTask task = DownloadTask(
      taskId: _taskId(),
      operationId: 'save_${DateTime.now().microsecondsSinceEpoch}',
      consumerSession: 'human:$account',
      status: DownloadStatus.succeeded,
      plannedPath: chosen.path,
      actualPath: chosen.path,
      mediaId: mediaId,
      filename: chosen.uri.pathSegments.last,
    );
    await ledger.saveDownload(account, task);
    return chosen.path;
  }

  Future<Directory> _resolveDirectory(
    String? directory,
    AttachmentKind kind,
  ) async {
    Directory target;
    if (directory == null || directory.trim().isEmpty) {
      target = Directory(
        '${cacheRoot.path}${Platform.pathSeparator}${kind.cacheDirectory}',
      );
    } else {
      final String raw = directory.trim();
      if (raw.contains('\u0000') || _hasTraversal(raw)) {
        throw _validation('目录不能包含 .. 或空字符');
      }
      if (_isAbsolute(raw)) {
        target = Directory(raw);
      } else {
        if (_hasTraversal(cacheRoot.path)) {
          throw _validation('缓存目录无效');
        }
        target = Directory('${cacheRoot.path}${Platform.pathSeparator}$raw');
      }
    }
    try {
      if (!await target.exists()) {
        await target.create(recursive: true);
      }
    } on FileSystemException {
      throw _failure('directory_not_writable');
    }
    return target;
  }

  Future<File> _reserve(Directory directory, String filename) async {
    final String safe = sanitizeFilename(filename);
    final int dot = safe.lastIndexOf('.');
    final String stem = dot > 0 ? safe.substring(0, dot) : safe;
    final String extension = dot > 0 ? safe.substring(dot) : '';
    for (int index = 1; index <= 500; index++) {
      final String name = index == 1 ? safe : '$stem ($index)$extension';
      final File candidate = File(
        '${directory.path}${Platform.pathSeparator}$name',
      );
      try {
        await candidate.create(exclusive: true);
        return candidate;
      } on FileSystemException {
        continue;
      }
    }
    throw _failure('path_conflict');
  }

  Future<File> _uniqueFile(File file) async {
    if (!await file.exists()) {
      return file;
    }
    final String path = file.path;
    final int dot = path.lastIndexOf('.');
    final int separator = path.lastIndexOf(Platform.pathSeparator);
    final String stem = dot > separator ? path.substring(0, dot) : path;
    final String extension = dot > separator ? path.substring(dot) : '';
    for (int index = 2; index <= 500; index++) {
      final File candidate = File('$stem ($index)$extension');
      if (!await candidate.exists()) {
        return candidate;
      }
    }
    throw _failure('path_conflict');
  }

  Future<void> dispose() async {
    _disposed = true;
    await Future.wait<void>(_active.values.toList());
  }

  static final RegExp _operationIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static bool _hasTraversal(String value) {
    final List<String> parts = value.split(RegExp(r'[\\/]'));
    return parts.any((String part) => part == '..');
  }

  static bool _isAbsolute(String value) {
    if (value.startsWith('/')) {
      return true;
    }
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  }

  static String _taskId() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int salt = DateTime.now().microsecondsSinceEpoch % 997;
    return 'dl-$now-$salt';
  }

  static String _short(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  static AuthFailure _validation(String message) => AuthFailure(
    status: 422,
    code: 'validation_error',
    message: message,
    fields: const <AuthFieldError>[
      AuthFieldError(field: 'path', code: 'invalid', message: '路径无效'),
    ],
  );

  static AuthFailure _failure(String code) =>
      AuthFailure(status: 503, code: code, message: '下载失败');

  static AuthFailure _conflict(String message) =>
      AuthFailure(status: 409, code: 'conflict', message: message);
}
