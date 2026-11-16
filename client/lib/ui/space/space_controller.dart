import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/auth_models.dart';
import '../../models/space_models.dart';
import 'space_detail_controller.dart';
import 'space_gateway.dart';
import 'space_image_viewer.dart';
import 'space_invalidation.dart';
import 'space_local_store.dart';

enum SpaceSection { feed, notifications, drafts }

/// Feed, notification and draft state for one account/server pair.
///
/// Detail visits live in [SpaceDetailController] so a resize, a comment
/// refresh or a reference hop cannot mint a second visit ID. A single HTTP
/// event replay loop applies invalidations; no per-post polling exists.
class SpaceController extends ChangeNotifier {
  SpaceController({
    required this.gateway,
    required this.store,
    SpaceImageLoader? images,
    this.onSessionExpired,
    this.pollInterval = const Duration(seconds: 20),
    this.autoPoll = true,
  }) : images = images ?? SpaceImageLoader(gateway);

  final SpaceGateway gateway;
  final SpaceLocalStore store;
  final SpaceImageLoader images;
  final VoidCallback? onSessionExpired;
  final Duration? pollInterval;
  final bool autoPoll;

  SpacePhase phase = SpacePhase.loading;
  final List<SpacePost> posts = <SpacePost>[];
  String? nextCursor;
  bool hasMore = false;
  bool refreshing = false;
  bool loadingMore = false;
  String? feedError;
  bool offline = false;
  bool unsupportedServer = false;

  int unreadNotifications = 0;
  int unreadPosts = 0;

  SpaceSection section = SpaceSection.feed;

  int pendingNewPosts = 0;
  List<SpacePost> _pendingPage = <SpacePost>[];

  // Details, in local back-history order.
  final Map<String, SpaceDetailController> _details =
      <String, SpaceDetailController>{};
  final List<String> _detailStack = <String>[];
  int _visitCounter = 0;

  // Notifications.
  SpacePhase notificationsPhase = SpacePhase.loading;
  final List<SpaceNotification> notifications = <SpaceNotification>[];
  String? notificationsCursor;
  bool notificationsHasMore = false;
  String? notificationsError;
  bool notificationsOffline = false;
  bool acking = false;

  // Drafts.
  final List<SpaceDraft> drafts = <SpaceDraft>[];
  bool draftsLoading = false;
  String? draftsError;

  int? _eventCursor;
  bool _eventsReady = false;
  /// Posts whose deletion was already observed. Late responses captured before
  /// that point must not reinsert them or restore their reference snapshots.
  final Set<String> _tombstones = <String>{};
  bool _polling = false;
  Timer? _timer;
  bool _disposed = false;
  bool _loadedOnce = false;
  final Set<int> _seenEvents = <int>{};

  bool get detailOpen => _detailStack.isNotEmpty;
  String? get selectedPostId => _detailStack.isEmpty ? null : _detailStack.last;
  SpaceDetailController? get detail =>
      selectedPostId == null ? null : _details[selectedPostId];
  List<String> get detailHistory => List<String>.unmodifiable(_detailStack);

  bool get hasUnseenNewPosts => pendingNewPosts > 0;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> start() async {
    if (_loadedOnce) {
      return;
    }
    _loadedOnce = true;
    await Future.wait<void>(<Future<void>>[
      _loadOverview(),
      _loadFeedFirst(explicit: true),
      loadDrafts(),
    ]);
    _startTimer();
  }

  Future<void> _loadOverview() async {
    try {
      final SpaceOverview overview = await gateway.overview();
      unreadNotifications = overview.unreadNotifications;
      unreadPosts = overview.unreadPosts;
      if (!_eventsReady) {
        _eventCursor = overview.latestEventId;
        _eventsReady = true;
      }
      unsupportedServer = false;
      _notify();
    } on AuthFailure catch (failure) {
      if (isSpaceUnauthorized(failure)) {
        onSessionExpired?.call();
      } else if (isSpaceUnsupported(failure)) {
        unsupportedServer = true;
        _notify();
      }
    } catch (_) {
      // The feed carries the actionable error; the badge simply stays unknown.
    }
  }

