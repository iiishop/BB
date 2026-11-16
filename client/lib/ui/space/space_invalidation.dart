import '../../models/space_models.dart';

/// Returns [post] with its reference to [deletedPostId] reduced to the
/// contract's deleted placeholder.
///
/// The server clearing the source is authoritative, but cached feed cards and
/// detail copies must not keep rendering the removed text, author or image
/// between a `post.deleted` event and the next full read. A reference to any
/// other post is returned unchanged.
SpacePost spacePostWithScrubbedReference(
  SpacePost post,
  String deletedPostId,
) {
  final SpaceReference? reference = post.reference;
  if (reference == null ||
      reference.postId != deletedPostId ||
      reference.deleted) {
    return post;
  }
  return SpacePost(
    postId: post.postId,
    author: post.author,
    createdAt: post.createdAt,
    text: post.text,
    images: post.images,
    reference: SpaceReference(
      postId: reference.postId,
      deleted: true,
      author: null,
      text: null,
      image: null,
    ),
    liked: post.liked,
    read: post.read,
    likeCount: post.likeCount,
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

/// Deleted comments keep their identity and reply relationships (so surviving
/// children and reply targets stay navigable) but expose no body or actions.
SpaceComment spaceCommentTombstone(SpaceComment comment) => SpaceComment(
  commentId: comment.commentId,
  postId: comment.postId,
  rootId: comment.rootId,
  replyToId: comment.replyToId,
  replyToAuthor: comment.replyToAuthor,
  author: comment.author,
  createdAt: comment.createdAt,
  text: null,
  deleted: true,
  canDelete: false,
);

SpaceBranch spaceBranchScrubbed(
  SpaceBranch branch,
  bool Function(String commentId) isDeleted,
) {
  final SpaceComment root = isDeleted(branch.root.commentId)
      ? spaceCommentTombstone(branch.root)
      : branch.root;
  final List<SpaceComment> replies = <SpaceComment>[
    for (final SpaceComment reply in branch.replies)
      isDeleted(reply.commentId) ? spaceCommentTombstone(reply) : reply,
  ];
  bool changed = !identical(root, branch.root);
  if (!changed) {
    for (int i = 0; i < replies.length; i++) {
      if (!identical(replies[i], branch.replies[i])) {
        changed = true;
        break;
      }
    }
  }
  if (!changed) {
    return branch;
  }
  return SpaceBranch(
    root: root,
    replies: replies,
    remainingReplies: branch.remainingReplies,
  );
}

/// Scrubs deleted comments inside a post's preview branches (feed and pending
/// page) without dropping surviving replies or their reply targets.
SpacePost spacePostWithScrubbedComments(
  SpacePost post,
  bool Function(String commentId) isDeleted,
) {
  final List<SpaceBranch> previews = <SpaceBranch>[
    for (final SpaceBranch branch in post.previewComments)
      spaceBranchScrubbed(branch, isDeleted),
  ];
  bool changed = false;
  for (int i = 0; i < previews.length; i++) {
    if (!identical(previews[i], post.previewComments[i])) {
      changed = true;
      break;
    }
  }
  if (!changed) {
    return post;
  }
  return SpacePost(
    postId: post.postId,
    author: post.author,
    createdAt: post.createdAt,
    text: post.text,
    images: post.images,
    reference: post.reference,
    liked: post.liked,
    read: post.read,
    likeCount: post.likeCount,
    commentCount: post.commentCount,
    rootCount: post.rootCount,
    repostCount: post.repostCount,
    viewCount: post.viewCount,
    canDelete: post.canDelete,
    canListVisitors: post.canListVisitors,
    previewComments: previews,
    remainingRoots: post.remainingRoots,
  );
}
