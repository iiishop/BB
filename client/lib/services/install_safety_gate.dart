/// Process-wide admission gate. UI registers each unsaved draft/pending media
/// owner with setBlocker and clears only after explicit discard or durable save.
/// Services use protect() around complete sends/uploads (including all awaits).
/// The UI must disable edits while installing; it must not discard draft state
/// on route disposal to make installation pass.
class InstallSafetyGate {
  final Set<void Function()> _listeners = <void Function()>{};
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  static final InstallSafetyGate instance = InstallSafetyGate();
  final Map<Object, String> _blockers = <Object, String>{};
  int _operations = 0;
  bool _installing = false;
  bool get installing => _installing;
  List<String> get blockers => List<String>.unmodifiable(<String>[
    ..._blockers.values,
    if (_operations > 0) '仍有发送或上传正在进行，请等待完成后再安装。',
  ]);
  void setBlocker(Object owner, String? reason) {
    if (reason == null) {
      _blockers.remove(owner);
    } else {
      _blockers[owner] = reason;
    }
    notifyListeners();
  }

  Future<T> protect<T>(Future<T> Function() operation) async {
    if (_installing) throw StateError('更新安装中，请稍后重试。');
    _operations++;
    notifyListeners();
    try {
      return await operation();
    } finally {
      _operations--;
      notifyListeners();
    }
  }

  /// Synchronous check + lock prevents a new operation entering between them.
  void acquire() {
    if (_installing) throw StateError('已有更新正在安装。');
    if (blockers.isNotEmpty) throw StateError(blockers.join('\n'));
    _installing = true;
    notifyListeners();
  }

  void release() {
    _installing = false;
    notifyListeners();
  }
}
