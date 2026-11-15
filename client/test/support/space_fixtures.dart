import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/services/space_api_client.dart';

/// Contract-valid fixtures. Every response object is checked against the one
/// generated schema (`server/contract/space-v1.json`) before a test uses it,
/// so the UI cannot drift onto a second, hand-maintained protocol.
const String spaceSelfAccount = '10000001';
const String spacePeerAccount = '10000002';
const String spaceThirdAccount = '10000003';

SpaceAuthor spaceAuthor({
  String account = spaceSelfAccount,
  String username = 'alice',
  String avatarUrl = '',
}) {
  return SpaceAuthor(
    account: account,
    username: username,
    avatarUrl: avatarUrl,
  );
}

SpaceImage spaceImage({
  String imageId = 'img-1',
  String filename = 'photo.png',
  String mimeType = 'image/png',
  int byteSize = 68,
}) => SpaceImage(
  imageId: imageId,
  filename: filename,
  mimeType: mimeType,
  byteSize: byteSize,
  originalUrl: '/space/images/$imageId',
  thumbnailUrl: '/space/images/$imageId?variant=thumb',
);

SpaceComment spaceComment({
  String commentId = 'comment-1',
  String postId = 'post-1',
  String? rootId,
  String? replyToId,
  SpaceAuthor? replyToAuthor,
  SpaceAuthor? author,
  String createdAt = '2026-11-15T10:00:00Z',
  String? text = '一条评论',
  bool deleted = false,
  bool canDelete = false,
}) => SpaceComment(
  commentId: commentId,
  postId: postId,
  rootId: rootId ?? commentId,
  replyToId: replyToId,
  replyToAuthor: replyToAuthor,
  author: author ?? spaceAuthor(),
  createdAt: createdAt,
  text: text,
  deleted: deleted,
  canDelete: canDelete,
);

SpaceBranch spaceBranch({
  required SpaceComment root,
  List<SpaceComment> replies = const <SpaceComment>[],
  int remainingReplies = 0,
}) => SpaceBranch(
  root: root,
  replies: replies,
  remainingReplies: remainingReplies,
);

SpacePost spacePost({
  String postId = 'post-1',
  SpaceAuthor? author,
  String createdAt = '2026-11-15T10:00:00Z',
  String text = '今天的海风很好，顺手拍了几张。',
  List<SpaceImage> images = const <SpaceImage>[],
  SpaceReference? reference,
  bool liked = false,
  bool read = false,
  int likeCount = 0,
  int commentCount = 0,
  int rootCount = 0,
  int repostCount = 0,
  int viewCount = 0,
  bool canDelete = false,
  bool canListVisitors = false,
  List<SpaceBranch> previewComments = const <SpaceBranch>[],
  int remainingRoots = 0,
}) {
  final SpacePost post = SpacePost(
    postId: postId,
    author: author ?? spaceAuthor(),
    createdAt: createdAt,
    text: text,
    images: images,
    reference: reference,
    liked: liked,
    read: read,
    likeCount: likeCount,
    commentCount: commentCount,
    rootCount: rootCount,
    repostCount: repostCount,
    viewCount: viewCount,
    canDelete: canDelete,
    canListVisitors: canListVisitors,
    previewComments: previewComments,
    remainingRoots: remainingRoots,
  );
  validateSpace('get_post', post.toJson(), kind: 'response');
  return post;
}

SpaceReference spaceReference({
  String postId = 'post-ref',
  bool deleted = false,
  SpaceAuthor? author,
  String? text = '被引用的原说说',
  SpaceImage? image,
}) => SpaceReference(
  postId: postId,
  deleted: deleted,
  author: author ?? spaceAuthor(account: spacePeerAccount, username: 'bob'),
  text: text,
  image: image,
);

