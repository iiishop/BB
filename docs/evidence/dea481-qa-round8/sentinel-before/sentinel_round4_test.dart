import 'dart:async';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;

class DelayedNotifications extends SpaceServiceGateway {
  DelayedNotifications(super.service);
  bool delay = false;
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpacePageNotification> listNotifications({String? cursor, int limit = 20, bool unreadOnly = false}) async {
    final result = await super.listNotifications(cursor: cursor, limit: limit, unreadOnly: unreadOnly);
    if (delay) {
      delay = false;
      captured.complete();
      await release.future;
    }
    return result;
  }
}

Map<String, Object?> state(SpaceNotification n) => {
  'snippet': n.snippet, 'accessible': n.accessible, 'deleted': n.deleted,
};

void main() {
  test('deleted comment notification must match unavailable server state after late page', () async {
    final a = await real.login();
    final b = await real.login();
    final post = await real.publish(a, 'post');
    final root = await b.createComment(post, text: 'parent secret', operationId: 'root');
    final child = await a.createComment(post, text: 'surviving child', replyToId: root.resourceId, operationId: 'child');
    final g = DelayedNotifications(a.service);
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    final peer = SpaceController(gateway: b, store: SpaceLocalStore(scopeKey: b.scopeKey), autoPoll: false);
    addTearDown(c.dispose);addTearDown(peer.dispose);
    await c.start();await peer.start();
    await c.loadNotifications(reset: true);await peer.loadNotifications(reset: true);
    g.delay = true;
    final loading = c.loadNotifications(reset: true);
    await g.captured.future;
    await b.deleteComment(root.resourceId!, operationId: 'delete-root');
    await c.pollEventsOnce();await peer.pollEventsOnce();
    final childNotice = peer.notifications.singleWhere((n) => n.commentId == child.resourceId);
    expect(childNotice.accessible, isTrue);
    expect(childNotice.deleted, isFalse);
    expect(childNotice.snippet, 'surviving child');
    expect(await peer.openNotification(childNotice), isTrue);
    expect(peer.detail!.context!.target.commentId, child.resourceId);
    final remote = (await a.listNotifications()).items.singleWhere((n) => n.commentId == root.resourceId);
    expect(state(remote), {'snippet': null, 'accessible': false, 'deleted': true});
    g.release.complete();
    await loading;
    expect(state(c.notifications.singleWhere((n) => n.commentId == root.resourceId)), state(remote),
      reason: 'deleted target must show content-deleted and disable invalid navigation, not only erase text');
  });

  test('post deletion invalidates loaded and late notification snapshots', () async {
    final a = await real.login();final b = await real.login();
    final post = await real.publish(a, 'post secret');
    final comment = await b.createComment(post, text: 'comment secret', operationId: 'comment');
    final g = DelayedNotifications(a.service);
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();await c.loadNotifications(reset: true);
    g.delay = true;
    final loading = c.loadNotifications(reset: true);
    await g.captured.future;
    await a.deletePost(post, operationId: 'delete-post');
    await c.pollEventsOnce();
    final afterEvent = state(c.notifications.singleWhere((n) => n.commentId == comment.resourceId));
    final remote = (await a.listNotifications()).items.singleWhere((n) => n.commentId == comment.resourceId);
    expect(state(remote), {'snippet': null, 'accessible': false, 'deleted': true});
    g.release.complete();await loading;
    expect({'afterEvent': afterEvent, 'afterLatePage': state(c.notifications.singleWhere((n) => n.commentId == comment.resourceId))},
      {'afterEvent': state(remote), 'afterLatePage': state(remote)},
      reason: 'post tombstone must protect notifications as well as post/reference snapshots');
  });
}
