import 'dart:async';

import 'package:flutter/widgets.dart';

/// Bridges Flutter's real application lifecycle to the existing client
/// recovery path.
///
/// The shared `EventFeed` also serves the standalone Dart entry, so it keeps no
/// widget binding and no invented lifecycle. Only the GUI host installs this
/// observer; on a real foreground resume it re-arms the same catch-up used by
/// login/restore instead of waiting for the next paused timer tick.
class ForegroundRecovery {
  ForegroundRecovery({required this.onResumed, WidgetsBinding? binding})
    : _binding = binding ?? WidgetsBinding.instance;

  /// The host action to run on resume. Exceptions are swallowed because a
  /// failed catch-up is already retained by the service as its last failure.
  final Future<void> Function() onResumed;

  final WidgetsBinding _binding;
  bool _attached = false;

  late final _ForegroundObserver _observer = _ForegroundObserver(this);

  void attach() {
    if (_attached) return;
    _attached = true;
    _binding.addObserver(_observer);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _binding.removeObserver(_observer);
  }
}

class _ForegroundObserver with WidgetsBindingObserver {
  _ForegroundObserver(this._owner);

  final ForegroundRecovery _owner;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await _owner.onResumed();
    } catch (_) {
      // Scheduled resume work has no caller; never crash the host.
    }
  }
}