SpaceOverview spaceOverview({
  int unreadPosts = 0,
  int unreadNotifications = 0,
  int latestEventId = 10,
}) {
  final SpaceOverview overview = SpaceOverview(
    contract: 'dea481-space-v1',
    unreadPosts: unreadPosts,
    unreadNotifications: unreadNotifications,
    latestEventId: latestEventId,
  );
  validateSpace('overview', overview.toJson(), kind: 'response');
  return overview;
}

SpacePagePost spacePagePost(
  List<SpacePost> posts, {
  String? nextCursor,
  bool hasMore = false,
}) {
  final SpacePagePost page = SpacePagePost(
    items: posts,
    nextCursor: nextCursor,
    hasMore: hasMore,
  );
  validateSpace('list_posts', page.toJson(), kind: 'response');
  return page;
}

SpacePageComment spacePageComment(
  List<SpaceComment> comments, {
  String? nextCursor,
  bool hasMore = false,
}) {
  final SpacePageComment page = SpacePageComment(
    items: comments,
    nextCursor: nextCursor,
    hasMore: hasMore,
  );
  validateSpace('list_comments', page.toJson(), kind: 'response');
  return page;
}

SpaceCommentContext spaceContext({
  String postId = 'post-1',
  required SpaceComment root,
  required SpaceComment target,
  SpaceComment? parent,
  List<SpaceComment> nearby = const <SpaceComment>[],
  String? beforeCursor,
  String? afterCursor,
}) {
  final SpaceCommentContext context = SpaceCommentContext(
    postId: postId,
    root: root,
    target: target,
    parent: parent,
    nearby: nearby,
    beforeCursor: beforeCursor,
    afterCursor: afterCursor,
  );
  validateSpace('get_comment_context', context.toJson(), kind: 'response');
  return context;
}

SpaceNotification spaceNotification({
  String notificationId = 'notif-1',
  String kind = 'like',
  String postId = 'post-1',
  String? commentId,
  String? targetPostId,
  int version = 1,
  int ackVersion = 0,
  bool unread = true,
  bool accessible = true,
  bool deleted = false,
  List<SpaceAuthor>? actors,
  int? actorCount,
  String? snippet = '赞了你的说说',
  String createdAt = '2026-11-15T10:00:00Z',
}) {
  final List<SpaceAuthor> resolvedActors =
      actors ??
      <SpaceAuthor>[spaceAuthor(account: spacePeerAccount, username: 'bob')];
  final SpaceNotification notification = SpaceNotification(
    notificationId: notificationId,
    kind: kind,
    postId: postId,
    commentId: commentId,
    targetPostId: targetPostId ?? postId,
    version: version,
    ackVersion: ackVersion,
    unread: unread,
    accessible: accessible,
    deleted: deleted,
    actors: resolvedActors,
    actorCount: actorCount ?? resolvedActors.length,
    snippet: snippet,
    createdAt: createdAt,
  );
  validateSpace('list_notifications', <String, dynamic>{
    'items': <Map<String, dynamic>>[notification.toJson()],
    'next_cursor': null,
    'has_more': false,
  }, kind: 'response');
  return notification;
}

SpacePageNotification spacePageNotification(
  List<SpaceNotification> items, {
  String? nextCursor,
  bool hasMore = false,
}) {
  final SpacePageNotification page = SpacePageNotification(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore,
  );
  validateSpace('list_notifications', page.toJson(), kind: 'response');
  return page;
}

SpaceOperation spaceOperation({
  String operationId = 'op-1',
  String status = 'succeeded',
  String action = 'publish_draft',
  String? resourceId = 'post-1',
  int? resourceVersion,
}) {
  final SpaceOperation operation = SpaceOperation(
    operationId: operationId,
    status: status,
    action: action,
    resourceId: resourceId,
    resourceVersion: resourceVersion,
  );
  validateSpace('get_operation', operation.toJson(), kind: 'response');
  return operation;
}