  Future<void> _loadFeedFirst({required bool explicit}) async {
    try {
      final SpacePagePost page = await gateway.listPosts(limit: 20);
      final List<SpacePost> admitted = _admitIncoming(page.items);
      final bool wasOffline = offline;
      if (explicit) {
        posts
          ..clear()
          ..addAll(admitted);
        pendingNewPosts = 0;
        _pendingPage = <SpacePost>[];
      } else {
        final Set<String> known = posts.map((SpacePost p) => p.postId).toSet();
        final List<SpacePost> fresh = admitted
            .where((SpacePost p) => !known.contains(p.postId))
            .toList();
        if (fresh.isNotEmpty) {
          _pendingPage = fresh;
          pendingNewPosts = fresh.length;
          _notify();
          return;
        }
      }
      nextCursor = page.nextCursor;
      hasMore = page.hasMore;
      phase = posts.isEmpty ? SpacePhase.empty : SpacePhase.ready;
      feedError = null;
      offline = false;
      unsupportedServer = false;
      _notify();
      if (wasOffline) {
        unawaited(_reconnectReplay());
      }
    } on AuthFailure catch (failure) {
      if (isSpaceUnauthorized(failure)) {
        onSessionExpired?.call();
        phase = SpacePhase.error;
        feedError = '登录已失效，请重新登录';
      } else if (isSpaceUnsupported(failure)) {
        unsupportedServer = true;
        phase = SpacePhase.error;
        feedError = '当前服务器还不支持 BB 空间';
      } else {
        offline = isSpaceOffline(failure);
        phase = posts.isEmpty ? SpacePhase.error : phase;
        feedError = spaceErrorText(failure);
      }
      _notify();
    } catch (failure) {
      offline = isSpaceOffline(failure);
      phase = posts.isEmpty ? SpacePhase.error : phase;
      feedError = spaceErrorText(failure);
      _notify();
    }
  }

  Future<void> refresh({bool explicit = true}) async {
    if (refreshing) {
      return;
    }
    refreshing = true;
    _notify();
    try {
      if (_eventsReady) {
        await pollEventsOnce();
      }
      await Future.wait<void>(<Future<void>>[
        _loadFeedFirst(explicit: explicit),
        _loadOverview(),
      ]);
    } finally {
      refreshing = false;
      _notify();
    }
  }

  Future<void> loadMore() async {
    if (loadingMore || !hasMore) {
      return;
    }
    loadingMore = true;
    _notify();
    try {
      final SpacePagePost page = await gateway.listPosts(
        cursor: nextCursor,
        limit: 20,
      );
      final Set<String> seen = posts.map((SpacePost p) => p.postId).toSet();
      posts.addAll(
        _admitIncoming(page.items).where((SpacePost p) => seen.add(p.postId)),
      );
      nextCursor = page.nextCursor;
      hasMore = page.hasMore;
      offline = false;
      feedError = null;
    } catch (failure) {
      offline = isSpaceOffline(failure);
      feedError = spaceErrorText(failure);
    } finally {
      loadingMore = false;
      _notify();
    }
  }

  /// Applies posts discovered by a background comparison. Used only by the
  /// explicit "有新说说" affordance so reading position never jumps.
  void applyPendingPosts() {
    if (_pendingPage.isEmpty) {
      return;
    }
    final List<SpacePost> admitted = _admitIncoming(_pendingPage);
    if (admitted.isEmpty) {
      _pendingPage = <SpacePost>[];
      pendingNewPosts = 0;
      _notify();
      return;
    }
    final Set<String> incoming = admitted.map((SpacePost p) => p.postId).toSet();
    posts
      ..removeWhere((SpacePost p) => incoming.contains(p.postId))
      ..insertAll(0, admitted);
    _pendingPage = <SpacePost>[];
    pendingNewPosts = 0;
    phase = posts.isEmpty ? SpacePhase.empty : SpacePhase.ready;
    _notify();
  }

  /// Feed-card like without opening a detail visit. The card state updates
  /// optimistically and reverts on failure; the server still checks permission
  /// and deduplicates membership.
  Future<void> togglePostLike(SpacePost post) async {
    final bool desired = !post.liked;
    final int index = posts.indexWhere(
      (SpacePost p) => p.postId == post.postId,
    );
    if (index < 0) {
      return;
    }
    final SpacePost original = posts[index];
    posts[index] = _withLike(original, desired);
    _notify();
    try {
      await gateway.setLike(
        post.postId,
        liked: desired,
        operationId:
            'space-like-${DateTime.now().microsecondsSinceEpoch}-${post.postId}',
      );
      feedError = null;
    } catch (failure) {
      final int current = posts.indexWhere(
        (SpacePost p) => p.postId == post.postId,
      );
      if (current >= 0) {
        posts[current] = original;
      }
      feedError = spaceErrorText(failure);
    }
    _notify();
  }

