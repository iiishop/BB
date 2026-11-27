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
///
/// `thumb` selects the small derivative used by lists and bubbles. The original
/// and the derivative are cached separately: they have different bytes, different
/// ETags, and a client may legitimately hold both.
abstract class AvatarCacheStore {
  Future<CachedAvatar?> read(String account, {bool thumb = false});

  Future<void> write(
    String account,
    Uint8List bytes,
    String version, {
    bool thumb = false,
  });

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
  final Map<String, int> _generations = <String, int>{};

  @override
  Future<CachedAvatar?> read(String account, {bool thumb = false}) async {
    final String key = _key(account, thumb);
    final CachedAvatar? memory = _memory.remove(key);
    if (memory != null) {
      _memory[key] = memory;
      return memory;
    }
    final Directory? directory = this.directory;
    if (directory == null) {
      return null;
    }
    final File image = _imageFile(directory, account, thumb);
    final File versionFile = _versionFile(directory, account, thumb);
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
      _remember(key, cached);
      return cached;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(
    String account,
    Uint8List bytes,
    String version, {
    bool thumb = false,
  }) async {
    if (bytes.isEmpty || version.isEmpty) {
      return;
    }
    final String key = _key(account, thumb);
    final int generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    _remember(key, CachedAvatar(bytes: bytes, version: version));
    final Directory? directory = this.directory;
    if (directory == null) {
      return;
    }
    File? temporary;
    try {
      await directory.create(recursive: true);
      if (_generations[key] != generation) {
        return;
      }
      final File image = _imageFile(directory, account, thumb);
      temporary = File('${image.path}.$pid.$generation.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      if (_generations[key] != generation) {
        return;
      }
      // The cache is expendable; if a Windows rename over the old file fails,
      // delete first instead of failing the avatar request.
      try {
        await temporary.rename(image.path);
      } on FileSystemException {
        if (_generations[key] != generation) {
          return;
        }
        if (await image.exists()) {
          await image.delete();
        }
        if (_generations[key] != generation) {
          return;
        }
        await temporary.rename(image.path);
      }
      if (_generations[key] != generation) {
        return;
      }
      await _versionFile(
        directory,
        account,
        thumb,
      ).writeAsString(version, flush: true);
    } on FileSystemException {
      // Cache writes are best effort; the fetched bytes are still returned.
    } finally {
      if (temporary != null && _generations[key] != generation) {
        try {
          if (await temporary.exists()) {
            await temporary.delete();
          }
        } on FileSystemException {
          // Best-effort cleanup for superseded temp files.
        }
      }
    }
  }

  /// Drops both variants: a replaced avatar invalidates the original and the
  /// derivative together.
  @override
  Future<void> invalidate(String account) async {
    for (final bool thumb in <bool>[false, true]) {
      final String key = _key(account, thumb);
      _generations[key] = (_generations[key] ?? 0) + 1;
      _memory.remove(key);
    }
    final Directory? directory = this.directory;
    if (directory == null) {
      return;
    }
    for (final bool thumb in <bool>[false, true]) {
      for (final File file in <File>[
        _imageFile(directory, account, thumb),
        _versionFile(directory, account, thumb),
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
  }

  String _key(String account, bool thumb) => thumb ? '$account|thumb' : account;

  void _remember(String key, CachedAvatar cached) {
    _memory.remove(key);
    _memory[key] = cached;
    while (_memory.length > maxEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  String _stem(String account, bool thumb) =>
      thumb ? '$account-thumb' : account;

  File _imageFile(Directory directory, String account, bool thumb) => File(
    '${directory.path}${Platform.pathSeparator}${_stem(account, thumb)}.png',
  );

  File _versionFile(Directory directory, String account, bool thumb) => File(
    '${directory.path}${Platform.pathSeparator}${_stem(account, thumb)}.version',
  );
}
