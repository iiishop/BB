import 'dart:async';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;
import 'adjacent_draft_probe_test.dart' as adjacent;

class DelayedImage extends SpaceServiceGateway {
  DelayedImage(super.service);
  String? delayedId;
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpaceImageContent> image(String imageId, {String variant = 'thumb'}) async {
    final result = await super.image(imageId, variant: variant);
    if (imageId == delayedId) {
      delayedId = null;
      captured.complete();
      await release.future;
    }
    return result;
  }
}

Future<SpacePost> imagePost(SpaceServiceGateway g, String prefix) async {
  final d = await g.createDraft(operationId: '$prefix-draft', text: prefix);
  final uploaded = await g.addImage(draftId: d.resourceId!, operationId: '$prefix-image',
    expectedVersion: 1, filename: 'sample.png', bytes: adjacent.png);
  final p = await g.publishDraft(draftId: d.resourceId!, expectedVersion: uploaded.resourceVersion!, operationId: '$prefix-publish');
  return g.getPost(p.resourceId!);
}

void main() {
  test('T07 deleted image cannot reenter cache through a late response', () async {
    final base = await real.login();
    final deleted = await imagePost(base, 'deleted');
    final live = await imagePost(base, 'live');
    final id = deleted.images.single.imageId;
    final liveId = live.images.single.imageId;
    final g = DelayedImage(base.service)..delayedId = id;
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    await c.images.load(liveId, variant: 'original');
    final loading = c.images.load(id, variant: 'original');
    // Attach failure handling now: invalidation may legitimately cancel load.
    final settled = loading.then<void>((_) {}, onError: (Object _) {});
    await g.captured.future;
    await base.deletePost(deleted.postId, operationId: 'delete');
    await c.pollEventsOnce();
    expect(c.posts.any((p) => p.postId == deleted.postId), isFalse);
    expect(c.images.cached(id, variant: 'original'), isNull);
    expect(c.images.cached(liveId, variant: 'original'), isNotNull);
    await expectLater(base.image(id, variant: 'original'),
      throwsA(isA<AuthFailure>().having((e) => e.status, 'status', 404)));
    // Same PNG bytes under a different live image ID remain authorized.
    expect((await base.image(liveId, variant: 'original')).base64, isNotEmpty);
    g.release.complete();
    await settled;
    expect(c.images.cached(id, variant: 'original'), isNull,
      reason: 'late image response must not undo consumed post deletion');
    await expectLater(c.images.load(id, variant: 'original'), throwsA(isA<AuthFailure>()));
  });
}
