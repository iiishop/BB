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

  /// Comments whose deletion was already observed. Every public snapshot that
  /// embeds a comment (feed preview, pending page, notification snippet, detail
  /// page/context) must redact it, including late responses.
  final Set<String> _deletedComments = <String>{};

  /// Post id -> owned image ids. Kept beyond the visible snapshot lifetime so
  /// deleting a post after its detail was closed can still revoke cached
  /// thumbnails/originals and cancel in-flight loads.
  final Map<String, List<String>> _ownedImageIds = <String, List<String>>{};
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
        // Revert only the like fields on the live snapshot. Restoring the
        // whole captured object would resurrect deleted text/reference facts
        // when a deletion event arrived while the request was in flight.
        posts[current] = _withLikeFields(
          posts[current],
          liked: original.liked,
          likeCount: original.likeCount,
        );
      }
      feedError = spaceErrorText(failure);
    }
    _notify();
  }

  SpacePost _withLike(SpacePost original, bool desired) {
    final int delta = desired == original.liked ? 0 : (desired ? 1 : -1);
    return _withLikeFields(
      original,
      liked: desired,
      likeCount: original.likeCount + delta,
    );
  }

  /// Copies [target] (so its current deletion/reference facts win) and only
  /// overrides the like fields.
  SpacePost _withLikeFields(
    SpacePost target, {
    required bool liked,
    required int likeCount,
  }) {
    return SpacePost(
      postId: target.postId,
      author: target.author,
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
        isDeletedComment: _isDeletedComment,
        onCommentDeleted: _handleCommentDeleted,
        onPostObserved: _recordOwnedImages,
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
    // Invalidate the owned image bytes before removing the last snapshot that
    // still knows which images belong to this post.
    _invalidateImagesForPostId(postId);
    posts.removeWhere((SpacePost p) => p.postId == postId);
    _pendingPage.removeWhere((SpacePost p) => p.postId == postId);
    _scrubReferencesTo(postId);
    _scrubCommentCaches();
    if (posts.isEmpty && phase == SpacePhase.ready) {
      phase = SpacePhase.empty;
    }
    _notify();
  }

  /// Drops every cached thumbnail/original owned by [postId], wherever the
  /// owning snapshot currently lives (feed, pending page or an open detail).
  /// Call this before removing that snapshot.
  void _invalidateImagesForPostId(String postId) {
    void invalidate(SpacePost? post) {
      if (post == null || post.postId != postId) {
        return;
      }
      // Only images this post owns. A deleted repost's reference image belongs
      // to the still-live source post, so invalidating it would blank an open
      // viewer for that source.
      for (final SpaceImage image in post.images) {
        images.invalidateImage(image.imageId);
      }
    }

    for (final SpacePost post in posts) {
      invalidate(post);
    }
    for (final SpacePost post in _pendingPage) {
      invalidate(post);
    }
    invalidate(_details[postId]?.post);
    // Snapshots can be gone (detail backed out or closed) before the deletion
    // event arrives; the recorded ownership still knows which bytes to revoke.
    for (final String imageId in _ownedImageIds.remove(postId) ?? <String>[]) {
      images.invalidateImage(imageId);
    }
  }

  void _recordOwnedImages(SpacePost post) {
    if (post.images.isEmpty) {
      return;
    }
    _ownedImageIds[post.postId] = <String>[
      for (final SpaceImage image in post.images) image.imageId,
    ];
  }

  bool _isTombstoned(String postId) => _tombstones.contains(postId);

  bool _isDeletedComment(String commentId) =>
      _deletedComments.contains(commentId);

  SpacePost _scrubIncoming(SpacePost post) {
    SpacePost result = post;
    final SpaceReference? reference = result.reference;
    if (reference != null && _tombstones.contains(reference.postId)) {
      result = spacePostWithScrubbedReference(result, reference.postId);
    }
    result = spacePostWithScrubbedComments(result, _isDeletedComment);
    _recordOwnedImages(result);
    return result;
  }

  /// Mirrors the server's notification projection: a notification is
  /// unavailable when its navigation target post is deleted, or when its
  /// referenced comment is deleted. A surviving repost target keeps the
  /// notification usable even if the quoted source post is gone.
  SpaceNotification _scrubNotification(SpaceNotification notification) {
    final bool postDeleted = _tombstones.contains(notification.targetPostId);
    final String? commentId = notification.commentId;
    final bool commentDeleted =
        commentId != null && _deletedComments.contains(commentId);
    if (!postDeleted && !commentDeleted) {
      return notification;
    }
    return SpaceNotification(
      notificationId: notification.notificationId,
      kind: notification.kind,
      postId: notification.postId,
      commentId: notification.commentId,
      targetPostId: notification.targetPostId,
      version: notification.version,
      ackVersion: notification.ackVersion,
      unread: notification.unread,
      accessible: false,
      deleted: true,
      actors: notification.actors,
      actorCount: notification.actorCount,
      snippet: null,
      createdAt: notification.createdAt,
    );
  }

  void _handleCommentDeleted(String postId, String commentId) {
    _deletedComments.add(commentId);
    _scrubCommentCaches();
    _details[postId]?.onCommentDeletedEvent(commentId);
    _notify();
  }

  void _scrubCommentCaches() {
    for (int i = 0; i < posts.length; i++) {
      posts[i] = spacePostWithScrubbedComments(posts[i], _isDeletedComment);
    }
    for (int i = 0; i < _pendingPage.length; i++) {
      _pendingPage[i] = spacePostWithScrubbedComments(
        _pendingPage[i],
        _isDeletedComment,
      );
    }
    for (int i = 0; i < notifications.length; i++) {
      notifications[i] = _scrubNotification(notifications[i]);
    }
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
      final SpaceReference? reference = controller.post?.reference;
      if (reference != null && reference.postId == postId) {
        final SpaceImage? image = reference.image;
        if (image != null) {
          images.invalidateImage(image.imageId);
        }
      }
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
      final List<SpaceNotification> admitted = <SpaceNotification>[
        for (final SpaceNotification notification in page.items)
          _scrubNotification(notification),
      ];
      if (reset || notifications.isEmpty) {
        notifications
          ..clear()
          ..addAll(admitted);
      } else {
        final Set<String> seen = notifications
            .map((SpaceNotification n) => n.notificationId)
            .toSet();
        notifications.addAll(
          admitted.where((SpaceNotification n) => seen.add(n.notificationId)),
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
          _tombstones.add(postId);
          _invalidateImagesForPostId(postId);
          posts.removeWhere((SpacePost p) => p.postId == postId);
          _pendingPage.removeWhere((SpacePost p) => p.postId == postId);
          _details[postId]?.onDeletedEvent();
          _scrubReferencesTo(postId);
          _scrubCommentCaches();
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
        if (commentId != null) {
          _deletedComments.add(commentId);
          _scrubCommentCaches();
        }
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
