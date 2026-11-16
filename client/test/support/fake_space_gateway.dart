import 'dart:async';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_gateway.dart';

import 'space_fixtures.dart';

const AuthFailure spaceNotFound = AuthFailure(
  status: 404,
  code: 'not_found',
  message: 'not found',
);

/// Scriptable Space gateway. Every response it returns is contract-valid; the
/// fake only replaces the network, never the DTO shape.
class FakeSpaceGateway implements SpaceGateway {
  FakeSpaceGateway({
    this.account = spaceSelfAccount,
    this.uri = 'http://space.test',
  }) : self = spaceAuthor(account: account, username: 'alice');

  @override
  final String account;
  final String uri;
  final SpaceAuthor self;
  @override
  String get scopeKey => '$uri|$account';

  SpaceOverview overviewResult = spaceOverview();
  final Map<String, SpacePagePost> postPages = <String, SpacePagePost>{};
  final Map<String, SpacePost> posts = <String, SpacePost>{};
  final Map<String, SpacePageComment> commentPages =
      <String, SpacePageComment>{};
  final Map<String, SpaceCommentContext> contexts =
      <String, SpaceCommentContext>{};
  final Map<String, SpacePageAuthor> likePages = <String, SpacePageAuthor>{};
  final Map<String, SpacePageVisitor> visitorPages =
      <String, SpacePageVisitor>{};

  SpacePageNotification notificationPage = spacePageNotification(
    <SpaceNotification>[],
  );
  SpacePageDraft draftPage = spacePageDraft(<SpaceDraft>[]);

  final Map<String, SpaceDraft> drafts = <String, SpaceDraft>{};
  final Map<String, SpaceImage> imageCatalog = <String, SpaceImage>{};
  final Map<String, Uint8List> imageBytes = <String, Uint8List>{};
  final List<SpaceEventPage> eventPages = <SpaceEventPage>[];

  /// Per-action one-shot failures (FIFO). The UI must surface them, not turn
  /// them into an empty list.
  final Map<String, List<Object>> failures = <String, List<Object>>{};

  /// Optional in-flight controls for `updateDraft`: [updateDraftCommitted]
  /// completes after the fake server applied the write, and [updateDraftGate]
  /// delays the response so a test can edit while the save is in flight.
  Completer<void>? updateDraftCommitted;
  Completer<void>? updateDraftGate;

  /// Same in-flight controls for `addImage`.
  Completer<SpaceOperation>? addImageCommitted;
  Completer<void>? addImageGate;

  /// Delays one `listPosts` response after the page was read, so a test can
  /// apply a deletion event before the stale page lands.
  bool holdListPosts = false;
  Completer<void>? listPostsCaptured;
  Completer<void>? listPostsGate;

  /// Delays a committed `setLike` response, optionally failing after release
  /// to exercise the optimistic rollback path against a deletion event.
  Completer<void>? setLikeCaptured;
  Completer<void>? setLikeGate;
  bool failSetLikeAfterGate = false;

  /// Delays one root-reply page after the server read it, so a comment deletion
  /// event can be applied before the stale page returns.
  bool holdReplies = false;
  Completer<void>? repliesCaptured;
  Completer<void>? repliesGate;

  /// Delays one notification page after the server read it, so a post/comment
  /// deletion event can be applied before the stale page returns.
  bool holdNotifications = false;
  Completer<void>? notificationsCaptured;
  Completer<void>? notificationsGate;

  final List<String> calls = <String>[];
  final List<({String postId, String? visitId})> getPostCalls =
      <({String postId, String? visitId})>[];
  final List<List<String>> markReadCalls = <List<String>>[];
  final List<List<SpaceAckVersion>> ackCalls = <List<SpaceAckVersion>>[];
  final List<({String postId, String? replyToId, String text})> commentCalls =
      <({String postId, String? replyToId, String text})>[];
  final List<String> createDraftOperationIds = <String>[];
  final List<String> updateOperationIds = <String>[];
  final List<String> addImageOperationIds = <String>[];
  final List<String> publishOperationIds = <String>[];
  final List<String> deleteDraftOperationIds = <String>[];
  final List<({String postId, bool liked})> likeCalls =
      <({String postId, bool liked})>[];
  final List<String> imageVariants = <String>[];
  int _counter = 0;

  String get _next => '${++_counter}';

