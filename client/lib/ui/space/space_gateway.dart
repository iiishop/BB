import 'dart:convert';

import '../../models/auth_models.dart';
import '../../services/space_service.dart';

/// UI-facing port for the one shared Space contract.
///
/// The only production implementation is [SpaceServiceGateway], which delegates
/// to Forge's generated `SpaceService` methods. Tests implement this port with
/// contract-shaped responses validated by `validateSpace`; the UI never speaks
/// HTTP or invents a second wire protocol.
abstract interface class SpaceGateway {
  /// `baseUri|account`, used to isolate local buffers and image caches.
  String get scopeKey;
  String get account;

  Future<SpaceOverview> overview();

  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
    String? author,
  });

  Future<SpacePost> getPost(String postId, {String? visitId});

  Future<SpacePageComment> listComments(
    String postId, {
    String? rootId,
    String? cursor,
    int limit = 20,
  });

  Future<SpaceCommentContext> commentContext(
    String commentId, {
    int radius = 3,
  });

  Future<SpacePageAuthor> listLikes(String postId, {String? cursor});

  Future<SpaceImageContent> image(String imageId, {String variant = 'thumb'});

  Future<SpacePageNotification> listNotifications({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
  });

  Future<SpacePageDraft> listDrafts({String? cursor, int limit = 20});

  Future<SpaceViewSummary> viewSummary(String postId);

  Future<SpacePageVisitor> listVisitors(String postId, {String? cursor});

  Future<SpaceEventPage> readEvents({int afterEventId = 0, int limit = 100});

  Future<SpaceOperation> markRead(
    List<String> postIds, {
    required String operationId,
  });

  Future<SpaceOperation> ackNotifications(
    List<SpaceAckVersion> items, {
    required String operationId,
  });

  Future<SpaceOperation> createDraft({
    required String operationId,
    String text = '',
    String? referenceId,
  });

  Future<SpaceDraft> getDraft(String draftId);

  Future<SpaceOperation> updateDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
    required String text,
    String? referenceId,
    required List<String> imageIds,
  });

  Future<SpaceOperation> addImage({
    required String draftId,
    required String operationId,
    required int expectedVersion,
    required String filename,
    required List<int> bytes,
  });

  Future<SpaceOperation> publishDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
  });

  Future<SpaceOperation> deleteDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
  });

  Future<SpaceOperation> deletePost(
    String postId, {
    required String operationId,
  });

  Future<SpaceOperation> setLike(
    String postId, {
    required bool liked,
    required String operationId,
  });

  Future<SpaceOperation> createComment(
    String postId, {
    required String text,
    required String operationId,
    String? replyToId,
  });

  Future<SpaceOperation> deleteComment(
    String commentId, {
    required String operationId,
  });
}

/// Production adapter over the single shared Space client.
class SpaceServiceGateway implements SpaceGateway {
  SpaceServiceGateway(this.service);

  final SpaceService service;

  @override
  String get account =>
      service.session.user?.account ?? service.session.identity?.account ?? '';

  @override
  String get scopeKey => '${service.api.baseUri}|$account';

  @override
  Future<SpaceOverview> overview() => service.overview();