  SpacePost _withLike(SpacePost original, bool desired) {
    final int delta = desired == original.liked ? 0 : (desired ? 1 : -1);
    return SpacePost(
      postId: original.postId,
      author: original.author,
      createdAt: original.createdAt,
      text: original.text,
      images: original.images,
      reference: original.reference,
      liked: desired,
      read: original.read,
      likeCount: original.likeCount + delta,
      commentCount: original.commentCount,
      rootCount: original.rootCount,
      repostCount: original.repostCount,
      viewCount: original.viewCount,
      canDelete: original.canDelete,
      canListVisitors: original.canListVisitors,
      previewComments: original.previewComments,
      remainingRoots: original.remainingRoots,
    );
  }

  Future<bool> deletePost(SpacePost post) async {
    try {
      await gateway.deletePost(
        post.postId,
        operationId: 'space-del-post-${DateTime.now().microsecondsSinceEpoch}',
      );
      _handlePostDeleted(post.postId);
      return true;
    } catch (failure) {
      feedError = spaceErrorText(failure);
      _notify();
      return false;
    }
  }

  Future<SpaceDetailController?> openPost(
    String postId, {
    String? focusCommentId,
    bool push = false,
  }) async {
    if (!push) {
      _clearStack();
    }
    SpaceDetailController? controller = _details[postId];
    if (controller == null) {
      controller = SpaceDetailController(
        gateway: gateway,
        store: store,
        postId: postId,
        visitId: _newVisitId(),
        focusCommentId: focusCommentId,
        onSessionExpired: onSessionExpired,
        onPostDeleted: _handlePostDeleted,
        isTombstoned: _isTombstoned,
      );
      _details[postId] = controller;
    }
    _detailStack.add(postId);
    _notify();
    await controller.load();
    return controller;
  }

  Future<SpaceDetailController?> openReference(String postId) =>
      openPost(postId, push: true);

  void backDetail() {
    if (_detailStack.isEmpty) {
      return;
    }
    _detailStack.removeLast();
    _disposeUnusedDetails();
    _notify();
  }

  void closeDetail() {
    _clearStack();
    _notify();
  }

  void _clearStack() {
    _detailStack.clear();
    for (final SpaceDetailController controller in _details.values) {
      controller.dispose();
    }
    _details.clear();
  }

  void _disposeUnusedDetails() {
    final Set<String> used = _detailStack.toSet();
    final List<String> stale = _details.keys
        .where((String id) => !used.contains(id))
        .toList();
    for (final String id in stale) {
      _details.remove(id)?.dispose();
    }
  }

  void _handlePostDeleted(String postId) {
    _tombstones.add(postId);
    posts.removeWhere((SpacePost p) => p.postId == postId);
    _pendingPage.removeWhere((SpacePost p) => p.postId == postId);
    _scrubReferencesTo(postId);
    if (posts.isEmpty && phase == SpacePhase.ready) {
      phase = SpacePhase.empty;
    }
    _notify();
  }

  bool _isTombstoned(String postId) => _tombstones.contains(postId);

  SpacePost _scrubIncoming(SpacePost post) {
    final SpaceReference? reference = post.reference;
    if (reference == null || !_tombstones.contains(reference.postId)) {
      return post;
    }
    return spacePostWithScrubbedReference(post, reference.postId);
  }

  List<SpacePost> _admitIncoming(Iterable<SpacePost> items) {
    return <SpacePost>[
      for (final SpacePost post in items)
        if (!_tombstones.contains(post.postId)) _scrubIncoming(post),
    ];
  }

  /// A deleted post can still be embedded as a reference card in other loaded
  /// posts and open details. Reduce every cached snapshot to the deleted
  /// placeholder and drop the source image from the shared cache.
  void _scrubReferencesTo(String postId) {
    void scrub(List<SpacePost> list) {
      for (int i = 0; i < list.length; i++) {
        final SpacePost post = list[i];
        final SpaceReference? reference = post.reference;
        if (reference == null || reference.postId != postId) {
          continue;
        }
        final SpaceImage? image = reference.image;
        if (image != null) {
          images.invalidateImage(image.imageId);
        }
        list[i] = spacePostWithScrubbedReference(post, postId);
      }
    }

    scrub(posts);
    scrub(_pendingPage);
    for (final SpaceDetailController controller in _details.values) {
      controller.onReferenceDeletedEvent(postId);
    }
  }

  String _newVisitId() {
    _visitCounter += 1;
    return 'visit-${DateTime.now().microsecondsSinceEpoch}-$_visitCounter';
  }

