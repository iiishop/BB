import 'package:bb_client/ui/media/photo_page.dart';
import 'package:bb_client/ui/media/photo_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/space_fixtures.dart';

/// Pinch gestures are testable: `startGesture` takes a pointer id, so two
/// fingers are two gestures. This exists because 0.1.7 shipped a recognizer
/// that rejected both pointers and nobody noticed until it was on a phone.
class _ReadySource implements PhotoSource {
  @override
  int? get byteSize => 3 * 1024 * 1024;

  @override
  Uint8List? get heldOriginal => null;

  @override
  Listenable? get changes => null;

  @override
  bool get invalidated => false;

  @override
  Future<Uint8List?> readCachedOriginal() async => null;

  @override
  Future<PhotoPreview> loadPreview() async =>
      PhotoPreview(bytes: spaceTinyPng, isDerivative: true);

  @override
  Future<Uint8List> loadOriginal({PhotoProgress? onProgress}) async =>
      spaceTinyPng;
}

void main() {
  late PhotoPageController controller;
  late List<bool> freezes;

  setUp(() {
    controller = PhotoPageController(source: _ReadySource());
    freezes = <bool>[];
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // Resolve the bytes before the first frame: the loading state has an
    // indefinite spinner, and pumpAndSettle would never settle on it.
    await controller.start();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoPage(
            controller: controller,
            onZoomChanged: (bool frozen) => freezes.add(frozen),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double zoomOf(WidgetTester tester) {
    final Transform transform = tester.widget<Transform>(
      find.byKey(PhotoPage.zoomKey),
    );
    return transform.transform.getMaxScaleOnAxis();
  }

  testWidgets('two fingers spread and the picture scales', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    expect(zoomOf(tester), 1.0);

    final Offset center = tester.getCenter(find.byKey(PhotoPage.zoomKey));
    final TestGesture first = await tester.startGesture(
      center - const Offset(40, 0),
      pointer: 11,
    );
    final TestGesture second = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 12,
    );
    await tester.pump();
    for (int step = 0; step < 3; step++) {
      await first.moveBy(const Offset(-40, 0));
      await second.moveBy(const Offset(40, 0));
      await tester.pump();
    }

    expect(
      zoomOf(tester),
      greaterThan(1.5),
      reason: '双指捏合必须真的放大；0.1.7 里两个指针都被 reject，比例一直是 1',
    );
    expect(freezes, contains(true), reason: '捏合期间要冻结翻页');

    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(zoomOf(tester), greaterThan(1.5), reason: '松手后保持放大');
    expect(freezes.last, isTrue);
  });

  testWidgets('pinching back to 1 releases the pager', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    final Offset center = tester.getCenter(find.byKey(PhotoPage.zoomKey));

    final TestGesture first = await tester.startGesture(
      center - const Offset(40, 0),
      pointer: 13,
    );
    final TestGesture second = await tester.startGesture(
      center + const Offset(40, 0),
      pointer: 14,
    );
    await tester.pump();
    for (int step = 0; step < 3; step++) {
      await first.moveBy(const Offset(-40, 0));
      await second.moveBy(const Offset(40, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(zoomOf(tester), greaterThan(1.5));

    // Now pinch the other way, with two fresh fingers (new pointer ids: the
    // previous pair is still registered in the binding's hit-test map). The
    // travel is wide on purpose: the recognizer only records its baseline span
    // once the gesture passes the slop, so a short pinch under-shrinks.
    final TestGesture back1 = await tester.startGesture(
      center - const Offset(190, 0),
      pointer: 21,
    );
    final TestGesture back2 = await tester.startGesture(
      center + const Offset(190, 0),
      pointer: 22,
    );
    await tester.pump();
    for (int step = 0; step < 6; step++) {
      await back1.moveBy(const Offset(36, 0));
      await back2.moveBy(const Offset(-36, 0));
      await tester.pump();
    }
    await back1.up();
    await back2.up();
    await tester.pumpAndSettle();

    expect(zoomOf(tester), 1.0, reason: '缩回 1 倍要复位，翻页也要恢复');
    expect(freezes.last, isFalse);
  });
}
