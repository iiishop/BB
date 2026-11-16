import 'package:flutter/foundation.dart';

import '../../models/auth_models.dart';
import '../../models/space_models.dart';
import 'space_gateway.dart';
import 'space_local_store.dart';
import 'space_invalidation.dart';

/// One active detail visit.
///
/// A visit ID is created when a person actively opens a post and reused for
/// every retry, comment refresh and resize, so the server never counts a
/// rebuild as another view. Closing the detail disposes this controller; the
/// next active open gets a new ID.
class SpaceDetailController extends ChangeNotifier {
  SpaceDetailController({
    required this.gateway,
    required this.store,
    required this.postId,
    required this.visitId,
    this.focusCommentId,
    this.onSessionExpired,
    this.onPostDeleted,
    this.isTombstoned,
    this.isDeletedComment,
    this.onCommentDeleted,
  });

  final SpaceGateway gateway;
  final SpaceLocalStore store;
  final String postId;
  final String visitId;
  final String? focusCommentId;
  final VoidCallback? onSessionExpired;
  final void Function(String postId)? onPostDeleted;

  /// Tells whether the owner controller already observed a deletion. A detail
  /// response captured before that event must not render deleted content.
  final bool Function(String postId)? isTombstoned;

  /// Same lookup for comments: late root/reply/context pages, and the post's
  /// preview branches, must not revive a deleted comment body.
  final bool Function(String commentId)? isDeletedComment;

  /// Propagates a locally deleted comment so feed previews and notification
  /// snippets redact it exactly like a remote `comment.deleted` event.
  final void Function(String postId, String commentId)? onCommentDeleted;

  SpacePhase phase = SpacePhase.loading;
  SpacePost? post;
  String? error;
  bool offline = false;
  bool deleted = false;
  bool readMarked = false;

  final List<SpaceComment> roots = <SpaceComment>[];
  final Map<String, List<SpaceComment>> replies =
      <String, List<SpaceComment>>{};
  final Map<String, bool> repliesHasMore = <String, bool>{};
  final Map<String, String?> repliesCursor = <String, String?>{};
  final Set<String> loadingReplies = <String>{};
  final Set<String> probedReplies = <String>{};
  bool rootsHasMore = false;
  String? rootsCursor;

  SpaceCommentContext? context;
  String? highlightedCommentId;

  bool likePending = false;
  bool posting = false;
  String? actionError;

  final Set<String> _deletedComments = <String>{};

  bool _isCommentDeleted(String commentId) =>
      _deletedComments.contains(commentId) ||
      (isDeletedComment?.call(commentId) ?? false);

  bool _disposed = false;
  bool _loading = false;

  bool get liked => post?.liked ?? false;
  int get likeCount => post?.likeCount ?? 0;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Returns the post to render, or null when a deletion was already observed.
  SpacePost? _admitPost(SpacePost loaded) {
    if (isTombstoned?.call(loaded.postId) ?? false) {
      deleted = true;
      phase = SpacePhase.error;
      error = '这条说说已被删除';
      post = null;
      return null;
    }
    SpacePost result = loaded;
    final SpaceReference? reference = result.reference;
    if (reference != null && (isTombstoned?.call(reference.postId) ?? false)) {
      result = spacePostWithScrubbedReference(result, reference.postId);
    }
    return spacePostWithScrubbedComments(result, _isCommentDeleted);
  }

  SpaceComment _admitComment(SpaceComment comment) =>
      _isCommentDeleted(comment.commentId)
      ? spaceCommentTombstone(comment)
      : comment;

  List<SpaceComment> _admitComments(Iterable<SpaceComment> comments) =>
      <SpaceComment>[
        for (final SpaceComment comment in comments) _admitComment(comment),
      ];

