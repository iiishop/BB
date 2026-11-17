import 'package:flutter/foundation.dart';

import '../../../models/space_models.dart';
import '../space_gateway.dart';
import 'space_profile_gateway.dart';

enum SpaceProfilePhase { loading, ready, empty, error }

/// One author's home-page state.
///
/// Single owner for identity, the visible month directory, the selected month,
/// the month that currently follows the scroll position and pagination. Follow
/// relationships live in the shared `SpaceFollowStore`, not here: the same
/// state is shown on feed cards and the home page. Every asynchronous response
/// is fenced by a generation counter, so a slow response for the previous
/// month/user can never backfill the current list.
class SpaceProfileController extends ChangeNotifier {
  SpaceProfileController({
    required this.gateway,
    required this.space,
    required this.userId,
    required this.viewerAccount,
    required this.displayOffsetMinutes,
    this.pageSize = 20,
    this.initialIdentity,
  });

  final SpaceProfileGateway gateway;

  /// Same shared Space gateway the feed uses; card actions (like/delete) must
  /// not add a second protocol.
  final SpaceGateway space;

  final String userId;
  final String viewerAccount;

  /// Fixed browsing offset in minutes east of UTC, captured once when this
  /// home page session opens. The directory and every card date use it; an
  /// independently changing local offset is never consulted.
  final int displayOffsetMinutes;

  final int pageSize;
  final SpaceProfileIdentity? initialIdentity;

  bool get isSelf => userId == viewerAccount;

  SpaceProfileIdentity? identity;
  final List<SpaceProfileEntry> entries = <SpaceProfileEntry>[];
  final List<SpaceProfileMonth> months = <SpaceProfileMonth>[];
  SpaceProfilePhase phase = SpaceProfilePhase.loading;
  bool refreshing = false;
  bool loadingMore = false;
  bool monthsLoading = false;
  String? error;
  String? monthsError;
  String? actionError;

  /// The month the current list is anchored at; null means "latest".
  SpaceProfileMonth? anchoredMonth;

  /// The month that follows the scroll position.
  SpaceProfileMonth? visibleMonth;

  bool hasMore = false;
  String? _cursor;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;
  final Set<String> _likePending = <String>{};

