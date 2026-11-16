import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;
import 'sentinel_round5_test.dart' as media;

void main() {
  test('T07 detail-only repost source deletion invalidates both image variants', () async {
    final g = await real.login();
    final source = await media.imagePost(g, 'detail-reference-source');
    final repostId = await real.publish(g, 'older repost', reference: source.postId);
    for (var i = 0; i < 21; i++) {
      await real.publish(g, 'newer-$i');
    }
    final live = await media.imagePost(g, 'surviving-image');
    final c = SpaceController(
      gateway: g,
      store: SpaceLocalStore(scopeKey: g.scopeKey),
      autoPoll: false,
    );
    addTearDown(c.dispose);
    await c.start();
    expect(c.posts.any((p) => p.postId == source.postId || p.postId == repostId), isFalse);
    // Follow a real reference and return; only the repost detail stays open.
    final detail = await c.openPost(repostId);
    final imageId = detail!.post!.reference!.image!.imageId;
    expect(imageId, source.images.single.imageId);
    final sourceDetail = await c.openReference(source.postId);
    expect(sourceDetail!.post!.postId, source.postId);
    await c.images.load(imageId, variant: 'thumb');
    await c.images.load(imageId, variant: 'original');
    c.backDetail();
    expect(c.detail, same(detail));
    expect(c.detailHistory, [repostId]);
    final liveId = live.images.single.imageId;
    await c.images.load(liveId, variant: 'original');
    await g.deletePost(source.postId, operationId: 'delete-detail-reference-source');
    await c.pollEventsOnce();
    expect(detail.post!.reference!.deleted, isTrue);
    expect(detail.post!.reference!.image, isNull);
    await expectLater(
      g.image(imageId, variant: 'original'),
      throwsA(isA<AuthFailure>().having((e) => e.status, 'status', 404)),
    );
    expect(c.images.cached(liveId, variant: 'original'), isNotNull);
    expect(
      [c.images.cached(imageId, variant: 'thumb') != null,
       c.images.cached(imageId, variant: 'original') != null],
      [false, false],
      reason: 'detail-only reference removal must invalidate its cached source bytes before scrubbing the owner',
    );
  });
}
