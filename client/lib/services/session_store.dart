import 'dart:convert';
import 'dart:io';

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
  });

  factory PersistedSession.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('session must be an object');
    }
    final Object? account = json['account'];
    final Object? username = json['username'];
    final Object? token = json['token'];
    if (account is! String ||
        username is! String ||
        token is! String ||
        account.isEmpty ||
        username.isEmpty ||
        token.isEmpty) {
      throw const FormatException('session is missing fields');
    }
    return PersistedSession(account: account, username: username, token: token);
  }

  final String account;
  final String username;
  final String token;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
    'token': token,
  };
}

/// File-backed session storage shared by the Flutter UI and the standalone
/// local control API entry.
///
/// The file is written atomically and restricted to the current user
/// (`0600`, parent directory `0700` on POSIX). Windows relies on the user
/// profile ACL for the same guarantee.
class SessionStore {
  SessionStore(this.file);

  /// Session file at an explicit location (used by tests and configuration).
  SessionStore.atPath(String path) : file = File(path);

  final File file;

  /// Default POSIX permissions for a credential file (owner read/write only).
  static const int fileMode = 0x180; // 0600

  /// Returns the stored session, or null when absent/unreadable.
  ///
  /// A corrupt file is deleted so a later write starts from a clean state; an
  /// IO error leaves it untouched (it may be a transient mount problem).
  Future<PersistedSession?> read() async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final String raw = await file.readAsString();
      return PersistedSession.fromJson(jsonDecode(raw));
    } on FormatException {
      await _deleteQuietly(file);
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes the session atomically and restricts access to the current user.
  Future<void> write(PersistedSession session) async {
    final Directory parent = file.parent;
    await parent.create(recursive: true);
    await _restrict(parent.path, '700');

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(session.toJson()), flush: true);
    await _restrict(temporary.path, '600');

    // rename(2) replaces the target atomically on POSIX; Windows needs the
    // previous file gone first.
    await _deleteQuietly(file);
    await temporary.rename(file.path);
    await _restrict(file.path, '600');
  }

  Future<void> clear() => _deleteQuietly(file);

  Future<void> _deleteQuietly(File target) async {
    try {
      if (await target.exists()) {
        await target.delete();
      }
    } on FileSystemException {
      // Nothing to clean up, or the volume is read-only: the next read/write
      // reports its own state.
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
