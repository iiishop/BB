import 'dart:async';

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
/// Pure Dart on purpose: the standalone `bb_client_api` entry must compile and
/// run without Flutter (`package:flutter/foundation.dart` pulls `dart:ui`).
/// The Flutter UI is just a listener at the boundary — it never owns the timer.
///
/// * a single network failure only counts as one missed beat;
/// * three consecutive misses show the "连接已断开，正在重连" banner but never
///   clear the credential — Android may suspend timers when backgrounded;
/// * a 401 means the session is genuinely gone, so the owner (UI or standalone
///   entry) must clear credentials and return to login;
/// * success resets the counter and removes the banner.
class HeartbeatController {
  HeartbeatController({
    required this.auth,
    this.interval = const Duration(seconds: 30),
    this.missedThreshold = 3,
  }) {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', '心跳间隔必须为正数');
    }
    if (missedThreshold < 1) {
      throw ArgumentError.value(
        missedThreshold,
        'missedThreshold',
        '漏拍阈值必须至少为 1',
      );
    }
  }

  /// Default beat interval from the STEP-2 contract.
  static const Duration defaultInterval = Duration(seconds: 30);

  final AuthService auth;
  final Duration interval;
  final int missedThreshold;

  Timer? _timer;
  int _missed = 0;
  HeartbeatPhase _phase = HeartbeatPhase.idle;
  bool _disposed = false;
  final List<void Function()> _listeners = <void Function()>[];

  HeartbeatPhase get phase => _phase;
  int get missedBeats => _missed;
  bool get isReconnecting => _phase == HeartbeatPhase.reconnecting;
  bool get isRunning => _timer != null;

  /// Registers a change listener. Same shape as Flutter's `Listenable`, but
  /// pure Dart so both the UI and the CLI can consume it.
  void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Begins the periodic beats for the current session. Safe to call twice;
  /// this is also what a successful MCP/local-API login calls.
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
      // A late response from the previous session must not touch the state of a
      // newly logged-in one (QA-465-02).
      if (!_owns(token)) {
        return;
      }
      _missed = 0;
      _setPhase(HeartbeatPhase.online);
    } on AuthFailure catch (failure) {
      if (!_owns(token)) {
        return;
      }
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
      if (!_owns(token)) {
        return;
      }
      // Unknown transport errors are treated exactly like a missed beat: keep
      // credentials, count once, let the next tick recover.
      _missed += 1;
      if (_missed >= missedThreshold) {
        _setPhase(HeartbeatPhase.reconnecting);
      }
    }
  }

  /// True while the request's token is still the session's current token.
  /// Login replaces the token; a pending old request must become a no-op.
  bool _owns(String token) => auth.session.tokenForRequest == token;

  void _setPhase(HeartbeatPhase phase) {
    if (_disposed || _phase == phase) {
      return;
    }
    _phase = phase;
    _notify();
  }

  void _notify() {
    // Copy so a listener may remove itself without mutating iteration.
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _listeners.clear();
  }
}
