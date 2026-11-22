import 'dart:io';

import 'package:flutter/foundation.dart';

const maxDownloadConcurrency = 8;

class DownloadLanePreference extends ChangeNotifier {
  DownloadLanePreference._(this._file, this._lanes);

  static const choices = [1, 2, 4, maxDownloadConcurrency];
  final File _file;
  int _lanes;
  int get lanes => _lanes;
  bool _saving = false;
  bool get saving => _saving;

  static Future<DownloadLanePreference> load(Directory directory) async {
    final file = File('${directory.path}/update-download-lanes');
    int? saved;
    try {
      saved = int.tryParse(await file.readAsString());
    } on FileSystemException {
      // Missing or unreadable preferences must not prevent updates.
    }
    return DownloadLanePreference._(
      file,
      choices.contains(saved) ? saved! : maxDownloadConcurrency,
    );
  }

  Future<void> select(int lanes) async {
    if (!choices.contains(lanes)) throw ArgumentError.value(lanes, 'lanes');
    if (_saving || lanes == _lanes) return;
    final previous = _lanes;
    _lanes = lanes;
    _saving = true;
    notifyListeners();
    try {
      await _file.parent.create(recursive: true);
      final temporary = File('${_file.path}.$pid.tmp');
      await temporary.writeAsString('$lanes', flush: true);
      await temporary.rename(_file.path);
    } catch (_) {
      _lanes = previous;
      rethrow;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
