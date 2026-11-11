import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/auth_models.dart';
import 'auth_service.dart';

/// Session presence state shown by the client.
enum HeartbeatPhase {
  /// No signed-in session (or the controller was stopped).
  idle,

  /// Heartbeats are landing.
  online,

  /// At least three consecutive client-side failures; credentials are kept.
  reconnecting,

  /// The server rejected the token (401): the user must sign in again.
  unauthorized,
}

/// 30-second HTTP heartbeat with the STEP-2 offline-banner semantics.
///
/// * a single network failure only counts as one missed beat;
/// * three consecutive misses show the "连接已断开，正在重连" banner but never
///   clear the credential — Android may suspend timers when backgrounded;
/// * a 401 means the session is genuinely gone, so the UI must return to login;
/// * success resets the counter and removes the banner.
class HeartbeatController extends ChangeNotifier {
  HeartbeatController({
    required this.auth,
    this.interval = const Duration(seconds: 30),
    this.missedThreshold = 3,
  });

  final AuthService auth;
  final Duration interval;
  final int missedThreshold;

  Timer? _timer;
  int _missed = 0;
  HeartbeatPhase _phase = HeartbeatPhase.idle;
  bool _disposed = false;

  HeartbeatPhase get phase => _phase;
  int get missedBeats => _missed;
  bool get isReconnecting => _phase == HeartbeatPhase.reconnecting;

  /// Begins the periodic beats for the current session. Safe to call twice.
  void start() {
    if (_timer != null) {
      return;
    }
    if (!auth.session.hasToken) {
      _setPhase(HeartbeatPhase.idle);
      return;
    }
    _setPhase(HeartbeatPhase.online);
    _timer = Timer.periodic(interval, (_) => unawaited(beatNow()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _missed = 0;
    _setPhase(HeartbeatPhase.idle);
  }

  /// Sends one heartbeat now. Exposed so tests and logout paths are explicit.
  Future<void> beatNow() async {
    final String? token = auth.session.tokenForRequest;
    if (token == null) {
      return;
    }
    try {
      await auth.api.heartbeat(token);
      _missed = 0;
      _setPhase(HeartbeatPhase.online);
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        _timer?.cancel();
        _timer = null;
        _setPhase(HeartbeatPhase.unauthorized);
        return;
      }
      _missed += 1;
      if (_missed >= missedThreshold) {
        _setPhase(HeartbeatPhase.reconnecting);
      }
    } catch (_) {
      // Unknown transport errors are treated exactly like a missed beat: keep
      // credentials, count once, let the next tick recover.
      _missed += 1;
      if (_missed >= missedThreshold) {
        _setPhase(HeartbeatPhase.reconnecting);
      }
    }
  }

  void _setPhase(HeartbeatPhase phase) {
    if (_disposed || _phase == phase) {
      return;
    }
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
