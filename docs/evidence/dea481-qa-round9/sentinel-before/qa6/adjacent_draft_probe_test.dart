import 'dart:convert';

import 'package:bb_client/ui/space/space_compose_controller.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'space_defect_probe_test.dart' as real;

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIAQMAAAD+wSzIAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAADUExURQ5vaAzojtIAAAAHdElNRQfqCw8XDyIfKVvdAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTExLTE1VDIzOjE1OjM0KzAwOjAwMNQOLgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0xMS0xNVQyMzoxNTozNCswMDowMEGJtpIAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMTEtMTVUMjM6MTU6MzQrMDA6MDAWnJdNAAAAC0lEQVQI12NgQAUAABAAAaHFIcEAAAAASUVORK5CYII=',
);

void main() {
  test('real T02 image removal during save must survive the older receipt', () async {
    final base = await real.login();
    final draft = await base.createDraft(operationId: 'create', text: 'initial');
    await base.addImage(draftId: draft.resourceId!, operationId: 'image',
        expectedVersion: 1, filename: 'test.png', bytes: png);
    final gateway = real.DelayedRealGateway(base.service);
    final c = SpaceComposeController(gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey), draftId: draft.resourceId);
    addTearDown(c.dispose);
    await c.start();
    final imageId = c.images.single.imageId;
    c.text.text = 'first saved edit';
    c.onTextChanged();
    final saving = c.saveNow();
    await gateway.accepted.future;
    await c.removeImage(imageId);
    expect(c.images, isEmpty, reason: 'removal is visible before the older reply');
    gateway.release.complete();
    await saving;
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(c.images, isEmpty, reason: 'an older receipt must not restore the removed image');
    expect((await base.getDraft(draft.resourceId!)).images, isEmpty);
  });

  test('real T02 upload must not erase already-dirty text', () async {
    final gateway = await real.login();
    final c = SpaceComposeController(gateway: gateway,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey),
        picker: () async => PickedSpaceImage(bytes: png, filename: 'test.png'));
    addTearDown(c.dispose);
    await c.start();
    c.text.text = 'unsaved before image selection';
    c.onTextChanged();
    await c.addImage();
    expect(c.images, hasLength(1), reason: 'real upload completed');
    expect(c.text.text, 'unsaved before image selection',
        reason: 'image confirmation must preserve input already dirty at upload admission');
    await c.saveNow();
    expect((await gateway.getDraft(c.id!)).text, 'unsaved before image selection');
  });
}
