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
      _states[account] = post.authorFollowing;
      changed = true;
    }
    if (changed) {
      _notify();
    }
  }

  /// Loads one target once. Failure leaves the state unknown instead of
  /// rendering a false "not following".
  Future<void> ensureLoaded(String account) async {
    if (isSelf(account) ||
        _states.containsKey(account) ||
        _loading.contains(account)) {
      return;
    }
    _loading.add(account);
    final int revision = _revision;
    try {
      final SpaceFollowState state = await gateway.getFollow(account);
      if (_disposed || revision != _revision) {
        return;
      }
      _states[account] = state.following;
      error = null;
    } catch (_) {
      // Unknown stays unknown; the next page/refresh can retry.
    } finally {
      _loading.remove(account);
      _notify();
    }
  }

  /// Desired-state write. Returns whether the server confirmed it; on an
  /// unknown/failed outcome the state is reconciled with the authoritative
  /// `get_follow` so a failure never becomes a fake success.
  Future<bool> setFollowing(String account, bool desired) async {
    if (isSelf(account) || _writing.contains(account)) {
      return false;
    }
    _writing.add(account);
    error = null;
    _notify();
    try {
      final SpaceFollowState state = await gateway.setFollow(
        account,
        following: desired,
      );
      _states[account] = state.following;
      _revision += 1;
      return true;
    } catch (failure) {
      error = spaceErrorText(failure);
      // Unknown network outcome: reconcile before the user retries, never
      // retry an old intent over a newer one.
      try {
        final SpaceFollowState state = await gateway.getFollow(account);
        _states[account] = state.following;
      } catch (_) {
        // Keep the previous authoritative value; the UI keeps showing it.
      }
      return false;
    } finally {
      _writing.remove(account);
      _notify();
    }
  }

  /// A persisted `follow.changed` event: the viewer's relationship changed
  /// somewhere (this device, another device, another client). Drop cached
  /// states, bump the revision and refetch the accounts we already showed.
  void handleFollowChanged() {
    _revision += 1;
    final List<String> known = _states.keys.toList();
    _states.clear();
    _notify();
    for (final String account in known) {
      unawaited(ensureLoaded(account));
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
