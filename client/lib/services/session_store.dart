import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Replacement strategy for the session file.
///
/// The default implementation renames the new file over the old one (atomic on
/// POSIX) and falls back to a backup-and-restore dance on Windows. Injecting a
/// different implementation is only used by fault-injection tests.
typedef SessionReplace = Future<void> Function(File temporary, File target);

/// On-disk session record.
///
/// The password is never part of it; only the bearer token the server issued and
/// the account it belongs to. Keeping the token on disk is what lets the
/// desktop app and the standalone Dart entry restore a login after a restart.
class PersistedSession {
  const PersistedSession({
    required this.account,
    required this.username,
    required this.token,
    this.generation = 0,
    this.assignGeneration = false,
  });

  factory PersistedSession.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('session must be an object');
    }
    final Object? account = json['account'];
    final Object? username = json['username'];
    final Object? token = json['token'];
    final Object? rawGeneration = json['generation'];
    if (account is! String ||
        username is! String ||
        token is! String ||
        account.isEmpty ||
        username.isEmpty ||
        token.isEmpty) {
      throw const FormatException('session is missing fields');
    }
    if (rawGeneration != null &&
        (rawGeneration is! int || rawGeneration < 0)) {
      throw const FormatException('session generation is invalid');
    }
    return PersistedSession(
      account: account,
      username: username,
      token: token,
      generation: rawGeneration is int ? rawGeneration : 0,
    );
  }

  final String account;
  final String username;
  final String token;

  /// Monotonic commit generation used to reject stale credential writes.
  /// Older files without the field read as zero.
  final int generation;

  /// A new login asks the store to allocate its generation inside the commit
  /// queue, after any earlier queued clear. Repairs use a fixed generation.
  final bool assignGeneration;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
    'token': token,
    if (generation > 0) 'generation': generation,
  };
}

/// A client-side credential-store failure.
///
/// The auth service turns it into the shared `session_storage_unavailable`
/// error so the UI can explain it and the local HTTP API can refuse success.
class SessionStorageException implements Exception {
  const SessionStorageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'SessionStorageException($message)';
}

/// File-backed session storage shared by the Flutter UI and the standalone
/// local control API entry.
///
/// * the new record is written to a per-operation unique temporary file in the
///   same directory, then renamed into place;
/// * the previous credential is never deleted before the replacement exists:
///   on POSIX the rename is atomic, on Windows the old file is moved to a
///   backup and restored if the new one cannot be put in place;
/// * the file is restricted to the current user (`0600`, parent `0700`).
///
/// Windows relies on the user profile ACL for the same guarantee.
class SessionStore {
  SessionStore(this.file, {SessionReplace? replace})
    : _replace = replace ?? replaceFile;

  /// Session file at an explicit location (tests and configuration).
  SessionStore.atPath(String path, {SessionReplace? replace})
    : this(File(path), replace: replace);

  final File file;
  final SessionReplace _replace;

  /// Highest credential commit generation observed by this store instance.
  /// A write from an older login/repair is ignored after a newer login or a
  /// completed clear, so an in-flight stale write cannot resurrect or
  /// overwrite the current credential.
  int _generation = 0;

  int nextGeneration() => ++_generation;

  int get currentGeneration => _generation;

  /// All credential file mutations are serialized. Generation checks,
  /// temporary-file preparation, the injected replacement and deletion are one
  /// commit order: a write that was already queued behind a newer login/logout
  /// re-checks ownership before touching the file, and a new login that queues
  /// behind an in-flight replacement commits after it, then returns success.
  Future<void> _commitTail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final Completer<void> release = Completer<void>();
    final Future<void> previous = _commitTail;
    _commitTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  /// Default POSIX permissions for a credential file (owner read/write only).
  static const int fileMode = 0x180; // 0600

