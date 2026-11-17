import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/space_models.dart';
import 'space_gateway.dart';

/// Single owner of the viewer's follow relationships for one signed-in account.
///
/// Follow state is shared by the Space feed cards and the author home page, so
/// it cannot live in either page's controller. This store:
/// * seeds from the authoritative `Post.author_following` of any loaded post;
/// * serializes writes per target and reconciles an unknown outcome with
///   `get_follow` instead of guessing or retrying over a newer intent;
/// * bumps [revision] on every relationship change so cursors of the
///   "following" feed are known to be stale;
/// * handles a `follow.changed` replay event by dropping cached states and
///   refetching the accounts it already knew about (another device changed the
///   viewer's relationship).
class SpaceFollowStore extends ChangeNotifier {
  SpaceFollowStore({required this.gateway, required this.viewerAccount});

  final SpaceGateway gateway;
  final String viewerAccount;

  final Map<String, bool> _states = <String, bool>{};
  final Set<String> _loading = <String>{};
  final Set<String> _writing = <String>{};

  /// Targets this session has shown or asked about. Invalidations use this
  /// (not `_states`, which the invalidation itself clears) so a second event
  /// can still request a fresh read.
  final Set<String> _knownTargets = <String>{};

  /// A read was requested while one for the same target was already in
  /// flight. When the in-flight read finishes (possibly discarded as stale),
  /// one fresh read follows, so the target never stays unknown (R2-C).
  final Set<String> _reloadRequested = <String>{};
  int _revision = 0;
  bool _disposed = false;

  /// Increments whenever a relationship may have changed. The following feed
  /// uses it to detect that its cursor is no longer valid.
  int get revision => _revision;

  String? error;

  bool isSelf(String account) => account == viewerAccount;

  /// Known authoritative state; null means "not loaded yet".
  bool? stateFor(String account) {
    if (isSelf(account)) {
      return false;
    }
    return _states[account];
  }

  bool isWriting(String account) => _writing.contains(account);

  /// Seeds authors whose relationship is still unknown from a server page.
  ///
  /// A page snapshot is a read captured before the request returned; it must
  /// never overwrite a relationship this store already knows (a local write or
  /// a reconciled read). Otherwise a feed page that started before a follow
  /// would undo it when its older response lands (Q2). Unknown authors are
  /// filled in; `handleFollowChanged` clears the cache when the server says a
  /// relationship changed elsewhere, so the next page can seed it again.
  void seedFromPosts(Iterable<SpacePost> posts) {
    bool changed = false;
    for (final SpacePost post in posts) {
      final String account = post.author.account;
      if (isSelf(account) || _states.containsKey(account)) {
        continue;
      }
      _knownTargets.add(account);
      _states[account] = post.authorFollowing;
      changed = true;
    }
    if (changed) {
      _notify();
    }
  }

  /// Loads one target once. Failure leaves the state unknown instead of
  /// rendering a false "not following".
  ///
  /// [force] is used by a persisted invalidation: it must reconcile even when
  /// a cached value exists, and it coalesces with an in-flight read by
  /// requesting one follow-up read instead of losing the update (R2-C).
  Future<void> ensureLoaded(String account, {bool force = false}) async {
    if (isSelf(account)) {
      return;
    }
    _knownTargets.add(account);
    if (!force && _states.containsKey(account)) {
      return;
    }
    if (_loading.contains(account)) {
      _reloadRequested.add(account);
      return;
    }
    _loading.add(account);
    final int revision = _revision;
    try {
      final SpaceFollowState state = await gateway.getFollow(account);
      if (_disposed) {
        return;
      }
      // A write or another invalidation happened while this read was in
      // flight: its answer predates the newest known intent, so discard it.
      // Only an unknown target (the invalidation path) needs a replacement
      // read; a successful write already set the authoritative value.
      if (revision != _revision) {
        if (!_states.containsKey(account)) {
          _reloadRequested.add(account);
        }
        return;
      }
      _states[account] = state.following;
      error = null;
    } catch (_) {
      // Unknown stays unknown; the next page/refresh can retry.
    } finally {
      _loading.remove(account);
      final bool reload = _reloadRequested.remove(account);
      _notify();
      if (reload && !_disposed) {
        unawaited(ensureLoaded(account, force: true));
      }
    }
  }

