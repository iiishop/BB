import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;

void main() {
  test('deleting repost source preserves notification to surviving repost target', () async {
    final a = await real.login();final b = await real.login();
    final source = await real.publish(a, 'source');
    final repost = await real.publish(b, 'surviving repost', reference: source);
    final c = SpaceController(gateway: a, store: SpaceLocalStore(scopeKey: a.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();await c.loadNotifications(reset: true);
    await a.deletePost(source, operationId: 'delete-source');
    await c.pollEventsOnce();
    final n = c.notifications.singleWhere((n) => n.kind == 'repost');
    final remote = (await a.listNotifications()).items.singleWhere((n) => n.kind == 'repost');
    expect(n.postId, source);
    expect(n.targetPostId, repost);
    expect(n.accessible, isTrue);expect(n.deleted, isFalse);
    expect(n.snippet, remote.snippet);
    expect(await c.openNotification(n), isTrue);
    expect(c.detail!.post!.postId, repost);
    expect(c.detail!.post!.reference!.deleted, isTrue);
  });
}
