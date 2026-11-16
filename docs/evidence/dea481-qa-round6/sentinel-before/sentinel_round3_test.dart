import 'dart:async';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;

class DelayedReplies extends SpaceServiceGateway {
  DelayedReplies(super.service);
  bool delay = false;
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpacePageComment> listComments(String postId, {
    String? rootId, String? cursor, int limit = 20,
  }) async {
    final result = await super.listComments(postId, rootId: rootId,
      cursor: cursor, limit: limit);
    if (delay && rootId != null) {
      delay = false;
      captured.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  test('T08 comment deletion scrubs loaded feed and notification snippets', () async {
    final author = await real.login();
    final peer = await real.login();
    final postId = await real.publish(author, 'post');
    final comment = await peer.createComment(postId, text: 'deleted comment secret', operationId: 'comment');
    final child = await author.createComment(postId, text: 'surviving child',
      replyToId: comment.resourceId, operationId: 'child');
    final c = SpaceController(gateway: author,
      store: SpaceLocalStore(scopeKey: author.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    await c.loadNotifications(reset: true);
    expect(c.posts.singleWhere((p) => p.postId == postId).previewComments.single.root.text,
      'deleted comment secret');
    expect(c.notifications.singleWhere((n) => n.commentId == comment.resourceId).snippet,
      'deleted comment secret');
    await peer.deleteComment(comment.resourceId!, operationId: 'delete-comment');
    await c.pollEventsOnce();
    final authoritative = await author.getPost(postId);
    expect(authoritative.previewComments.single.root.text, isNull);
    expect(authoritative.previewComments.single.replies.single.commentId, child.resourceId);
    final remoteNotifications = await author.listNotifications();
    expect(remoteNotifications.items.singleWhere((n) => n.commentId == comment.resourceId).snippet, isNull);
    expect({
      'feed': c.posts.singleWhere((p) => p.postId == postId).previewComments.single.root.text,
      'notification': c.notifications.singleWhere((n) => n.commentId == comment.resourceId).snippet,
    }, {'feed': null, 'notification': null},
      reason: 'processed comment deletion must redact all already-loaded public snapshots');
  });

  test('T08 late replies response cannot revive a deleted comment', () async {
    final base = await real.login();
    final postId = await real.publish(base, 'post');
    final root = await base.createComment(postId, text: 'root', operationId: 'root');
    final reply = await base.createComment(postId, text: 'deleted reply secret',
      replyToId: root.resourceId, operationId: 'reply');
    final child = await base.createComment(postId, text: 'surviving child',
      replyToId: reply.resourceId, operationId: 'child');
    final g = DelayedReplies(base.service);
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    final detail = (await c.openPost(postId))!;
    g.delay = true;
    final expanding = detail.expandReplies(root.resourceId!);
    await g.captured.future;
    await base.deleteComment(reply.resourceId!, operationId: 'delete-reply');
    await c.pollEventsOnce();
    expect(detail.replies[root.resourceId]!.singleWhere((r) => r.commentId == reply.resourceId).text, isNull);
    final fresh = await base.listComments(postId, rootId: root.resourceId);
    expect(fresh.items.singleWhere((r) => r.commentId == reply.resourceId).text, isNull);
    expect(fresh.items.singleWhere((r) => r.commentId == child.resourceId).replyToId, reply.resourceId);
    g.release.complete();
    await expanding;
    expect(detail.replies[root.resourceId]!.singleWhere((r) => r.commentId == reply.resourceId).text, isNull,
      reason: 'late comment-page response must obey previously consumed comment tombstone');
  });
}
