import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'conversation_access.dart';

/// Byte-level cache for image bytes that must survive a restart.
///
/// [SpaceImageLoader] keeps bytes in memory so re-reading one picture during a
/// session is free, but that map dies with the process — reopening a picture
/// after leaving the viewer or restarting the app downloaded the original
/// again. This layer sits behind it: disk first, network only on a miss. Chat
/// originals share it under their own key prefix.
///
/// Entries are keyed by `<variant>|<id>` (Space) or `chat-<variant>|<mediaId>`
/// (chat). Both ids are server-assigned and immutable, so no version component
/// is needed. Exactly one `|` per key: the file name swaps it for `_` and the
/// reverse parse splits on the first `_`.
class MediaDiskCache {
  MediaDiskCache({this.maxBytes = 256 * 1024 * 1024, this.directory});

  /// Soft ceiling. Oldest entries are evicted once a write crosses it.
  final int maxBytes;

  /// Optional explicit directory (used by tests instead of `path_provider`).
  final Directory? directory;

  Directory? _dir;

  /// Set once initialisation can never succeed: no platform implementation
  /// (widget tests) or a directory that could not be created. A flag rather
  /// than a cached future on purpose — a completed future is bound to the zone
  /// that created it, and a process-wide cache is first touched in one widget
  /// test and read in the next, where awaiting that future never completes and
  /// hangs `pumpAndSettle`.
  bool _unavailable = false;
  int _bytes = 0;

  /// Key to byte size, for eviction. File length is the authority on restart.
  final Map<String, int> _sizes = <String, int>{};

  /// LRU order, oldest first.
  final List<String> _order = <String>[];

  Future<void> _ensureReady() async {
    if (_dir != null || _unavailable) {
      return;
    }
    await _prepare();
  }

  Future<void> _prepare() async {
    // Widget tests run without a path_provider implementation; asking for the
    // cache directory there never completes and hangs pumpAndSettle. The loader
    // then just works from memory, which is what those tests exercise anyway.
    if (directory == null && Platform.environment.containsKey('FLUTTER_TEST')) {
      _unavailable = true;
      return;
    }
    try {
      final Directory dir =
          directory ??
          Directory(
            '${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}space-media',
          );
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _dir = dir;
      // Index what a previous run left behind, newest last so eviction walks
      // from the least recently written entry.
      final List<File> files =
          dir
              .listSync()
              .whereType<File>()
              .where((File f) => f.path.endsWith('.bin'))
              .toList()
            ..sort(
              (File a, File b) =>
                  a.statSync().modified.compareTo(b.statSync().modified),
            );
      for (final File file in files) {
        final String key = _keyOf(file);
        final int size = file.statSync().size;
        _sizes[key] = size;
        _order.add(key);
        _bytes += size;
      }
      _evict();
    } catch (error) {
      // A cache that cannot initialise is not an error the user should see;
      // the loader simply falls back to the network.
      debugPrint('[media-cache] 初始化失败：$error');
      _dir = null;
      _unavailable = true;
    }
  }

  File? _file(String key) {
    final Directory? dir = _dir;
    if (dir == null) {
      return null;
    }
    return File('${dir.path}${Platform.pathSeparator}${_nameOf(key)}.bin');
  }

  String _nameOf(String key) => key.replaceAll('|', '_');

  String _keyOf(File file) {
    final String name = file.uri.pathSegments.last;
    final String stem = name.substring(0, name.length - 4);
    final int split = stem.indexOf('_');
    if (split <= 0) {
      return stem;
    }
    return '${stem.substring(0, split)}|${stem.substring(split + 1)}';
  }

  /// Cached bytes for [key], or null when nothing is on disk.
  Future<Uint8List?> read(String key) async {
    await _ensureReady();
    final File? file = _file(key);
    if (file == null || !file.existsSync()) {
      return null;
    }
    try {
      final Uint8List bytes = await file.readAsBytes();
      _touch(key, bytes.length);
      return bytes;
    } catch (error) {
      debugPrint('[media-cache] 读取失败 $key：$error');
      return null;
    }
  }

  /// Stores [bytes] for [key]. Failures are swallowed: a full disk must not
  /// break viewing.
  Future<void> write(String key, Uint8List bytes) async {
    await _ensureReady();
    final File? file = _file(key);
    if (file == null) {
      return;
    }
    try {
      await file.writeAsBytes(bytes, flush: false);
      _touch(key, bytes.length);
      _evict();
    } catch (error) {
      debugPrint('[media-cache] 写入失败 $key：$error');
    }
  }

  /// Deletes a single cached entry from memory and disk.
  Future<void> delete(String key) async {
    await _ensureReady();
    final int? size = _sizes.remove(key);
    if (size != null) {
      _bytes -= size;
      _order.remove(key);
    }
    final File? file = _file(key);
    try {
      if (file != null && file.existsSync()) {
        file.deleteSync();
      }
    } catch (error) {
      debugPrint('[media-cache] 删除失败 $key：$error');
    }
  }

  /// Deletes every cached entry whose key matches [predicate] (used on group
  /// revocation or identity clear).
  Future<int> deleteWhere(bool Function(String key) predicate) async {
    await _ensureReady();
    final List<String> targets = _sizes.keys.where(predicate).toList();
    for (final String key in targets) {
      await delete(key);
    }
    return targets.length;
  }

  void _touch(String key, int size) {
    final int? previous = _sizes[key];
    if (previous != null) {
      _bytes -= previous;
      _order.remove(key);
    }
    _sizes[key] = size;
    _order.add(key);
    _bytes += size;
  }

  void _evict() {
    while (_bytes > maxBytes && _order.isNotEmpty) {
      final String oldest = _order.removeAt(0);
      final int? size = _sizes.remove(oldest);
      if (size != null) {
        _bytes -= size;
      }
      final File? file = _file(oldest);
      try {
        if (file != null && file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {
        // Locked file: drop it from the index and move on.
      }
    }
  }

  /// Current footprint, for diagnostics.
  int get byteCount => _bytes;

  /// Entry count, for diagnostics.
  int get entryCount => _sizes.length;
}

MediaDiskCache? _shared;

/// The one cache instance for this process.
///
/// Two instances would index the same directory independently: each would count
/// and evict without seeing the other's files, so the ceiling would drift and
/// one surface could delete an entry the other is about to read.
MediaDiskCache sharedMediaDiskCache() => _shared ??= MediaDiskCache();

/// Registers a [MediaDiskCache] purger on [access] so any group revocation
/// deletes `chat-original-<scopeTag>|*` entries for `(server, account,
/// conversationId)` even when no viewer is currently open.
ConversationCachePurger registerDiskCachePurger({
  required ConversationAccessController access,
  required MediaDiskCache disk,
  required Uri serverUri,
}) {
  final String server = serverUri.toString();
  Future<void> purger(
    String account,
    String conversationId,
    Set<String> mediaIds,
  ) async {
    final String tag = ConversationAccessController.diskScopeTag(
      server: server,
      account: account,
      conversationId: conversationId,
    );
    final String prefix = 'chat-original-$tag|';
    await disk.deleteWhere((String key) => key.startsWith(prefix));
    for (final String mediaId in mediaIds) {
      await disk.delete('$prefix$mediaId');
    }
  }

  access.registerPurger(purger);
  return purger;
}
