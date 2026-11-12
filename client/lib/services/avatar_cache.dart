import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Cached avatar bytes and the server version they were fetched for.
class CachedAvatar {
  const CachedAvatar({required this.bytes, required this.version});

  final Uint8List bytes;
  final String version;
}

/// Avatar cache contract (memory is always used; disk is optional).
abstract class AvatarCacheStore {
  Future<CachedAvatar?> read(String account);

  Future<void> write(String account, Uint8List bytes, String version);

  Future<void> invalidate(String account);
}

/// Bounded in-memory LRU cache with an optional disk mirror.
///
/// The server remains the single source of truth: the cache is only reused
/// after a `304 Not Modified` for the stored `avatar_version`. Opening another
/// user's Profile and every MCP `view_avatar` still call the server.
class AvatarCache implements AvatarCacheStore {
  AvatarCache({this.directory, this.maxEntries = 24});

  /// Optional disk mirror; memory-only when null.
  final Directory? directory;
  final int maxEntries;
  final LinkedHashMap<String, CachedAvatar> _memory =
      LinkedHashMap<String, CachedAvatar>();

  @override
  Future<CachedAvatar?> read(String account) async {
    final CachedAvatar? memory = _memory.remove(account);
    if (memory != null) {
      _memory[account] = memory;
      return memory;
    }
    final Directory? directory = this.directory;
    if (directory == null) {
      return null;
    }
    final File image = _imageFile(directory, account);
    final File versionFile = _versionFile(directory, account);
    try {
      if (!await image.exists() || !await versionFile.exists()) {
        return null;
      }
      final String version = (await versionFile.readAsString()).trim();
      if (version.isEmpty) {
        return null;
      }
      final Uint8List bytes = await image.readAsBytes();
      if (bytes.isEmpty) {
        return null;
      }
      final CachedAvatar cached = CachedAvatar(bytes: bytes, version: version);
      _remember(account, cached);
      return cached;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(String account, Uint8List bytes, String version) async {
    if (bytes.isEmpty || version.isEmpty) {
      return;
    }
    _remember(account, CachedAvatar(bytes: bytes, version: version));
    final Directory? directory = this.directory;
    if (directory == null) {
      return;
    }
    try {
      await directory.create(recursive: true);
      final File image = _imageFile(directory, account);
      final File temporary = File('${image.path}.$pid.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      // The cache is expendable; if a Windows rename over the old file fails,
      // delete first instead of failing the avatar request.
      try {
        await temporary.rename(image.path);
      } on FileSystemException {
        if (await image.exists()) {
          await image.delete();
        }
        await temporary.rename(image.path);
      }
      await _versionFile(
        directory,
        account,
      ).writeAsString(version, flush: true);
    } on FileSystemException {
      // Cache writes are best effort; the fetched bytes are still returned.
    }
  }

  @override
  Future<void> invalidate(String account) async {
    _memory.remove(account);
    final Directory? directory = this.directory;
    if (directory == null) {
      return;
    }
    for (final File file in <File>[
      _imageFile(directory, account),
      _versionFile(directory, account),
    ]) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Ignore: a stale file is harmless because the version gate rejects it.
      }
    }
  }

  void _remember(String account, CachedAvatar cached) {
    _memory.remove(account);
    _memory[account] = cached;
    while (_memory.length > maxEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  File _imageFile(Directory directory, String account) =>
      File('${directory.path}${Platform.pathSeparator}$account.png');

  File _versionFile(Directory directory, String account) =>
      File('${directory.path}${Platform.pathSeparator}$account.version');
}