  bool get atLatest => anchoredMonth == null;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final SpaceProfileIdentity? seeded = initialIdentity;
    if (seeded != null) {
      identity = seeded;
    }
    await Future.wait<void>(<Future<void>>[
      _loadIdentity(),
      _loadMonths(),
      _reloadTimeline(),
    ]);
  }

  Future<void> refresh() async {
    await Future.wait<void>(<Future<void>>[
      _loadIdentity(),
      _loadMonths(),
      _reloadTimeline(),
    ]);
  }

  Future<void> _loadIdentity() async {
    if (identity != null) {
      return;
    }
    try {
      final SpaceProfileIdentity loaded = await gateway.identity(userId);
      if (_disposed) {
        return;
      }
      identity = loaded;
      _notify();
    } catch (_) {
      // The timeline author is a valid fallback for accounts without an
      // uploaded profile; a missing profile must not fail the whole page.
    }
  }

  Future<void> _loadMonths() async {
    monthsLoading = true;
    _notify();
    try {
      final List<SpaceProfileMonth> loaded = await gateway.months(
        userId,
        timezoneOffsetMinutes: displayOffsetMinutes,
      );
      if (_disposed) {
        return;
      }
      months
        ..clear()
        ..addAll(loaded)
        ..sort((SpaceProfileMonth a, SpaceProfileMonth b) => b.compareTo(a));
      monthsError = null;
    } catch (exception) {
      if (_disposed) {
        return;
      }
      monthsError = spaceErrorText(exception);
    } finally {
      monthsLoading = false;
      _notify();
    }
  }

  /// Loads the first page for the current anchor.
  Future<void> _reloadTimeline() async {
    final int generation = ++_generation;
    refreshing = entries.isNotEmpty;
    // A stale load-more cannot reset this flag itself (its generation no
    // longer matches), so a new reload owns the reset.
    loadingMore = false;
    if (entries.isEmpty) {
      phase = SpaceProfilePhase.loading;
    }
    error = null;
    hasMore = false;
    _cursor = null;
    _notify();
    try {
      final SpaceProfileTimelinePage page = await gateway.timeline(
        userId: userId,
        timezoneOffsetMinutes: displayOffsetMinutes,
        month: anchoredMonth,
        limit: pageSize,
      );
      if (_disposed || generation != _generation) {
        return;
      }
      entries
        ..clear()
        ..addAll(page.items);
      _cursor = page.nextCursor;
      hasMore = page.hasMore;
      phase = entries.isEmpty
          ? SpaceProfilePhase.empty
          : SpaceProfilePhase.ready;
      _adoptFirstIdentity();
      visibleMonth =
          anchoredMonth ??
          (entries.isEmpty ? null : monthOf(entries.first.timelineAt));
      error = null;
    } catch (exception) {
      if (_disposed || generation != _generation) {
        return;
      }
      error = spaceErrorText(exception);
      if (entries.isEmpty) {
        phase = SpaceProfilePhase.error;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        refreshing = false;
        _notify();
      }
    }
  }

  Future<void> loadMore() async {
    if (loadingMore || !hasMore || _cursor == null || refreshing) {
      return;
    }
    final int generation = _generation;
    loadingMore = true;
    _notify();
    try {
      final SpaceProfileTimelinePage page = await gateway.timeline(
        userId: userId,
        timezoneOffsetMinutes: displayOffsetMinutes,
        cursor: _cursor,
        limit: pageSize,
      );
      if (_disposed || generation != _generation) {
        return;
      }
      final Set<String> seen = <String>{
        for (final SpaceProfileEntry entry in entries) entry.post.postId,
      };
      for (final SpaceProfileEntry entry in page.items) {
        // A cursor must never duplicate a row; drop an overlap defensively so a
        // server bug cannot render the same post twice.
        if (seen.add(entry.post.postId)) {
          entries.add(entry);
        }
      }
      _cursor = page.nextCursor;
      hasMore = page.hasMore;
      phase = entries.isEmpty
          ? SpaceProfilePhase.empty
          : SpaceProfilePhase.ready;
    } catch (exception) {
      if (_disposed || generation != _generation) {
        return;
      }
      error = spaceErrorText(exception);
    } finally {
      if (!_disposed && generation == _generation) {
        loadingMore = false;
        _notify();
      }
    }
  }

  /// Jumps the list to [month]'s newest visible entry; older months stay
  /// reachable by scrolling, exactly like the product specification.
  Future<void> jumpToMonth(SpaceProfileMonth month) async {
    if (anchoredMonth == month) {
      return;
    }
    anchoredMonth = month;
    visibleMonth = month;
    entries.clear();
    await _reloadTimeline();
  }

  Future<void> backToLatest() async {
    if (anchoredMonth == null) {
      return;
    }
    anchoredMonth = null;
    visibleMonth = null;
    entries.clear();
    await _reloadTimeline();
  }

  void reportVisibleMonth(SpaceProfileMonth? month) {
    if (month == null) {
      return;
    }
    // The explicit selection keeps its own marker; this only moves the
    // "currently on screen" highlight.
    if (visibleMonth == month) {
      return;
    }
    visibleMonth = month;
    _notify();
  }

  /// Feed-style like from a home-page card. Optimistic on the card snapshot,
  /// reverted from the live entry on failure; the server stays authoritative.
  Future<void> toggleLike(SpacePost post) async {
    if (_likePending.contains(post.postId)) {
      return;
    }
    final int index = entries.indexWhere(
      (SpaceProfileEntry e) => e.post.postId == post.postId,
    );
    if (index < 0) {
      return;
    }
    final SpacePost original = entries[index].post;
    final bool desired = !original.liked;
    _likePending.add(post.postId);
    entries[index] = SpaceProfileEntry(
      post: _withLike(original, desired),
      timelineAt: entries[index].timelineAt,
    );
    actionError = null;
    _notify();
    try {
      await space.setLike(
        post.postId,
        liked: desired,
        operationId:
            'space-like-${DateTime.now().microsecondsSinceEpoch}-${post.postId}',
      );
    } catch (failure) {
      final int current = entries.indexWhere(
        (SpaceProfileEntry e) => e.post.postId == post.postId,
      );
      if (current >= 0) {
        entries[current] = SpaceProfileEntry(
          post: _withLikeFields(
            entries[current].post,
            liked: original.liked,
            likeCount: original.likeCount,
          ),
          timelineAt: entries[current].timelineAt,
        );
      }
      actionError = spaceErrorText(failure);
    } finally {
      _likePending.remove(post.postId);
      _notify();
    }
  }

  Future<bool> deletePost(SpacePost post) async {
    try {
      await space.deletePost(
        post.postId,
        operationId: 'space-del-post-${DateTime.now().microsecondsSinceEpoch}',
      );
      removePost(post.postId);
      // A deleted single-entry month must disappear from the directory; this
      // is a small read, not a client-side scan of all history.
      await _loadMonths();
      return true;
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
      return false;
    }
  }

  void replacePost(SpacePost post) {
    final int index = entries.indexWhere(
      (SpaceProfileEntry e) => e.post.postId == post.postId,
    );
    if (index < 0) {
      return;
    }
    entries[index] = SpaceProfileEntry(
      post: post,
      timelineAt: entries[index].timelineAt,
    );
    _notify();
  }

  void removePost(String postId) {
    final int before = entries.length;
    entries.removeWhere((SpaceProfileEntry e) => e.post.postId == postId);
    if (entries.length == before) {
      return;
    }
    if (entries.isEmpty && phase == SpaceProfilePhase.ready) {
      phase = SpaceProfilePhase.empty;
    }
    _notify();
  }

  /// Local-time month of one timeline entry under the session's fixed offset.
  /// The card time uses the same offset, so the archived month and the visible
  /// date always agree.
  SpaceProfileMonth? monthOf(String timelineAt) {
    final DateTime? parsed = DateTime.tryParse(timelineAt);
    if (parsed == null) {
      return null;
    }
    final DateTime wallClock = parsed.toUtc().add(
      Duration(minutes: displayOffsetMinutes),
    );
    return SpaceProfileMonth(year: wallClock.year, month: wallClock.month);
  }

  bool isSelected(SpaceProfileMonth month) => anchoredMonth == month;

  SpaceMonthState monthState(SpaceProfileMonth month) {
    if (anchoredMonth == month) {
      return SpaceMonthState.selected;
    }
    if (visibleMonth == month) {
      return SpaceMonthState.visible;
    }
    return SpaceMonthState.idle;
  }

  SpacePost _withLike(SpacePost original, bool desired) {
    final int delta = desired == original.liked ? 0 : (desired ? 1 : -1);
    return _withLikeFields(
      original,
      liked: desired,
      likeCount: original.likeCount + delta,
    );
  }

  SpacePost _withLikeFields(
    SpacePost target, {
    required bool liked,
    required int likeCount,
  }) {
    return SpacePost(
      postId: target.postId,
      author: target.author,
      authorFollowing: target.authorFollowing,
      createdAt: target.createdAt,
      text: target.text,
      images: target.images,
      reference: target.reference,
      liked: liked,
      read: target.read,
      likeCount: likeCount,
      commentCount: target.commentCount,
      rootCount: target.rootCount,
      repostCount: target.repostCount,
      viewCount: target.viewCount,
      canDelete: target.canDelete,
      canListVisitors: target.canListVisitors,
      previewComments: target.previewComments,
      remainingRoots: target.remainingRoots,
    );
  }

  void _adoptFirstIdentity() {
    if (identity != null || entries.isEmpty) {
      return;
    }
    final SpaceAuthor author = entries.first.post.author;
    identity = SpaceProfileIdentity(
      account: author.account,
      username: author.username,
      avatarUrl: author.avatarUrl,
    );
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

enum SpaceMonthState { idle, visible, selected }
