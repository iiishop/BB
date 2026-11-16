import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'space_defect_probe_test.dart' as real;

/// Actual mutation reaches FastAPI; model loss of its reply after commit.
/// Server data, deletion and event delivery all use the real SpaceService.
class LostLikeReply extends SpaceServiceGateway {
  LostLikeReply(super.service);
  final committed = Completer<void>();
  final release = Completer<void>();

  @override
  Future<SpaceOperation> setLike(String postId, {
    required bool liked,
    required String operationId,
  }) async {
    await super.setLike(postId, liked: liked, operationId: operationId);
    committed.complete();
    await release.future;
    throw const AuthFailure(
      status: 503, code: 'upstream_unavailable', message: 'lost committed reply',
    );
  }
}

void main() {
  for (final detailPath in [false, true]) {
    test('T07 like rollback cannot restore deleted reference detail=$detailPath', () async {
      final base = await real.login();
      final source = await real.publish(base, 'deleted source secret');
      final repost = await real.publish(base, 'repost', reference: source);
      final gateway = LostLikeReply(base.service);
      final controller = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey), autoPoll: false,
      );
      addTearDown(controller.dispose);
      await controller.start();
      final detail = detailPath ? await controller.openPost(repost) : null;
      final liking = detailPath
          ? detail!.toggleLike()
          : controller.togglePostLike(controller.posts.singleWhere((p) => p.postId == repost));
      await gateway.committed.future;
      expect((await base.getPost(repost)).liked, isTrue,
        reason: 'mutation really committed before simulating a lost response');
      await base.deletePost(source, operationId: 'delete-source');
      await controller.pollEventsOnce();
      SpacePost visible() => detailPath
          ? detail!.post!
          : controller.posts.singleWhere((p) => p.postId == repost);
      expect(visible().reference!.text, isNull,
        reason: 'actual deletion event scrubbed the reference before rollback');
      expect((await base.getPost(repost)).reference!.text, isNull,
        reason: 'authoritative server no longer exposes the source body');
      gateway.release.complete();
      await liking;
      expect(visible().reference!.text, isNull,
        reason: 'rollback must not overwrite a processed deletion tombstone');
      expect(visible().reference!.author, isNull);
      expect(visible().reference!.image, isNull);
    });
  }
}