  @override
  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
    String? author,
  }) => service.listPosts(
    cursor: cursor,
    limit: limit,
    unreadOnly: unreadOnly,
    author: author,
  );

  @override
  Future<SpacePost> getPost(String postId, {String? visitId}) =>
      service.getPost(postId: postId, visitId: visitId);

  @override
  Future<SpacePageComment> listComments(
    String postId, {
    String? rootId,
    String? cursor,
    int limit = 20,
  }) => service.listComments(
    postId: postId,
    rootId: rootId,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<SpaceCommentContext> commentContext(
    String commentId, {
    int radius = 3,
  }) => service.getCommentContext(commentId: commentId, radius: radius);

  @override
  Future<SpacePageAuthor> listLikes(String postId, {String? cursor}) =>
      service.listLikes(postId: postId, cursor: cursor);

  @override
  Future<SpaceImageContent> image(String imageId, {String variant = 'thumb'}) =>
      service.getImage(imageId: imageId, variant: variant);

  @override
  Future<SpacePageNotification> listNotifications({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
  }) => service.listNotifications(
    cursor: cursor,
    limit: limit,
    unreadOnly: unreadOnly,
  );

  @override
  Future<SpacePageDraft> listDrafts({String? cursor, int limit = 20}) =>
      service.listDrafts(cursor: cursor, limit: limit);

  @override
  Future<SpaceViewSummary> viewSummary(String postId) =>
      service.getViewSummary(postId: postId);

  @override
  Future<SpacePageVisitor> listVisitors(String postId, {String? cursor}) =>
      service.listVisitors(postId: postId, cursor: cursor);

  @override
  Future<SpaceEventPage> readEvents({int afterEventId = 0, int limit = 100}) =>
      service.readEvents(afterEventId: afterEventId, limit: limit);

  @override
  Future<SpaceOperation> markRead(
    List<String> postIds, {
    required String operationId,
  }) => service.markRead(operationId: operationId, postIds: postIds);

  @override
  Future<SpaceOperation> ackNotifications(
    List<SpaceAckVersion> items, {
    required String operationId,
  }) => service.ackNotifications(operationId: operationId, items: items);

  @override
  Future<SpaceOperation> createDraft({
    required String operationId,
    String text = '',
    String? referenceId,
  }) => service.createDraft(
    operationId: operationId,
    text: text,
    referenceId: referenceId,
  );

  @override
  Future<SpaceDraft> getDraft(String draftId) =>
      service.getDraft(draftId: draftId);

  @override
  Future<SpaceOperation> updateDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
    required String text,
    String? referenceId,
    required List<String> imageIds,
  }) => service.updateDraft(
    draftId: draftId,
    operationId: operationId,
    expectedVersion: expectedVersion,
    text: text,
    referenceId: referenceId,
    imageIds: imageIds,
  );

  @override
  Future<SpaceOperation> addImage({
    required String draftId,
    required String operationId,
    required int expectedVersion,
    required String filename,
    required List<int> bytes,
  }) => service.addImage(
    draftId: draftId,
    operationId: operationId,
    expectedVersion: expectedVersion,
    filename: filename,
    base64: spaceBase64(bytes),
  );

  @override
  Future<SpaceOperation> publishDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
  }) => service.publishDraft(
    draftId: draftId,
    operationId: operationId,
    expectedVersion: expectedVersion,
  );

  @override
  Future<SpaceOperation> deleteDraft({
    required String draftId,
    required String operationId,
    required int expectedVersion,
  }) => service.deleteDraft(
    draftId: draftId,
    operationId: operationId,
    expectedVersion: expectedVersion,
  );

  @override
  Future<SpaceOperation> deletePost(
    String postId, {
    required String operationId,
  }) => service.deletePost(postId: postId, operationId: operationId);

  @override
  Future<SpaceOperation> setLike(
    String postId, {
    required bool liked,
    required String operationId,
  }) => service.setLike(postId: postId, operationId: operationId, liked: liked);

  @override
  Future<SpaceOperation> createComment(
    String postId, {
    required String text,
    required String operationId,
    String? replyToId,
  }) => service.createComment(
    postId: postId,
    operationId: operationId,
    text: text,
    replyToId: replyToId,
  );

  @override
  Future<SpaceOperation> deleteComment(
    String commentId, {
    required String operationId,
  }) => service.deleteComment(commentId: commentId, operationId: operationId);
}

/// The server contract transfers image bytes as base64; `dart:convert` is the
/// only encoder used so UI tests exercise the same bytes as the service.
String spaceBase64(List<int> bytes) => base64Encode(bytes);

/// Connection-level failures that the UI must show as offline rather than as
/// an empty Space or a permission error.
bool isSpaceOffline(Object error) {
  if (error is! AuthFailure) {
    return true;
  }
  return error.status == 502 ||
      error.status == 503 ||
      error.status == 504 ||
      error.code == 'upstream_unavailable' ||
      error.code == 'upstream_timeout' ||
      error.code == 'storage_unavailable';
}

bool isSpaceUnauthorized(Object error) =>
    error is AuthFailure && error.status == 401;

bool isSpaceUnsupported(Object error) =>
    error is AuthFailure &&
    (error.code == 'unsupported_space' ||
        (error.status == 404 && error.code == 'not_found'));

/// User-facing error copy. Service codes stay structured in logs; the person
/// sees an actionable sentence.
String spaceErrorText(Object error) {
  if (error is AuthFailure) {
    switch (error.code) {
      case 'unsupported_space':
        return '当前服务器还不支持 BB 空间，聊天仍可正常使用';
      case 'forbidden':
        return '你没有权限执行这个操作';
      case 'not_found':
        return '内容不存在或已被删除';
      case 'version_conflict':
        return '草稿已在别处更新，请先查看服务器版本';
      case 'idempotency_conflict':
        return '同一次提交的内容不一致，请刷新后重试';
      case 'source_deleted':
        return '来源说说已被删除，无法转发';
      case 'attachments_not_ready':
        return '还有图片没有准备完成，暂时不能发布';
      case 'validation_error':
        return '内容不符合要求，请检查后重试';
      case 'payload_too_large':
        return '文件超过大小上限';
      case 'unsupported_media_type':
        return '只支持 PNG、JPEG、WebP 图片';
      case 'stale_identity':
        return '登录状态已变化，请重新打开空间';
      default:
        break;
    }
  }
  if (isSpaceOffline(error)) {
    return '暂时无法连接服务器，请稍后重试';
  }
  return '操作失败，请稍后重试';
}