  void failNext(String action, Object error) {
    failures.putIfAbsent(action, () => <Object>[]).add(error);
  }

  void _record(String action) {
    calls.add(action);
    final List<Object>? queue = failures[action];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  @override
  Future<SpaceOverview> overview() async {
    _record('overview');
    return overviewResult;
  }

  @override
  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
  }) async {
    _record('list_posts');
    final SpacePagePost page =
        postPages[cursor ?? ''] ?? spacePagePost(const <SpacePost>[]);
    if (holdListPosts) {
      holdListPosts = false;
      final Completer<void>? captured = listPostsCaptured;
      if (captured != null && !captured.isCompleted) {
        captured.complete();
      }
      final Completer<void>? gate = listPostsGate;
      if (gate != null) {
        await gate.future;
      }
    }
    return page;
  }

  @override
  Future<SpacePost> getPost(String postId, {String? visitId}) async {
    _record('get_post');
    getPostCalls.add((postId: postId, visitId: visitId));
    final SpacePost? post = posts[postId];
    if (post == null) {
      throw spaceNotFound;
    }
    return post;
  }

  @override
  Future<SpacePageComment> listComments(
    String postId, {
    String? rootId,
    String? cursor,
    int limit = 20,
  }) async {
    _record('list_comments');
    final SpacePageComment page =
        commentPages['$postId|${rootId ?? ''}|${cursor ?? ''}'] ??
        spacePageComment(const <SpaceComment>[]);
    if (holdReplies && rootId != null) {
      holdReplies = false;
      final Completer<void>? captured = repliesCaptured;
      if (captured != null && !captured.isCompleted) {
        captured.complete();
      }
      final Completer<void>? gate = repliesGate;
      if (gate != null) {
        await gate.future;
      }
    }
    return page;
  }

  @override
  Future<SpaceCommentContext> commentContext(
    String commentId, {
    int radius = 3,
  }) async {
    _record('get_comment_context');
    final SpaceCommentContext? context = contexts[commentId];
    if (context == null) {
      throw spaceNotFound;
    }
    return context;
  }

  @override
  Future<SpacePageAuthor> listLikes(String postId, {String? cursor}) async {
    _record('list_likes');
    return likePages['$postId|${cursor ?? ''}'] ??
        spacePageAuthor(<SpaceAuthor>[]);
  }

  @override
  Future<SpaceImageContent> image(
    String imageId, {
    String variant = 'thumb',
  }) async {
    _record('get_image');
    imageVariants.add('$variant:$imageId');
    return spaceImageContent(
      imageId: imageId,
      bytes: imageBytes[imageId] ?? spaceTinyPng,
    );
  }

  @override
  Future<SpacePageNotification> listNotifications({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
  }) async {
    _record('list_notifications');
    final SpacePageNotification page = notificationPage;
    if (holdNotifications) {
      holdNotifications = false;
      final Completer<void>? captured = notificationsCaptured;
      if (captured != null && !captured.isCompleted) {
        captured.complete();
      }
      final Completer<void>? gate = notificationsGate;
      if (gate != null) {
        await gate.future;
      }
    }
    return page;
  }

  @override
  Future<SpacePageDraft> listDrafts({String? cursor, int limit = 20}) async {
    _record('list_drafts');
    return spacePageDraft(drafts.values.toList());
  }

  @override
  Future<SpaceViewSummary> viewSummary(String postId) async {
    _record('get_view_summary');
    final SpacePost? post = posts[postId];
    return spaceViewSummary(postId: postId, viewCount: post?.viewCount ?? 0);
  }

  @override
  Future<SpacePageVisitor> listVisitors(String postId, {String? cursor}) async {
    _record('list_visitors');
    return visitorPages['$postId|${cursor ?? ''}'] ??
        spacePageVisitor(<SpaceVisitor>[]);
  }

  @override
  Future<SpaceEventPage> readEvents({
    int afterEventId = 0,
    int limit = 100,
  }) async {
    _record('read_events');
    if (eventPages.isEmpty) {
      return spaceEventPage(const <SpaceEvent>[], nextEventId: afterEventId);
    }
    return eventPages.removeAt(0);
  }

  @override
  Future<SpaceOperation> markRead(
    List<String> postIds, {
    required String operationId,
  }) async {
    _record('mark_read');
    markReadCalls.add(List<String>.of(postIds));
    return spaceOperation(
      operationId: operationId,
      action: 'mark_read',
      resourceId: null,
    );
  }

  @override
  Future<SpaceOperation> ackNotifications(
    List<SpaceAckVersion> items, {
    required String operationId,
  }) async {
    _record('ack_notifications');
    ackCalls.add(List<SpaceAckVersion>.of(items));
    return spaceOperation(
      operationId: operationId,
      action: 'ack_notifications',
      resourceId: null,
    );
  }

  @override
  Future<SpaceOperation> createDraft({
    required String operationId,
    String text = '',
    String? referenceId,
  }) async {
    createDraftOperationIds.add(operationId);
    _record('create_draft');
    final String id = 'draft-$_next';
    drafts[id] = spaceDraft(
      draftId: id,
      version: 1,
      text: text,
      referenceId: referenceId,
    );
    return spaceOperation(
      operationId: operationId,
      action: 'create_draft',
      resourceId: id,
      resourceVersion: 1,
    );
  }

  @override
  Future<SpaceDraft> getDraft(String draftId) async {
    _record('get_draft');
    final SpaceDraft? draft = drafts[draftId];
    if (draft == null) {
      throw spaceNotFound;
    }
    return draft;
  }

  @override
  Future<SpaceOperation> updateDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
    required String text,
    String? referenceId,
    required List<String> imageIds,
  }) async {
    updateOperationIds.add(operationId);
    _record('update_draft');
    final SpaceDraft draft = await getDraft(draftId);
    if (draft.version != expectedVersion) {
      throw const AuthFailure(
        status: 409,
        code: 'version_conflict',
        message: 'conflict',
      );
    }
    final List<SpaceImage> images = <SpaceImage>[
      for (final String id in imageIds)
        imageCatalog[id] ?? spaceImage(imageId: id),
    ];
    drafts[draftId] = spaceDraft(
      draftId: draftId,
      version: draft.version + 1,
      text: text,
      referenceId: referenceId,
      images: images,
    );
    final Completer<void>? committed = updateDraftCommitted;
    if (committed != null && !committed.isCompleted) {
      committed.complete();
    }
    final Completer<void>? gate = updateDraftGate;
    if (gate != null) {
      await gate.future;
    }
    return spaceOperation(
      operationId: operationId,
      action: 'update_draft',
      resourceId: draftId,
      resourceVersion: draft.version + 1,
    );
  }

  @override
  Future<SpaceOperation> addImage({
    required String draftId,
    required String operationId,
    required int expectedVersion,
    required String filename,
    required List<int> bytes,
  }) async {
    addImageOperationIds.add(operationId);
    _record('add_image');
    final SpaceDraft draft = await getDraft(draftId);
    if (draft.version != expectedVersion) {
      throw const AuthFailure(
        status: 409,
        code: 'version_conflict',
        message: 'conflict',
      );
    }
    final String imageId = 'img-$_next';
    final SpaceImage image = spaceImage(
      imageId: imageId,
      filename: filename,
      byteSize: bytes.length,
    );
    imageCatalog[imageId] = image;
    drafts[draftId] = spaceDraft(
      draftId: draftId,
      version: draft.version + 1,
      text: draft.text,
      referenceId: draft.referenceId,
      images: <SpaceImage>[...draft.images, image],
    );
    final SpaceOperation operation = spaceOperation(
      operationId: operationId,
      action: 'add_image',
      resourceId: imageId,
      resourceVersion: draft.version + 1,
    );
    final Completer<SpaceOperation>? committed = addImageCommitted;
    if (committed != null && !committed.isCompleted) {
      committed.complete(operation);
    }
    final Completer<void>? gate = addImageGate;
    if (gate != null) {
      await gate.future;
    }
    return operation;
  }

  @override
  Future<SpaceOperation> publishDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
  }) async {
    publishOperationIds.add(operationId);
    _record('publish_draft');
    final SpaceDraft draft = await getDraft(draftId);
    if (draft.version != expectedVersion) {
      throw const AuthFailure(
        status: 409,
        code: 'version_conflict',
        message: 'conflict',
      );
    }
    final String postId = 'post-new-$_next';
    final SpaceReference? reference = draft.referenceId == null
        ? null
        : spaceReference(postId: draft.referenceId!);
    posts[postId] = spacePost(
      postId: postId,
      author: self,
      text: draft.text,
      images: draft.images,
      reference: reference,
      canDelete: true,
    );
    drafts.remove(draftId);
    return spaceOperation(
      operationId: operationId,
      action: 'publish_draft',
      resourceId: postId,
      resourceVersion: draft.version + 1,
    );
  }

  @override
  Future<SpaceOperation> deleteDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
  }) async {
    deleteDraftOperationIds.add(operationId);
    _record('delete_draft');
    final SpaceDraft draft = await getDraft(draftId);
    if (draft.version != expectedVersion) {
      throw const AuthFailure(
        status: 409,
        code: 'version_conflict',
        message: 'conflict',
      );
    }
    drafts.remove(draftId);
    return spaceOperation(
      operationId: operationId,
      action: 'delete_draft',
      resourceId: draftId,
      resourceVersion: draft.version + 1,
    );
  }

  @override
  Future<SpaceOperation> deletePost(
    String postId, {
    required String operationId,
  }) async {
    _record('delete_post');
    posts.remove(postId);
    return spaceOperation(
      operationId: operationId,
      action: 'delete_post',
      resourceId: postId,
    );
  }

  @override
  Future<SpaceOperation> setLike(
    String postId, {
    required bool liked,
    required String operationId,
  }) async {
    _record('set_like');
    likeCalls.add((postId: postId, liked: liked));
    final SpacePost? post = posts[postId];
    if (post != null) {
      posts[postId] = spacePost(
        postId: post.postId,
        author: post.author,
        createdAt: post.createdAt,
        text: post.text,
        images: post.images,
        reference: post.reference,
        liked: liked,
        likeCount:
            post.likeCount + (liked == post.liked ? 0 : (liked ? 1 : -1)),
        commentCount: post.commentCount,
        rootCount: post.rootCount,
        repostCount: post.repostCount,
        viewCount: post.viewCount,
        canDelete: post.canDelete,
        canListVisitors: post.canListVisitors,
        previewComments: post.previewComments,
        remainingRoots: post.remainingRoots,
      );
    }
    final Completer<void>? captured = setLikeCaptured;
    if (captured != null && !captured.isCompleted) {
      captured.complete();
    }
    final Completer<void>? gate = setLikeGate;
    if (gate != null) {
      await gate.future;
    }
    if (failSetLikeAfterGate) {
      failSetLikeAfterGate = false;
      throw upstreamUnavailable;
    }
    return spaceOperation(
      operationId: operationId,
      action: 'set_like',
      resourceId: postId,
    );
  }

  @override
  Future<SpaceOperation> createComment(
    String postId, {
    required String text,
    required String operationId,
    String? replyToId,
  }) async {
    _record('create_comment');
    commentCalls.add((postId: postId, replyToId: replyToId, text: text));
    final String commentId = 'comment-new-$_next';
    final SpaceComment comment = spaceComment(
      commentId: commentId,
      postId: postId,
      rootId: replyToId ?? commentId,
      replyToId: replyToId,
      author: self,
      text: text,
    );
    final String key = '$postId||';
    final SpacePageComment page =
        commentPages[key] ?? spacePageComment(const <SpaceComment>[]);
    commentPages[key] = spacePageComment(<SpaceComment>[
      ...page.items,
      comment,
    ]);
    return spaceOperation(
      operationId: operationId,
      action: 'create_comment',
      resourceId: commentId,
    );
  }

  @override
  Future<SpaceOperation> deleteComment(
    String commentId, {
    required String operationId,
  }) async {
    _record('delete_comment');
    for (final MapEntry<String, SpacePageComment> entry
        in commentPages.entries) {
      final List<SpaceComment> replaced = <SpaceComment>[];
      bool changed = false;
      for (final SpaceComment comment in entry.value.items) {
        if (comment.commentId == commentId) {
          replaced.add(
            spaceComment(
              commentId: comment.commentId,
              postId: comment.postId,
              rootId: comment.rootId,
              replyToId: comment.replyToId,
              replyToAuthor: comment.replyToAuthor,
              author: comment.author,
              createdAt: comment.createdAt,
              text: null,
              deleted: true,
            ),
          );
          changed = true;
        } else {
          replaced.add(comment);
        }
      }
      if (changed) {
        commentPages[entry.key] = spacePageComment(replaced);
      }
    }
    return spaceOperation(
      operationId: operationId,
      action: 'delete_comment',
      resourceId: commentId,
    );
  }
}