  Future<void> load() async {
    if (_loading || deleted) {
      return;
    }
    _loading = true;
    phase = post == null ? SpacePhase.loading : phase;
    _notify();
    try {
      final SpacePost loaded = await gateway.getPost(postId, visitId: visitId);
      final SpacePost? admitted = _admitPost(loaded);
      if (admitted == null) {
        _notify();
        return;
      }
      post = admitted;
      phase = SpacePhase.ready;
      error = null;
      offline = false;
      _notify();
      await _refreshComments();
      if (focusCommentId != null) {
        await _loadContext(focusCommentId!);
      }
      await _maybeMarkRead();
    } on AuthFailure catch (failure) {
      if (isSpaceUnauthorized(failure)) {
        onSessionExpired?.call();
      }
      if (failure.status == 404) {
        deleted = true;
        phase = SpacePhase.error;
        error = '这条说说已被删除';
      } else {
        offline = isSpaceOffline(failure);
        phase = post == null ? SpacePhase.error : phase;
        error = spaceErrorText(failure);
      }
      _notify();
    } catch (failure) {
      offline = isSpaceOffline(failure);
      phase = post == null ? SpacePhase.error : phase;
      error = spaceErrorText(failure);
      _notify();
    } finally {
      _loading = false;
    }
  }

  Future<void> refreshFacts() async {
    if (deleted) {
      return;
    }
    try {
      final SpacePost loaded = await gateway.getPost(postId, visitId: visitId);
      final SpacePost? admitted = _admitPost(loaded);
      if (admitted == null) {
        _notify();
        return;
      }
      post = admitted;
      _notify();
    } catch (_) {
      // The invalidation event is retried by the next explicit refresh.
    }
  }

  Future<void> _maybeMarkRead() async {
    if (readMarked) {
      return;
    }
    try {
      await gateway.markRead(<String>[
        postId,
      ], operationId: 'space-read-$visitId');
      readMarked = true;
      _notify();
    } catch (_) {
      // Read marking is retried by the next successful detail load; it never
      // blocks the content the person already sees.
    }
  }

  Future<void> _refreshComments() async {
    try {
      final SpacePageComment page = await gateway.listComments(
        postId,
        limit: 10,
      );
      roots
        ..clear()
        ..addAll(_admitComments(page.items));
      rootsCursor = page.nextCursor;
      rootsHasMore = page.hasMore;
      final Map<String, SpaceBranch> previews = <String, SpaceBranch>{
        for (final SpaceBranch branch
            in post?.previewComments ?? <SpaceBranch>[])
          branch.root.commentId: branch,
      };
      for (final SpaceComment root in roots) {
        final SpaceBranch? preview = previews[root.commentId];
        if (!replies.containsKey(root.commentId) && preview != null) {
          replies[root.commentId] = List<SpaceComment>.of(preview.replies);
          repliesHasMore[root.commentId] = preview.remainingReplies > 0;
          repliesCursor[root.commentId] = null;
        }
      }
      _notify();
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
    }
  }

  Future<void> loadMoreRoots() async {
    if (!rootsHasMore || rootsCursor == null) {
      return;
    }
    try {
      final SpacePageComment page = await gateway.listComments(
        postId,
        cursor: rootsCursor,
        limit: 10,
      );
      final Set<String> seen = roots
          .map((SpaceComment c) => c.commentId)
          .toSet();
      roots.addAll(
        _admitComments(page.items).where(
          (SpaceComment c) => seen.add(c.commentId),
        ),
      );
      rootsCursor = page.nextCursor;
      rootsHasMore = page.hasMore;
      _notify();
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
    }
  }

  Future<void> expandReplies(String rootId, {bool more = false}) async {
    if (loadingReplies.contains(rootId)) {
      return;
    }
    if (more && !(repliesHasMore[rootId] ?? false)) {
      return;
    }
    loadingReplies.add(rootId);
    _notify();
    try {
      final SpacePageComment page = await gateway.listComments(
        postId,
        rootId: rootId,
        cursor: more ? repliesCursor[rootId] : null,
        limit: 20,
      );
      final List<SpaceComment> existing = more
          ? (replies[rootId] ?? <SpaceComment>[])
          : <SpaceComment>[];
      final Set<String> seen = existing
          .map((SpaceComment c) => c.commentId)
          .toSet();
      replies[rootId] = <SpaceComment>[
        ...existing,
        ..._admitComments(page.items).where(
          (SpaceComment c) => seen.add(c.commentId),
        ),
      ];
      repliesCursor[rootId] = page.nextCursor;
      repliesHasMore[rootId] = page.hasMore;
    } catch (failure) {
      actionError = spaceErrorText(failure);
    } finally {
      loadingReplies.remove(rootId);
      probedReplies.add(rootId);
      _notify();
    }
  }

