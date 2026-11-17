import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One successful save of a space image.
@immutable
class SpaceDownloadRecord {
  const SpaceDownloadRecord({
    required this.imageId,
    required this.savedAt,
    required this.location,
  });

  final String imageId;
  final DateTime savedAt;

  /// Whatever the platform reported: a file path on desktop, a gallery handle
  /// on Android/iOS. Only desktop paths are verifiable later; on mobile the
  /// record means "this was saved once", not "it is still there".
  final String location;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'image_id': imageId,
    'saved_at': savedAt.toIso8601String(),
    'location': location,
  };

  static SpaceDownloadRecord? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final String? imageId = value['image_id'] as String?;
    final String? savedAt = value['saved_at'] as String?;
    if (imageId == null || imageId.isEmpty || savedAt == null) {
      return null;
    }
    final DateTime? parsed = DateTime.tryParse(savedAt);
    if (parsed == null) {
      return null;
    }
    return SpaceDownloadRecord(
      imageId: imageId,
      savedAt: parsed,
      location: (value['location'] as String?) ?? '',
    );
  }
}

/// Remembers which space images were already downloaded.
///
/// Backed by one JSON file per account scope. A database would be overkill for
/// a list this small, and the whole point is surviving a restart, not querying.
class SpaceDownloadLog {
  SpaceDownloadLog({required this.scopeKey});

  final String scopeKey;
  final Map<String, SpaceDownloadRecord> _records =
      <String, SpaceDownloadRecord>{};
  File? _file;
  bool _loaded = false;

  SpaceDownloadRecord? find(String imageId) => _records[imageId];

  int get count => _records.length;

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    // Widget tests have no path_provider implementation; an in-memory log keeps
    // them deterministic and is what they assert on anyway.
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    try {
      final Directory base = await getApplicationSupportDirectory();
      final File file = File(
        '${base.path}${Platform.pathSeparator}space-downloads-$_scopeHash.json',
      );
      _file = file;
      if (!file.existsSync()) {
        return;
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return;
      }
      for (final Object? entry in decoded) {
        final SpaceDownloadRecord? record = SpaceDownloadRecord.fromJson(entry);
        if (record != null) {
          _records[record.imageId] = record;
        }
      }
    } catch (error) {
      debugPrint('[space-downloads] 读取失败：$error');
    }
  }

  /// Records a successful save. Never throws: a bookkeeping failure must not
  /// turn a completed download into an error.
  Future<void> record(String imageId, {required String location}) async {
    await load();
    _records[imageId] = SpaceDownloadRecord(
      imageId: imageId,
      savedAt: DateTime.now(),
      location: location,
    );
    await _flush();
  }

  Future<void> _flush() async {
    final File? file = _file;
    if (file == null) {
      return;
    }
    try {
      final List<Map<String, dynamic>> payload = _records.values
          .map((SpaceDownloadRecord r) => r.toJson())
          .toList();
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (error) {
      debugPrint('[space-downloads] 写入失败：$error');
    }
  }

  /// Stable, filesystem-safe digest of the scope so two accounts do not share
  /// the same file.
  String get _scopeHash {
    int hash = 0;
    for (final int unit in scopeKey.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }
}