  /// Desired-state write. Returns whether the server confirmed it; on an
  /// unknown/failed outcome the state is reconciled with the authoritative
  /// `get_follow` so a failure never becomes a fake success.
  Future<bool> setFollowing(String account, bool desired) async {
    if (isSelf(account) || _writing.contains(account)) {
      return false;
    }
    _knownTargets.add(account);
    _writing.add(account);
    error = null;
    final bool? previous = _states[account];
    // Any authoritative fact (persisted event, forced read, another result)
    // applied while this request is in flight advances the revision. A result
    // from before that point cannot be attributed to the current truth.
    final int requestRevision = _revision;
    _notify();
    try {
      final SpaceFollowState state = await gateway.setFollow(
        account,
        following: desired,
      );
      await _settleWriteResult(
        account,
        state.following,
        previous,
        requestRevision,
      );
      return true;
    } catch (failure) {
      error = spaceErrorText(failure);
      // Unknown network outcome: reconcile before the user retries, never
      // retry an old intent over a newer one. A reconciliation that discovers
      // a real change is an authoritative relationship change and must advance
      // the revision exactly like a confirmed write (R4): consumers such as the
      // following feed otherwise keep a snapshot that contradicts the receiver.
      try {
        final SpaceFollowState state = await gateway.getFollow(account);
        await _settleWriteResult(
          account,
          state.following,
          previous,
          requestRevision,
        );
      } catch (_) {
        // Keep the previous authoritative value; the UI keeps showing it.
      }
      return false;
    } finally {
      _writing.remove(account);
      _notify();
    }
  }

  /// Applies a write/reconciliation result only when no newer authoritative
  /// fact landed while the request (or its reconciliation) was in flight.
  ///
  /// A result delivered after such a fact cannot be ordered against it: the
  /// request may have been accepted before the newer fact (stale, must not
  /// roll back) or after it (the receiver's current truth, must still apply).
  /// Reading the receiver again after the result arrives resolves both cases
  /// without treating every late result as stale (R5).
  Future<void> _settleWriteResult(
    String account,
    bool following,
    bool? previous,
    int requestRevision,
  ) async {
    if (_revision == requestRevision) {
      _applyAuthoritative(account, following, previous);
      return;
    }
    await _readLatestAuthoritative(account);
  }

  /// Reads the receiver's current relationship after a result whose ordering
  /// is unknown. The read is fenced like every other authoritative read: if a
  /// newer fact lands while it is in flight, retry instead of applying a read
  /// that is already stale. The write's failure message is preserved.
  Future<void> _readLatestAuthoritative(String account) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      final int revision = _revision;
      try {
        final SpaceFollowState state = await gateway.getFollow(account);
        if (_disposed) {
          return;
        }
        if (revision != _revision) {
          continue;
        }
        final bool? before = _states[account];
        _applyAuthoritative(account, state.following, before);
        return;
      } catch (_) {
        // Keep the last known relationship and the existing error surface.
        return;
      }
    }
  }

  /// Applies an authoritative relationship result from any path (confirmed
  /// write, reconciliation after an unknown outcome, or a read). Any actual
  /// change advances the revision so every consumer invalidates its snapshot;
  /// an unchanged duplicate remains a true no-op.
  void _applyAuthoritative(String account, bool following, bool? previous) {
    _states[account] = following;
    if (previous == null || previous != following) {
      _revision += 1;
    }
  }

  /// A persisted `follow.changed` event: the viewer's relationship changed
  /// somewhere (this device, another device, another client). Drop cached
  /// states, bump the revision and refetch the accounts we already showed.
  void handleFollowChanged() {
    _revision += 1;
    // `_knownTargets` survives the clear, so two invalidations in a row still
    // reconcile the same target even while the first read is in flight (R2-C).
    final List<String> known = _knownTargets.toList();
    _states.clear();
    _notify();
    for (final String account in known) {
      unawaited(ensureLoaded(account, force: true));
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