  Future<void> _loadContext(String commentId) async {
    try {
      final SpaceCommentContext loaded = await gateway.commentContext(
        commentId,
      );
      context = SpaceCommentContext(
        postId: loaded.postId,
        root: _admitComment(loaded.root),
        target: _admitComment(loaded.target),
        parent: loaded.parent == null
            ? null
            : _admitComment(loaded.parent!),
        nearby: _admitComments(loaded.nearby),
        beforeCursor: loaded.beforeCursor,
        afterCursor: loaded.afterCursor,
      );
      highlightedCommentId = commentId;
      final String rootId = context!.root.commentId;
      if (!roots.any((SpaceComment c) => c.commentId == rootId)) {
        roots.insert(0, context!.root);
      }
      final List<SpaceComment> contextItems = <SpaceComment>[
        context!.target,
        ...context!.nearby,
      ];
      final Map<String, SpaceComment> merged = <String, SpaceComment>{
        for (final SpaceComment c in replies[rootId] ?? <SpaceComment>[])
          c.commentId: c,
        for (final SpaceComment c in contextItems) c.commentId: c,
      };
      replies[rootId] = merged.values.toList()
        ..sort((SpaceComment a, SpaceComment b) {
          final int byTime = a.createdAt.compareTo(b.createdAt);
          return byTime != 0 ? byTime : a.commentId.compareTo(b.commentId);
        });
      _notify();
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
    }
  }

  void selectReplyTarget(String? commentId) {
    actionError = null;
    _notify();
  }

  Future<bool> toggleLike() async {
    final SpacePost? current = post;
    if (current == null || likePending) {
      return false;
    }
    final bool desired = !current.liked;
    likePending = true;
    post = _postWithLike(current, desired: desired);
    _notify();
    try {
      await gateway.setLike(
        postId,
        liked: desired,
        operationId:
            'space-like-$visitId-${DateTime.now().microsecondsSinceEpoch}',
      );
      actionError = null;
      return true;
    } catch (failure) {
      final SpacePost? latest = post;
      if (latest != null && !deleted && !(isTombstoned?.call(postId) ?? false)) {
        // Only revert the like fields on the live snapshot; a deletion event
        // during the request must not be undone by the old captured object.
        post = _withLikeFields(
          latest,
          liked: current.liked,
          likeCount: current.likeCount,
        );
      }
      actionError = spaceErrorText(failure);
      return false;
    } finally {
      likePending = false;
      _notify();
    }
  }

  SpacePost _postWithLike(SpacePost original, {required bool desired}) {
    final int delta = desired == original.liked ? 0 : (desired ? 1 : -1);
    return _withLikeFields(
      original,
      liked: desired,
      likeCount: original.likeCount + delta,
    );
  }

  /// Copies [target] so current deletion/reference facts win, overriding only
  /// the like fields.
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

  Future<void> refreshAfterMutation() async {
    try {
      final SpacePost loaded = await gateway.getPost(postId, visitId: visitId);
      final SpacePost? admitted = _admitPost(loaded);
      if (admitted == null) {
        _notify();
        return;
      }
      post = admitted;
      await _refreshComments();
      _notify();
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
    }
  }

