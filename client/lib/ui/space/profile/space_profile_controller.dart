import 'package:flutter/foundation.dart';

import '../../../models/space_models.dart';
import '../space_gateway.dart';
import 'space_profile_gateway.dart';

enum SpaceProfilePhase { loading, ready, empty, error }

/// One author's home-page state.
///
/// Single owner for identity, the visible month directory, the selected month,
/// the month that currently follows the scroll position, pagination and the
/// follow relationship. Every asynchronous response is fenced by a generation
/// counter, so a slow response for the previous month/user can never backfill
/// the current list.
class SpaceProfileController extends ChangeNotifier {
  SpaceProfileController({
    required this.gateway,
    required this.userId,
    required this.viewerAccount,
    this.pageSize = 20,
    this.initialIdentity,
  });

  final SpaceProfileGateway gateway;
  final String userId;
  final String viewerAccount;
  final int pageSize;
  final SpaceProfileIdentity? initialIdentity;

  bool get isSelf => userId == viewerAccount;

  /// The month directory only appears when the server can answer it.
  bool get directoryAvailable => gateway.supportsMonths;

  /// The follow control only appears when the server has the relationship.
  bool get followAvailable => gateway.supportsFollow && !isSelf;

  SpaceProfileIdentity? identity;
  final List<SpaceProfileEntry> entries = <SpaceProfileEntry>[];
  final List<SpaceProfileMonth> months = <SpaceProfileMonth>[];
  SpaceProfilePhase phase = SpaceProfilePhase.loading;
  bool refreshing = false;
  bool loadingMore = false;
  bool followingBusy = false;
  bool monthsLoading = false;
  String? error;
  String? monthsError;
  String? followError;

  /// Authoritative follow state; null when unknown or when viewing yourself.
  bool? following;

  /// The month the current list is anchored at; null means "latest".
  SpaceProfileMonth? anchoredMonth;

  /// The month that follows the scroll position.
  SpaceProfileMonth? visibleMonth;

  bool hasMore = false;
  String? _cursor;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;

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
      _loadFollowing(),
    ]);
  }

  Future<void> refresh() async {
    await Future.wait<void>(<Future<void>>[
      _loadIdentity(),
      _loadMonths(),
      _reloadTimeline(),
      _loadFollowing(),
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

  Future<void> _loadFollowing() async {
    if (!followAvailable) {
      return;
    }
    try {
      final bool result = await gateway.following(userId);
      if (_disposed) {
        return;
      }
      following = result;
      followError = null;
    } catch (_) {
      // Unknown relationship is never rendered as "not following".
      followError = null;
    }
    _notify();
  }

  Future<void> _loadMonths() async {
    if (!directoryAvailable) {
      return;
    }
    monthsLoading = true;
    _notify();
    try {
      final List<SpaceProfileMonth> loaded = await gateway.months(userId);
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
    if (!directoryAvailable || anchoredMonth == month) {
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

  bool get canFollow => followAvailable && following != null;

  Future<bool> setFollowing(bool value) async {
    if (!followAvailable || followingBusy) {
      return false;
    }
    followingBusy = true;
    followError = null;
    _notify();
    try {
      final bool authoritative = await gateway.setFollowing(
        userId: userId,
        following: value,
      );
      if (_disposed) {
        return false;
      }
      following = authoritative;
      return true;
    } catch (exception) {
      if (_disposed) {
        return false;
      }
      // Keep the previous authoritative state: a failed write never becomes a
      // fake "followed" or "unfollowed" label.
      followError = spaceErrorText(exception);
      return false;
    } finally {
      followingBusy = false;
      _notify();
    }
  }

  /// Local-time month of one timeline entry. The card time uses the same zone,
  /// so the archived month and the visible date always agree.
  SpaceProfileMonth? monthOf(String timelineAt) {
    final DateTime? parsed = DateTime.tryParse(timelineAt);
    if (parsed == null) {
      return null;
    }
    final DateTime local = parsed.toLocal();
    return SpaceProfileMonth(year: local.year, month: local.month);
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