SpaceDraft spaceDraft({
  String draftId = 'draft-1',
  int version = 1,
  String state = 'draft',
  String text = '',
  String? referenceId,
  List<SpaceImage> images = const <SpaceImage>[],
  String? postId,
  String createdAt = '2026-11-15T10:00:00Z',
}) {
  final SpaceDraft draft = SpaceDraft(
    draftId: draftId,
    version: version,
    state: state,
    text: text,
    referenceId: referenceId,
    images: images,
    postId: postId,
    createdAt: createdAt,
  );
  validateSpace('get_draft', draft.toJson(), kind: 'response');
  return draft;
}

SpacePageDraft spacePageDraft(List<SpaceDraft> drafts) {
  final SpacePageDraft page = SpacePageDraft(
    items: drafts,
    nextCursor: null,
    hasMore: false,
  );
  validateSpace('list_drafts', page.toJson(), kind: 'response');
  return page;
}

SpacePageAuthor spacePageAuthor(List<SpaceAuthor> authors) {
  final SpacePageAuthor page = SpacePageAuthor(
    items: authors,
    nextCursor: null,
    hasMore: false,
  );
  validateSpace('list_likes', page.toJson(), kind: 'response');
  return page;
}

SpaceViewSummary spaceViewSummary({
  String postId = 'post-1',
  int viewCount = 0,
}) {
  final SpaceViewSummary summary = SpaceViewSummary(
    postId: postId,
    viewCount: viewCount,
  );
  validateSpace('get_view_summary', summary.toJson(), kind: 'response');
  return summary;
}

SpacePageVisitor spacePageVisitor(List<SpaceVisitor> visitors) {
  final SpacePageVisitor page = SpacePageVisitor(
    items: visitors,
    nextCursor: null,
    hasMore: false,
  );
  validateSpace('list_visitors', page.toJson(), kind: 'response');
  return page;
}

SpaceVisitor spaceVisitor({
  SpaceAuthor? author,
  int count = 1,
  String lastVisitedAt = '2026-11-15T10:00:00Z',
}) => SpaceVisitor(
  author: author ?? spaceAuthor(account: spacePeerAccount, username: 'bob'),
  count: count,
  lastVisitedAt: lastVisitedAt,
);

SpaceEventPage spaceEventPage(
  List<SpaceEvent> events, {
  int? nextEventId,
  bool hasMore = false,
}) {
  final SpaceEventPage page = SpaceEventPage(
    items: events,
    nextEventId: nextEventId ?? (events.isEmpty ? 0 : events.last.eventId),
    hasMore: hasMore,
  );
  validateSpace('read_events', page.toJson(), kind: 'response');
  return page;
}

SpaceEvent spaceEvent({
  int eventId = 1,
  String type = 'post.changed',
  String? postId = 'post-1',
  String? commentId,
  String? notificationId,
  String occurredAt = '2026-11-15T10:00:00Z',
}) => SpaceEvent(
  version: 1,
  eventId: eventId,
  type: type,
  postId: postId,
  commentId: commentId,
  notificationId: notificationId,
  occurredAt: occurredAt,
);

/// A real, decodable 8x8 PNG; screenshots also exercise the engine decoder.
final Uint8List spaceTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIAQMAAAD+wSzIAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQ5vaAzojtIAAAAHdElNRQfqCw8XDyIfKVvdAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTExLTE1VDIzOjE1OjM0KzAwOjAwMNQOLgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMS0xNVQyMzoxNTozNCswMDowMEGJtpIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTEtMTVUMjM6MTU6MzQrMDA6MDAWnJdNAAAAC0lEQVQI12NgQAUAABAAAaHFIcEAAAAASUVORK5CYII=',
);

SpaceImageContent spaceImageContent({
  String imageId = 'img-1',
  Uint8List? bytes,
}) {
  final SpaceImageContent content = SpaceImageContent(
    imageId: imageId,
    mimeType: 'image/png',
    base64: base64EncodeBytes(bytes ?? spaceTinyPng),
  );
  validateSpace('get_image', content.toJson(), kind: 'response');
  return content;
}

String base64EncodeBytes(List<int> bytes) => base64Encode(bytes);