  Future<String?> submitComment(String text, {String? replyToId}) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || posting) {
      return '评论不能为空';
    }
    posting = true;
    actionError = null;
    _notify();
    try {
      await gateway.createComment(
        postId,
        text: trimmed,
        replyToId: replyToId,
        operationId:
            'space-comment-$visitId-${DateTime.now().microsecondsSinceEpoch}',
      );
      store.deleteComment(postId);
      await refreshAfterMutation();
      return null;
    } catch (failure) {
      actionError = spaceErrorText(failure);
      return actionError;
    } finally {
      posting = false;
      _notify();
    }
  }

  Future<void> deleteComment(String commentId) async {
    try {
      await gateway.deleteComment(
        commentId,
        operationId:
            'space-del-comment-$visitId-${DateTime.now().microsecondsSinceEpoch}',
      );
      _tombstoneComment(commentId);
      onCommentDeleted?.call(postId, commentId);
      _notify();
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
    }
  }

  void _tombstoneComment(String commentId) {
    _deletedComments.add(commentId);
    for (int i = 0; i < roots.length; i++) {
      if (roots[i].commentId == commentId) {
        roots[i] = spaceCommentTombstone(roots[i]);
      }
    }
    for (final MapEntry<String, List<SpaceComment>> entry in replies.entries) {
      final List<SpaceComment> items = entry.value;
      for (int i = 0; i < items.length; i++) {
        if (items[i].commentId == commentId) {
          items[i] = spaceCommentTombstone(items[i]);
        }
      }
    }
    final SpaceCommentContext? current = context;
    if (current != null) {
      context = SpaceCommentContext(
        postId: current.postId,
        root: current.root.commentId == commentId
            ? spaceCommentTombstone(current.root)
            : current.root,
        target: current.target.commentId == commentId
            ? spaceCommentTombstone(current.target)
            : current.target,
        parent: current.parent?.commentId == commentId
            ? spaceCommentTombstone(current.parent!)
            : current.parent,
        nearby: <SpaceComment>[
          for (final SpaceComment comment in current.nearby)
            comment.commentId == commentId
                ? spaceCommentTombstone(comment)
                : comment,
        ],
        beforeCursor: current.beforeCursor,
        afterCursor: current.afterCursor,
      );
    }
    final SpacePost? currentPost = post;
    if (currentPost != null) {
      post = spacePostWithScrubbedComments(currentPost, _isCommentDeleted);
    }
  }


  Future<bool> deletePost() async {
    try {
      await gateway.deletePost(
        postId,
        operationId:
            'space-del-post-$visitId-${DateTime.now().microsecondsSinceEpoch}',
      );
      deleted = true;
      onPostDeleted?.call(postId);
      _notify();
      return true;
    } catch (failure) {
      actionError = spaceErrorText(failure);
      _notify();
      return false;
    }
  }

  Future<SpacePageVisitor> loadVisitors({String? cursor}) =>
      gateway.listVisitors(postId, cursor: cursor);

  Future<SpacePageAuthor> loadLikes({String? cursor}) =>
      gateway.listLikes(postId, cursor: cursor);

  Future<SpaceViewSummary> loadSummary() => gateway.viewSummary(postId);

  SpaceCommentBuffer? get unsentComment => store.comment(postId);

  void rememberUnsent(String text, String? replyToId) {
    store.saveComment(
      postId,
      SpaceCommentBuffer(text: text, replyToId: replyToId),
    );
  }

  void onDeletedEvent() {
    deleted = true;
    post = null;
    _notify();
  }

  /// Drops a cached reference snapshot whose source post was deleted. The
  /// server re-read is still authoritative; this only removes stale text,
  /// author and image from a card already on screen.
  void onReferenceDeletedEvent(String sourcePostId) {
    final SpacePost? current = post;
    if (current == null) {
      return;
    }
    final SpacePost scrubbed = spacePostWithScrubbedReference(
      current,
      sourcePostId,
    );
    if (identical(scrubbed, current)) {
      return;
    }
    post = scrubbed;
    _notify();
  }

  void onCommentDeletedEvent(String commentId) {
    _tombstoneComment(commentId);
    _notify();
  }

  void onChangedEvent() {
    refreshFacts();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

enum SpacePhase { loading, ready, empty, error }
