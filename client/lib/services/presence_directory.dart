import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'chat_service.dart';

/// The one source an open conversation and the user list read peer presence
/// from.
///
/// Presence is not pushed: `GET /users` reports `online` only while a session
/// heartbeated within the server's 90s freshness window. This directory keeps
/// the last confirmed value per account, refreshes only the accounts that are
/// currently on screen on one shared interval, and lets the list adopt its own
/// fresher page so both surfaces cannot disagree.
///
/// Reads can complete out of order: a targeted read held by a slow response
/// may return after a newer list page already confirmed a different value.
/// Every read therefore reserves a ticket with [beginObservation] when it
/// starts, and only the ticket newer than the last applied one for that account
/// may write. Leaving a conversation invalidates its in-flight reads, so a
/// response captured for the closed page cannot overwrite the reopened one.
///
/// A failed refresh keeps the last confirmed value — an unreachable server
/// never turns a peer offline — and a response that arrives after [dispose] is
/// dropped instead of notifying a destroyed page.
class PresenceDirectory extends ChangeNotifier {
  PresenceDirectory({
    required this.chat,
    this.refreshInterval = const Duration(seconds: 30),
  });

  final ChatService chat;

  /// Matches the user list's silent refresh so the visible update bound is one
  /// interval; it is a poll, not a push.
  final Duration refreshInterval;

  final Map<String, Presence> _values = <String, Presence>{};

  /// Highest observation ticket applied per account. Tickets increase when a
  /// read starts, so a response that started earlier can never win later.
  final Map<String, int> _lastObservation = <String, int>{};
  final Set<String> _watched = <String>{};
  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;
  int _observationSeq = 0;

  /// Last confirmed presence; null means "not known yet", which is not the
  /// same as offline.
  Presence? valueFor(String account) => _values[account];

  /// Reserves the ordering ticket of a presence read that starts now.
  ///
  /// Callers that await an HTTP read pass this ticket back to [seed] (or it is
  /// taken internally by [refresh]) when the response arrives. A read that
  /// started earlier than one already applied is dropped.
  int beginObservation() => ++_observationSeq;

  /// Adopts presence the caller already fetched (the user list page), so a row
  /// and an open header never show two different values.
  ///
  /// [observation] is the ticket taken when that list request started; omitting
  /// it means "this page started now". A page older than an already applied
  /// targeted read is dropped.
  void seed(Iterable<ChatUser> users, {int? observation}) {
    if (_disposed) {
      return;
    }
    final int ticket = observation ?? beginObservation();
    bool changed = false;
    for (final ChatUser user in users) {
      if (_accept(user.account, ticket) &&
          _values[user.account] != user.presence) {
        _values[user.account] = user.presence;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  /// Records [ticket] as the newest observation for [account] when it wins.
  /// Equal or older tickets are stale and must not write.
  bool _accept(String account, int ticket) {
    if (ticket <= (_lastObservation[account] ?? 0)) {
      return false;
    }
    _lastObservation[account] = ticket;
    return true;
  }

  /// Starts refreshing [account] on the shared timer. The first read happens
  /// immediately so a just-opened conversation does not wait a full interval.
  void watch(String account) {
    if (_disposed) {
      return;
    }
    final bool added = _watched.add(account);
    _timer ??= Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
    if (added) {
      unawaited(refresh());
    }
  }

  /// Stops refreshing [account]; the timer only runs while something watches.
  ///
  /// A read that started before the page left is invalidated here: its ticket
  /// is below the new one, so releasing it later cannot overwrite the value a
  /// reopened conversation may already be showing.
  void unwatch(String account) {
    if (_disposed) {
      return;
    }
    _watched.remove(account);
    _lastObservation[account] = ++_observationSeq;
    if (_watched.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Refreshes every watched account, coalescing overlapping ticks.
  Future<void> refresh() async {
    if (_disposed || _refreshing) {
      return;
    }
    _refreshing = true;
    try {
      bool changed = false;
      for (final String account in _watched.toList()) {
        final int ticket = beginObservation();
        try {
          final Presence? presence = await chat.presenceOf(account);
          if (_disposed) {
            return;
          }
          if (presence != null &&
              _accept(account, ticket) &&
              _values[account] != presence) {
            _values[account] = presence;
            changed = true;
          }
        } on AuthFailure {
          // Session owners handle 401/identity changes; presence keeps the
          // last confirmed value instead of inventing offline.
        } catch (_) {
          // Network/timeout: keep the last confirmed value and retry next tick.
        }
      }
      if (changed && !_disposed) {
        notifyListeners();
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _watched.clear();
    super.dispose();
  }
}