  void showFeed() {
    section = SpaceSection.feed;
    _notify();
  }

  void showNotifications() {
    section = SpaceSection.notifications;
    _notify();
    unawaited(loadNotifications(reset: true));
  }

  void showDrafts() {
    section = SpaceSection.drafts;
    _notify();
    unawaited(loadDrafts());
  }

  Future<void> loadNotifications({
    bool reset = false,
    bool silent = false,
  }) async {
    if (!silent) {
      notificationsPhase = SpacePhase.loading;
      notificationsError = null;
      _notify();
    }
    try {
      final SpacePageNotification page = await gateway.listNotifications(
        cursor: reset ? null : notificationsCursor,
        limit: 20,
      );
      if (reset || notifications.isEmpty) {
        notifications
          ..clear()
          ..addAll(page.items);
      } else {
        final Set<String> seen = notifications
            .map((SpaceNotification n) => n.notificationId)
            .toSet();
        notifications.addAll(
          page.items.where((SpaceNotification n) => seen.add(n.notificationId)),
        );
      }
      notificationsCursor = page.nextCursor;
      notificationsHasMore = page.hasMore;
      notificationsPhase = notifications.isEmpty
          ? SpacePhase.empty
          : SpacePhase.ready;
      notificationsError = null;
      notificationsOffline = false;
      _notify();
    } on AuthFailure catch (failure) {
      if (isSpaceUnauthorized(failure)) {
        onSessionExpired?.call();
      }
      notificationsOffline = isSpaceOffline(failure);
      notificationsPhase = notifications.isEmpty
          ? SpacePhase.error
          : notificationsPhase;
      notificationsError = spaceErrorText(failure);
      _notify();
    } catch (failure) {
      notificationsOffline = isSpaceOffline(failure);
      notificationsPhase = notifications.isEmpty
          ? SpacePhase.error
          : notificationsPhase;
      notificationsError = spaceErrorText(failure);
      _notify();
    }
  }

  Future<void> loadMoreNotifications() async {
    if (!notificationsHasMore || notificationsPhase == SpacePhase.loading) {
      return;
    }
    await loadNotifications(silent: true);
  }

  Future<bool> openNotification(SpaceNotification notification) async {
    if (notification.deleted || !notification.accessible) {
      await ackNotification(notification);
      return false;
    }
    final String postId = notification.targetPostId.isNotEmpty
        ? notification.targetPostId
        : notification.postId;
    final String? focus =
        (notification.kind == 'comment' || notification.kind == 'reply')
        ? notification.commentId
        : null;
    await openPost(postId, focusCommentId: focus);
    await ackNotification(notification);
    return true;
  }

  Future<bool> ackNotification(SpaceNotification notification) async {
    if (!notification.unread) {
      return true;
    }
    return _ack(<SpaceNotification>[notification]);
  }

  Future<void> ackAllLoaded() async {
    final List<SpaceNotification> unread = notifications
        .where((SpaceNotification n) => n.unread)
        .toList();
    if (unread.isEmpty) {
      return;
    }
    await _ack(unread);
  }

  Future<bool> _ack(List<SpaceNotification> items) async {
    if (acking) {
      return false;
    }
    acking = true;
    _notify();
    final Map<String, int> observed = <String, int>{
      for (final SpaceNotification n in items) n.notificationId: n.version,
    };
    try {
      await gateway.ackNotifications(<SpaceAckVersion>[
        for (final SpaceNotification n in items)
          SpaceAckVersion(notificationId: n.notificationId, version: n.version),
      ], operationId: 'space-ack-${DateTime.now().microsecondsSinceEpoch}');
      for (int i = 0; i < notifications.length; i++) {
        final SpaceNotification n = notifications[i];
        final int? version = observed[n.notificationId];
        if (version != null && version >= n.version) {
          notifications[i] = _notificationRead(n);
        }
      }
      unreadNotifications = (unreadNotifications - observed.length).clamp(
        0,
        1 << 31,
      );
      _notify();
      unawaited(_loadOverview());
      return true;
    } catch (failure) {
      notificationsError = spaceErrorText(failure);
      _notify();
      return false;
    } finally {
      acking = false;
      _notify();
    }
  }

  SpaceNotification _notificationRead(SpaceNotification n) => SpaceNotification(
    notificationId: n.notificationId,
    kind: n.kind,
    postId: n.postId,
    commentId: n.commentId,
    targetPostId: n.targetPostId,
    version: n.version,
    ackVersion: n.version,
    unread: false,
    accessible: n.accessible,
    deleted: n.deleted,
    actors: n.actors,
    actorCount: n.actorCount,
    snippet: n.snippet,
    createdAt: n.createdAt,
  );

