import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;
import 'sentinel_round5_test.dart' as media;

void main() {
  test('T07 local delete followed by replay clears own original cache', () async {
    final g = await real.login();
    final post = await media.imagePost(g, 'local-delete');
    final live = await media.imagePost(g, 'live');
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    final id = post.images.single.imageId;
    final liveId = live.images.single.imageId;
    await c.images.load(id, variant: 'original');
    await c.images.load(liveId, variant: 'original');
    expect(await c.deletePost(post), isTrue);
    await c.pollEventsOnce();
    expect(c.posts.any((p) => p.postId == post.postId), isFalse);
    await expectLater(g.image(id, variant: 'original'), throwsA(isA<AuthFailure>().having((e) => e.status, 'status', 404)));
    expect(c.images.cached(liveId, variant: 'original'), isNotNull);
    expect(c.images.cached(id, variant: 'original'), isNull,
      reason: 'local deletion must revoke cached own media even after removing feed entry');
  });

  test('T07 deletion of detail outside first feed page clears original cache', () async {
    final g = await real.login();
    final old = await media.imagePost(g, 'older');
    for (var i = 0; i < 21; i++) {
      await real.publish(g, 'newer-$i');
    }
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    expect(c.posts.any((p) => p.postId == old.postId), isFalse);
    final detail = await c.openPost(old.postId);
    expect(detail!.post!.postId, old.postId);
    final id = old.images.single.imageId;
    await c.images.load(id, variant: 'original');
    await g.deletePost(old.postId, operationId: 'delete-old');
    await c.pollEventsOnce();
    await expectLater(g.image(id, variant: 'original'), throwsA(isA<AuthFailure>().having((e) => e.status, 'status', 404)));
    expect(c.images.cached(id, variant: 'original'), isNull,
      reason: 'detail-only image must be invalidated even when absent from feed');
  });
}
