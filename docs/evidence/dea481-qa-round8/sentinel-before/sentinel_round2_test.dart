import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_compose_controller.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'space_defect_probe_test.dart' as real;
import 'adjacent_draft_probe_test.dart' as adjacent;

class UploadReadFailure extends SpaceServiceGateway {
  UploadReadFailure(super.service);
  final accepted = Completer<void>();
  final release = Completer<void>();
  bool failConfirmation = false;
  @override
  Future<SpaceOperation> addImage({required String draftId,
      required String operationId, required int expectedVersion,
      required String filename, required List<int> bytes}) async {
    final result = await super.addImage(draftId: draftId, operationId: operationId,
      expectedVersion: expectedVersion, filename: filename, bytes: bytes);
    accepted.complete();
    await release.future;
    failConfirmation = true;
    return result;
  }
  @override
  Future<SpaceDraft> getDraft(String draftId) async {
    if (failConfirmation) {
      failConfirmation = false;
      throw const AuthFailure(status: 503, code: 'upstream_unavailable', message: 'confirmation unavailable');
    }
    return super.getDraft(draftId);
  }
}

class DelayedFeed extends SpaceServiceGateway {
  DelayedFeed(super.service);
  bool delay = false;
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpacePagePost> listPosts({String? cursor, int limit = 20, bool unreadOnly = false}) async {
    final result = await super.listPosts(cursor: cursor, limit: limit, unreadOnly: unreadOnly);
    if (delay) {
      delay = false;
      captured.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  test('T02 failed upload confirmation retry preserves local image removal', () async {
    final base = await real.login();
    final draft = await base.createDraft(operationId: 'create', text: 'initial');
    await base.addImage(draftId: draft.resourceId!, operationId: 'image-a',
      expectedVersion: 1, filename: 'a.png', bytes: adjacent.png);
    final gateway = UploadReadFailure(base.service);
    final c = SpaceComposeController(gateway: gateway,
      store: SpaceLocalStore(scopeKey: gateway.scopeKey), draftId: draft.resourceId,
      picker: () async => PickedSpaceImage(bytes: adjacent.png, filename: 'b.png'));
    addTearDown(c.dispose);
    await c.start();
    final removedId = c.images.single.imageId;
    final uploading = c.addImage();
    await gateway.accepted.future;
    await c.removeImage(removedId);
    expect(c.images, isEmpty);
    expect(c.phase, DraftSavePhase.conflict,
      reason: 'real receiver rejects edit using version before accepted upload');
    gateway.release.complete();
    await uploading;
    expect(c.pending.single.uploaded, isTrue);
    await c.retryUpload(c.pending.single);
    expect(c.images.any((i) => i.imageId == removedId), isFalse,
      reason: 'confirmation retry cannot restore an image explicitly removed during upload');
  });

  test('T07 stale refresh response cannot restore a deleted post or reference', () async {
    final base = await real.login();
    final a = await real.publish(base, 'source secret');
    final b = await real.publish(base, 'repost', reference: a);
    final g = DelayedFeed(base.service);
    final c = SpaceController(gateway: g, store: SpaceLocalStore(scopeKey: g.scopeKey), autoPoll: false);
    addTearDown(c.dispose);
    await c.start();
    g.delay = true;
    final refreshing = c.refresh();
    await g.captured.future;
    await base.deletePost(a, operationId: 'delete');
    await c.pollEventsOnce();
    expect(c.posts.any((p) => p.postId == a), isFalse);
    expect(c.posts.singleWhere((p) => p.postId == b).reference!.text, isNull);
    g.release.complete();
    await refreshing;
    expect(c.posts.any((p) => p.postId == a), isFalse,
      reason: 'late feed snapshot cannot resurrect a processed tombstone');
    expect(c.posts.singleWhere((p) => p.postId == b).reference!.text, isNull);
  });
}