  Future<void> loadDrafts({bool silent = false}) async {
    if (draftsLoading) {
      return;
    }
    draftsLoading = true;
    if (!silent) {
      draftsError = null;
    }
    _notify();
    try {
      final SpacePageDraft page = await gateway.listDrafts(limit: 20);
      drafts
        ..clear()
        ..addAll(page.items);
      draftsError = null;
    } catch (failure) {
      draftsError = spaceErrorText(failure);
    } finally {
      draftsLoading = false;
      _notify();
    }
  }

  Future<bool> discardDraft(SpaceDraft draft) async {
    try {
      await gateway.deleteDraft(
        draftId: draft.draftId,
        operationId: 'space-del-draft-${DateTime.now().microsecondsSinceEpoch}',
        expectedVersion: draft.version,
      );
      store.deleteDraft(draft.draftId);
      drafts.removeWhere((SpaceDraft d) => d.draftId == draft.draftId);
      _notify();
      return true;
    } catch (failure) {
      draftsError = spaceErrorText(failure);
      _notify();
      return false;
    }
  }

  void _startTimer() {
    if (!autoPoll || pollInterval == null || _timer != null) {
      return;
    }
    _timer = Timer.periodic(pollInterval!, (_) {
      unawaited(pollEventsOnce());
    });
  }

  Future<void> _reconnectReplay() async {
    await pollEventsOnce();
    await loadNotifications(reset: true, silent: true);
    await loadDrafts(silent: true);
  }

  /// Applies every persisted invalidation after the last processed event ID.
  /// IDs are deduplicated and the cursor advances only after a page is applied.
  Future<void> pollEventsOnce() async {
    if (!_eventsReady || _polling || _disposed) {
      return;
    }
    _polling = true;
    try {
      for (int page = 0; page < 20; page++) {
        final SpaceEventPage events = await gateway.readEvents(
          afterEventId: _eventCursor ?? 0,
          limit: 100,
        );
        for (final SpaceEvent event in events.items) {
          if (_seenEvents.contains(event.eventId)) {
            continue;
          }
          _seenEvents.add(event.eventId);
          if (_seenEvents.length > 512) {
            _seenEvents.remove(_seenEvents.first);
          }
          _applyEvent(event);
        }
        _eventCursor = events.nextEventId;
        _notify();
        if (!events.hasMore) {
          break;
        }
      }
    } catch (_) {
      // Reconnect retries from the same cursor on the next tick/refresh.
    } finally {
      _polling = false;
    }
  }

  void _applyEvent(SpaceEvent event) {
    switch (event.type) {
      case 'post.deleted':
        final String? postId = event.postId;
        if (postId != null) {
          SpacePost? removed;
          for (final SpacePost post in posts) {
            if (post.postId == postId) {
              removed = post;
              break;
            }
          }
          if (removed != null) {
            for (final SpaceImage image in removed.images) {
              images.invalidateImage(image.imageId);
            }
            final SpaceImage? referenceImage = removed.reference?.image;
            if (referenceImage != null) {
              images.invalidateImage(referenceImage.imageId);
            }
          }
          _tombstones.add(postId);
          posts.removeWhere((SpacePost p) => p.postId == postId);
          _pendingPage.removeWhere((SpacePost p) => p.postId == postId);
          _details[postId]?.onDeletedEvent();
          _scrubReferencesTo(postId);
          if (posts.isEmpty && phase == SpacePhase.ready) {
            phase = SpacePhase.empty;
          }
        }
        break;
      case 'post.changed':
        final String? postId = event.postId;
        if (postId != null) {
          _details[postId]?.onChangedEvent();
        }
        break;
      case 'comment.deleted':
        final String? commentId = event.commentId;
        final String? postId = event.postId;
        if (commentId != null && postId != null) {
          _details[postId]?.onCommentDeletedEvent(commentId);
        }
        break;
      case 'notification.changed':
        unawaited(_loadOverview());
        if (section == SpaceSection.notifications) {
          unawaited(loadNotifications(reset: true, silent: true));
        }
        break;
      case 'read.changed':
        unawaited(_loadOverview());
        break;
      case 'draft.changed':
        if (section == SpaceSection.drafts) {
          unawaited(loadDrafts(silent: true));
        }
        break;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final SpaceDetailController controller in _details.values) {
      controller.dispose();
    }
    _details.clear();
    super.dispose();
  }
}
