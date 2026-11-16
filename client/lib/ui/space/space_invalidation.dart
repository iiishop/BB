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
