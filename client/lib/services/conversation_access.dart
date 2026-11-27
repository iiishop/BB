/// Pure-Dart access & revocation coordinator for shared conversations.
///
/// Tracks per-(account, conversation) membership epochs so open chat windows,
/// full-screen media viewers, loopback streams, and in-memory/disk caches can
/// invalidate immediately when a user leaves, is removed, or a group is
/// dissolved.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

class ConversationAccessState {
  const ConversationAccessState({
    required this.active,
    required this.epoch,
    this.membershipRevision,
    this.historyThrough,
  });

  final bool active;
  final int epoch;
  final int? membershipRevision;
  final int? historyThrough;
}

typedef ConversationCachePurger = FutureOr<void> Function(
  String account,
  String conversationId,
  Set<String> mediaIds,
);

/// Pure-Dart access state & listener registry shared by services and UI.
class ConversationAccessController {
  final Map<String, _AccessEntry> _entries = <String, _AccessEntry>{};
  final Set<void Function()> _listeners = <void Function()>{};
  final Set<ConversationCachePurger> _purgers = <ConversationCachePurger>{};

  static String scopeKey(String account, String conversationId) =>
      '$account\u0001$conversationId';

  /// Stable, filename-safe tag (`16` lowercase hex chars) scoped to
  /// `(server, account, conversationId)` so disk cache entries for one group
  /// membership never collide with another account, server, or conversation.
  static String diskScopeTag({
    required String server,
    required String account,
    required String conversationId,
  }) {
    final String digest = sha256
        .convert(utf8.encode('$server\u0001$account\u0001$conversationId'))
        .toString();
    return digest.substring(0, 16);
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void registerPurger(ConversationCachePurger purger) => _purgers.add(purger);

  void unregisterPurger(ConversationCachePurger purger) =>
      _purgers.remove(purger);

  ConversationAccessState? stateFor(String account, String conversationId) {
    final _AccessEntry? entry = _entries[scopeKey(account, conversationId)];
    if (entry == null) {
      return null;
    }
    return ConversationAccessState(
      active: entry.active,
      epoch: entry.epoch,
      membershipRevision: entry.membershipRevision,
      historyThrough: entry.historyThrough,
    );
  }

  int epochFor(String account, String conversationId) =>
      _entries[scopeKey(account, conversationId)]?.epoch ?? 0;

  bool isRevoked(String account, String conversationId) {
    final _AccessEntry? entry = _entries[scopeKey(account, conversationId)];
    return entry != null && !entry.active;
  }

  bool isStale(String account, String conversationId, int capturedEpoch) {
    final _AccessEntry? entry = _entries[scopeKey(account, conversationId)];
    if (entry == null) {
      return capturedEpoch != 0;
    }
    return !entry.active || entry.epoch != capturedEpoch;
  }

  void registerMedia(String account, String conversationId, String mediaId) {
    if (account.isEmpty || conversationId.isEmpty || mediaId.isEmpty) {
      return;
    }
    final _AccessEntry entry = _entries.putIfAbsent(
      scopeKey(account, conversationId),
      () => _AccessEntry(),
    );
    entry.mediaIds.add(mediaId);
  }

  /// Marks `(account, conversationId)` revoked, bumps its epoch, notifies open
  /// viewers/windows, and invokes registered memory/disk cache purgers.
  Future<void> revoke(
    String account,
    String conversationId, {
    int? membershipRevision,
  }) async {
    final String key = scopeKey(account, conversationId);
    final _AccessEntry entry = _entries.putIfAbsent(key, () => _AccessEntry());
    if (membershipRevision != null &&
        entry.membershipRevision != null &&
        membershipRevision < entry.membershipRevision!) {
      return;
    }
    entry.active = false;
    entry.epoch += 1;
    if (membershipRevision != null) {
      entry.membershipRevision = membershipRevision;
    }
    final Set<String> mediaIds = Set<String>.from(entry.mediaIds);
    entry.mediaIds.clear();
    _notify();
    for (final ConversationCachePurger purger
        in List<ConversationCachePurger>.of(_purgers)) {
      await purger(account, conversationId, mediaIds);
    }
  }

  /// Records active access (or re-join with a newer membership revision).
  ///
  /// When restoring after a previous revocation or a newer revision, the epoch
  /// advances so any pre-revocation window or viewer stays invalidated.
  void grant(
    String account,
    String conversationId, {
    required int membershipRevision,
    int? historyThrough,
  }) {
    final String key = scopeKey(account, conversationId);
    final _AccessEntry entry = _entries.putIfAbsent(key, () => _AccessEntry());
    if (entry.membershipRevision != null &&
        membershipRevision < entry.membershipRevision!) {
      return;
    }
    final bool revisionAdvanced =
        entry.membershipRevision != null &&
        membershipRevision > entry.membershipRevision!;
    final bool reactivated = !entry.active;
    entry.active = true;
    entry.membershipRevision = membershipRevision;
    if (historyThrough != null) {
      entry.historyThrough = historyThrough;
    }
    if (revisionAdvanced || reactivated) {
      entry.epoch += 1;
      _notify();
    }
  }

  /// Applies a server `conversation.access_changed` event.
  Future<void> applyAccessEvent({
    required String account,
    required String conversationId,
    required bool active,
    required int membershipRevision,
    int? historyThrough,
  }) async {
    if (!active) {
      await revoke(
        account,
        conversationId,
        membershipRevision: membershipRevision,
      );
      return;
    }
    grant(
      account,
      conversationId,
      membershipRevision: membershipRevision,
      historyThrough: historyThrough,
    );
  }

  /// Invalidates all entries for [account] (e.g. logout/account switch).
  Future<void> clearAccount(String account) async {
    final String prefix = '$account\u0001';
    final List<MapEntry<String, _AccessEntry>> targets = _entries.entries
        .where((MapEntry<String, _AccessEntry> e) => e.key.startsWith(prefix))
        .toList();
    for (final MapEntry<String, _AccessEntry> entry in targets) {
      final String conversationId = entry.key.substring(prefix.length);
      await revoke(account, conversationId);
    }
  }

  void _notify() {
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
  }
}

class _AccessEntry {
  bool active = true;
  int epoch = 0;
  int? membershipRevision;
  int? historyThrough;
  final Set<String> mediaIds = <String>{};
}
