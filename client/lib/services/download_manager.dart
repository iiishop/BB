import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';
import 'media_source.dart';

class _Recovery {
  const _Recovery({this.task}) : blocked = false, normal = false;
  const _Recovery.blocked() : task = null, blocked = true, normal = false;
  const _Recovery.normal() : task = null, blocked = false, normal = true;

  final DownloadTask? task;
  final bool blocked;
  final bool normal;
}

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
          _spawn(account, captured.token, prior, resumed: true);
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
        await _cleanupPrepare(task.taskId);
      } else if ((task.status == DownloadStatus.pending ||
              task.status == DownloadStatus.running) &&
          !_active.containsKey(task.taskId)) {
        _spawn(account, captured.token, task, resumed: true);
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
        _spawn(captured.account, captured.token, task, resumed: true);
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
        await _cleanupPrepare(task.taskId);
      }
    }
  }

  void _spawn(
    String account,
    String token,
    DownloadTask task, {
    bool resumed = false,
  }) {
    if (_disposed || _active.containsKey(task.taskId)) {
      return;
    }
    final Future<void> work = _run(account, token, task, resumed: resumed);
    _active[task.taskId] = work;
    unawaited(
      work.whenComplete(() {
        _active.remove(task.taskId);
      }),
    );
  }

  Future<void> _run(
    String account,
    String token,
    DownloadTask task, {
    bool resumed = false,
  }) async {
    bool normalPending = !resumed;
    if (resumed) {
      final _Recovery recovery = await _recoverPrepared(account, task);
      if (recovery.task != null) {
        final bool committed = await _commitSucceeded(account, recovery.task!);
        if (committed) {
          await _cleanupPrepare(task.taskId);
        }
        return;
      }
      if (recovery.blocked) {
        return;
      }
      normalPending = recovery.normal;
    }
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
      final Directory stagingDirectory = Directory(
        '${cacheRoot.path}${Platform.pathSeparator}.staging',
      );
      await stagingDirectory.create(recursive: true);
      final File staging = File(_stagingPath(task.taskId));
      await staging.writeAsBytes(media.bytes, flush: true);
      final int size = await staging.length();
      final String digest = sha256
          .convert(await staging.readAsBytes())
          .toString();
      // Preparation is durable before the final path is touched. A failure to
      // persist this record leaves only the task-specific staging file; it
      // never places/overwrites the final file and never invents a transport
      // failure.
      if (!await _writePrepare(
        account: account,
        task: task,
        stagingPath: staging.path,
        finalPath: target.path,
        size: size,
        digest: digest,
      )) {
        return;
      }
      if (!await _placePrepared(staging, target, size, digest)) {
        return;
      }
    } catch (error) {
      if (resumed && !normalPending) {
        return;
      }
      if (error is AuthFailure &&
          (error.status == 401 || error.status == 403)) {
        // A stale/expired token must not become a permanent business failure;
        // leave the accepted task resumable for the origin account.
        return;
      }
      await _recordFailed(account, task, error);
      return;
    }

    final DownloadTask done = task.copyWith(
      status: DownloadStatus.succeeded,
      plannedPath: target.path,
      actualPath: target.path,
    );
    final bool committed = await _commitSucceeded(account, done);
    if (committed) {
      await _cleanupPrepare(task.taskId);
    }
  }

  Future<bool> _commitSucceeded(String account, DownloadTask done) async {
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
      // Keep the prepare record and pending task for the next recovery pass.
      return false;
    }
    try {
      await onEvent(event);
    } catch (_) {
      // The durable pending event is retried on the origin account's next
      // read/wait or restart; a successful saved file is never reclassified.
    }
    return true;
  }

  String _preparePath(String taskId) =>
      '${cacheRoot.path}${Platform.pathSeparator}.terminal'
      '${Platform.pathSeparator}$taskId.json';

  String _stagingPath(String taskId) =>
      '${cacheRoot.path}${Platform.pathSeparator}.staging'
      '${Platform.pathSeparator}$taskId.part';

  Future<bool> _writePrepare({
    required String account,
    required DownloadTask task,
    required String stagingPath,
    required String finalPath,
    required int size,
    required String digest,
  }) async {
    try {
      final Map<String, dynamic> record = <String, dynamic>{
        'version': 2,
        'state': 'prepared',
        'task_id': task.taskId,
        'operation_id': task.operationId,
        'account': account,
        'consumer_session': task.consumerSession,
        'media_id': task.mediaId,
        'staging_path': stagingPath,
        'final_path': finalPath,
        'size': size,
        'sha256': digest,
      };
      final File target = File(_preparePath(task.taskId));
      await target.parent.create(recursive: true);
      final File temporary = File(
        '${target.path}.part-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await temporary.writeAsString(jsonEncode(record), flush: true);
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _placePrepared(
    File staging,
    File target,
    int size,
    String digest,
  ) async {
    try {
      if (await target.exists()) {
        if (await target.length() == 0) {
          await target.delete();
        } else {
          return false;
        }
      }
      await staging.rename(target.path);
      if (!await target.exists() ||
          await target.length() != size ||
          sha256.convert(await target.readAsBytes()).toString() != digest) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<_Recovery> _recoverPrepared(String account, DownloadTask task) async {
    final File record = File(_preparePath(task.taskId));
    if (await record.exists()) {
      try {
        final Object? decoded = jsonDecode(await record.readAsString());
        if (decoded is! Map<String, dynamic>) {
          return const _Recovery.blocked();
        }
        final int? version = decoded['version'] as int?;
        // Backwards-compatible recovery of the previous v1 completion marker.
        if (version == 1) {
          final String? actualPath = decoded['actual_path'] as String?;
          final int? size = decoded['size'] as int?;
          final String? digest = decoded['sha256'] as String?;
          if (decoded['task_id'] != task.taskId ||
              decoded['operation_id'] != task.operationId ||
              decoded['account'] != account ||
              decoded['consumer_session'] != task.consumerSession ||
              actualPath == null ||
              size == null ||
              digest == null) {
            return const _Recovery.blocked();
          }
          final File file = File(actualPath);
          if (!await file.exists() ||
              await file.length() != size ||
              sha256.convert(await file.readAsBytes()).toString() != digest) {
            return const _Recovery.blocked();
          }
          return _Recovery(
            task: task.copyWith(
              status: DownloadStatus.succeeded,
              plannedPath: actualPath,
              actualPath: actualPath,
            ),
          );
        }
        final String? stagingPath = decoded['staging_path'] as String?;
        final String? finalPath = decoded['final_path'] as String?;
        final int? size = decoded['size'] as int?;
        final String? digest = decoded['sha256'] as String?;
        if (version != 2 ||
            decoded['task_id'] != task.taskId ||
            decoded['operation_id'] != task.operationId ||
            decoded['account'] != account ||
            decoded['consumer_session'] != task.consumerSession ||
            decoded['media_id'] != task.mediaId ||
            stagingPath == null ||
            finalPath == null ||
            size == null ||
            digest == null) {
          return const _Recovery.blocked();
        }
        final File finalFile = File(finalPath);
        final File stagingFile = File(stagingPath);
        if (await finalFile.exists() &&
            await finalFile.length() == size &&
            sha256.convert(await finalFile.readAsBytes()).toString() ==
                digest) {
          return _Recovery(
            task: task.copyWith(
              status: DownloadStatus.succeeded,
              plannedPath: finalPath,
              actualPath: finalPath,
            ),
          );
        }
        if (await stagingFile.exists() &&
            await stagingFile.length() == size &&
            sha256.convert(await stagingFile.readAsBytes()).toString() ==
                digest) {
          if (!await _placePrepared(stagingFile, finalFile, size, digest)) {
            return const _Recovery.blocked();
          }
          return _Recovery(
            task: task.copyWith(
              status: DownloadStatus.succeeded,
              plannedPath: finalPath,
              actualPath: finalPath,
            ),
          );
        }
        return const _Recovery.blocked();
      } catch (_) {
        return const _Recovery.blocked();
      }
    }

    // Preparation may have written staging bytes and then failed to persist
    // the record. The task-specific staging file is still evidence we can
    // verify and promote once the record is writable again.
    final File staging = File(_stagingPath(task.taskId));
    if (await staging.exists()) {
      try {
        final int size = await staging.length();
        final String digest = sha256
            .convert(await staging.readAsBytes())
            .toString();
        final File finalFile = File(task.plannedPath);
        if (await finalFile.exists() && await finalFile.length() > 0) {
          return const _Recovery.blocked();
        }
        if (!await _writePrepare(
          account: account,
          task: task,
          stagingPath: staging.path,
          finalPath: task.plannedPath,
          size: size,
          digest: digest,
        )) {
          return const _Recovery.blocked();
        }
        return await _recoverPrepared(account, task);
      } catch (_) {
        return const _Recovery.blocked();
      }
    }

    final File finalFile = File(task.plannedPath);
    if (await finalFile.exists() && await finalFile.length() > 0) {
      // Old pending ledger with a non-empty target: no proof this task owns it.
      return const _Recovery.blocked();
    }
    return const _Recovery.normal();
  }

  Future<void> _cleanupPrepare(String taskId) async {
    try {
      final File record = File(_preparePath(taskId));
      if (await record.exists()) {
        await record.delete();
      }
      final File staging = File(_stagingPath(taskId));
      if (await staging.exists()) {
        await staging.delete();
      }
    } catch (_) {
      // A stale record/staging is harmless: recovery validates identity/hash.
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
