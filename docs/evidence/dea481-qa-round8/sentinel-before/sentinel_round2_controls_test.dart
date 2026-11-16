import 'package:bb_client/ui/space/space_compose_controller.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'space_defect_probe_test.dart' as real;
import 'adjacent_draft_probe_test.dart' as adjacent;
import 'sentinel_round2_test.dart' show UploadReadFailure;

void main() {
  for (final externalWriter in [false, true]) {
    test('confirmation retry with external writer=$externalWriter', () async {
      final base = await real.login();
      final g = UploadReadFailure(base.service);
      final c = SpaceComposeController(gateway: g,
        store: SpaceLocalStore(scopeKey: g.scopeKey),
        picker: () async => PickedSpaceImage(bytes: adjacent.png, filename: 'a.png'));
      addTearDown(c.dispose);
      await c.start();
      final uploading = c.addImage();
      await g.accepted.future;
      if (externalWriter) {
        c.text.text = 'local input';
        c.onTextChanged();
        final d = await base.getDraft(c.id!);
        await base.updateDraft(draftId: c.id!, operationId: 'other-edit',
          expectedVersion: d.version, text: 'other edit',
          imageIds: d.images.map((i) => i.imageId).toList());
      }
      g.release.complete();
      await uploading;
      expect(c.pending.single.uploaded, isTrue);
      await c.retryUpload(c.pending.single);
      expect(c.pending, isEmpty);
      expect(c.images, hasLength(1));
      if (externalWriter) {
        expect(c.phase, DraftSavePhase.conflict);
        expect(c.text.text, 'local input');
        expect((await base.getDraft(c.id!)).text, 'other edit');
      } else {
        expect(c.phase, DraftSavePhase.saved);
        expect(c.canPublish, isTrue);
        expect(await c.publish(), isTrue);
        expect((await base.getPost(c.publishedPostId!)).images, hasLength(1));
      }
    });
  }
}
