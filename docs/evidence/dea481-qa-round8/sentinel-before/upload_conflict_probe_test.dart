import 'dart:async';

import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_compose_controller.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'space_defect_probe_test.dart' as real;
import 'adjacent_draft_probe_test.dart' as adjacent;

class DelayedUploadGateway extends SpaceServiceGateway {
  DelayedUploadGateway(super.service);
  final accepted = Completer<SpaceOperation>();
  final release = Completer<void>();

  @override
  Future<SpaceOperation> addImage({required String draftId,
    required String operationId, required int expectedVersion,
    required String filename, required List<int> bytes}) async {
    final operation = await super.addImage(draftId: draftId,
        operationId: operationId, expectedVersion: expectedVersion,
        filename: filename, bytes: bytes);
    accepted.complete(operation);
    await release.future;
    return operation;
  }
}

void main() {
  test('real T02 upload confirmation must fence a newer external writer', () async {
    final base = await real.login();
    final gateway = DelayedUploadGateway(base.service);
    final c = SpaceComposeController(gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey),
        picker: () async => PickedSpaceImage(bytes: adjacent.png, filename: 'test.png'));
    addTearDown(c.dispose);
    await c.start();
    c.text.text = 'pending local text';
    c.onTextChanged();
    final uploading = c.addImage();
    final receipt = await gateway.accepted.future;
    final afterUpload = await base.getDraft(c.id!);
    expect(afterUpload.version, receipt.resourceVersion);
    await base.updateDraft(draftId: c.id!, operationId: 'other-client',
        expectedVersion: afterUpload.version, text: 'other client committed',
        imageIds: afterUpload.images.map((i) => i.imageId).toList());
    expect(c.phase, DraftSavePhase.dirty,
        reason: 'controlled setup completes before the autosave debounce');
    gateway.release.complete();
    await uploading;
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect((await base.getDraft(c.id!)).text, 'other client committed',
        reason: 'a later server version must not become permission to overwrite another writer');
    expect(c.text.text, 'pending local text');
    expect(c.phase, DraftSavePhase.conflict);
  });
}