  /// Returns the stored session, or null when absent/corrupt.
  ///
  /// A corrupt file is removed on a best-effort basis (it is not a usable
  /// credential); IO errors are raised as [SessionStorageException] because
  /// silently treating an unreadable credential as "logged out" hides a real
  /// storage fault.
  Future<PersistedSession?> read() async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final String raw = await file.readAsString();
      final PersistedSession session = PersistedSession.fromJson(
        jsonDecode(raw),
      );
      if (session.generation > _generation) {
        _generation = session.generation;
      }
      return session;
    } on FormatException {
      await _deleteQuietly(file);
      return null;
    } on FileSystemException catch (error) {
      throw SessionStorageException('无法读取会话凭据', error);
    }
  }

  /// Writes the session without ever dropping the previous credential first.
  Future<void> write(PersistedSession session) {
    return _serialized(() => _writeLocked(session));
  }

  Future<void> _writeLocked(PersistedSession session) async {
    // Generation is allocated inside the serialized commit for a new login:
    // an earlier queued clear must not invalidate a login that was enqueued
    // after it. Repairs use their fixed generation and are rejected when a
    // newer login/logout already owns the file.
    final PersistedSession effective;
    if (session.assignGeneration) {
      _generation += 1;
      effective = PersistedSession(
        account: session.account,
        username: session.username,
        token: session.token,
        generation: _generation,
      );
    } else {
      if (session.generation < _generation) {
        return;
      }
      if (session.generation > _generation) {
        _generation = session.generation;
      }
      effective = session;
    }
    final Directory parent = file.parent;
    final File temporary = File('${file.path}.$pid.${_nonce()}.tmp');
    try {
      await parent.create(recursive: true);
      await _restrict(parent.path, '700');
      await temporary.writeAsString(jsonEncode(effective.toJson()), flush: true);
      await _restrict(temporary.path, '600');
      await _replace(temporary, file);
      await _restrict(file.path, '600');
    } on SessionStorageException {
      rethrow;
    } on FileSystemException catch (error) {
      throw SessionStorageException('无法写入会话凭据', error);
    } on ProcessException catch (error) {
      throw SessionStorageException('无法设置会话文件权限', error);
    } on StateError catch (error) {
      throw SessionStorageException('无法设置会话文件权限', error);
    } finally {
      // The rename consumed the temporary file on success; remove it when any
      // step failed, and never leave stray credential copies behind.
      await _deleteQuietly(temporary);
    }
  }

  /// Removes the stored credential and reports failures instead of pretending.
  Future<void> clear() {
    return _serialized(_clearLocked);
  }

  Future<void> _clearLocked() async {
    // A logout is a commit too: any older in-flight credential write must not
    // recreate the file after this point.
    _generation += 1;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException catch (error) {
      throw SessionStorageException('无法删除会话凭据', error);
    }
  }

  /// Default replacement: atomic rename, with a safe fallback for Windows.
  static Future<void> replaceFile(File temporary, File target) async {
    try {
      await temporary.rename(target.path);
      return;
    } on FileSystemException {
      // Windows cannot rename over an existing file; use a backup so the old
      // credential survives if the new one cannot be moved into place.
    }

    final File backup = File('${target.path}.bak');
    bool oldMoved = false;
    try {
      if (await target.exists()) {
        await _deleteIfExists(backup);
        await target.rename(backup.path);
        oldMoved = true;
      }
      await temporary.rename(target.path);
      await _deleteIfExists(backup);
    } on FileSystemException catch (error) {
      if (oldMoved) {
        try {
          await backup.rename(target.path);
        } on FileSystemException {
          // The old credential is still in the backup file; report the
          // original failure rather than losing it.
        }
      }
      throw SessionStorageException('无法替换会话凭据', error);
    }
  }

  static String _nonce() {
    final Random random = Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 4; i++) {
      buffer.write(random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'));
    }
    return buffer.toString();
  }

  static Future<void> _deleteIfExists(File target) async {
    if (await target.exists()) {
      await target.delete();
    }
  }

  static Future<void> _deleteQuietly(File target) async {
    try {
      await _deleteIfExists(target);
    } on FileSystemException {
      // Best-effort cleanup of corrupt data / temporary files. The credential
      // itself is never deleted quietly; that is [clear]'s job.
    }
  }

  Future<void> _restrict(String path, String mode) async {
    if (Platform.isWindows) {
      return;
    }
    try {
      final ProcessResult result = await Process.run('chmod', <String>[
        mode,
        path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('无法设置会话文件权限（chmod $mode 失败）');
      }
    } on ProcessException {
      throw StateError('无法设置会话文件权限（缺少 chmod 命令）');
    }
  }
}
