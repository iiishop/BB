import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/space_download_log.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';

/// Three images, all loadable, so paging is possible in both directions.
Future<SpaceImageViewer> buildViewer({
  required TargetPlatform platform,
  int initialIndex = 1,
}) async {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  final List<SpaceImage> images = <SpaceImage>[];
  for (final String id in <String>['img-1', 'img-2', 'img-3']) {
    gateway.imageBytes[id] = spaceTinyPng;
    images.add(spaceImage(imageId: id));
  }
  return SpaceImageViewer(
    images: images,
    initialIndex: initialIndex,
    loader: SpaceImageLoader(gateway),
  );
}

void main() {
  testWidgets('desktop shows paging arrows and they page the viewer', (
    WidgetTester tester,
  ) async {
    final SpaceImageViewer viewer = await buildViewer(
      platform: TargetPlatform.windows,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: viewer,
      ),
    );
    await tester.pumpAndSettle();

    // Starts on the middle image, so both arrows are available.
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.byKey(SpaceImageViewer.previousKey), findsOneWidget);
    expect(find.byKey(SpaceImageViewer.nextKey), findsOneWidget);

    await tester.tap(find.byKey(SpaceImageViewer.nextKey));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);

    // The last image has no further page, so the forward arrow is gone.
    expect(find.byKey(SpaceImageViewer.nextKey), findsNothing);
    expect(find.byKey(SpaceImageViewer.previousKey), findsOneWidget);

    await tester.tap(find.byKey(SpaceImageViewer.previousKey));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('mobile keeps swipe only, no arrows', (
    WidgetTester tester,
  ) async {
    final SpaceImageViewer viewer = await buildViewer(
      platform: TargetPlatform.android,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: viewer,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.byKey(SpaceImageViewer.previousKey), findsNothing);
    expect(find.byKey(SpaceImageViewer.nextKey), findsNothing);
  });

  testWidgets('arrow keys page the viewer', (WidgetTester tester) async {
    final SpaceImageViewer viewer = await buildViewer(
      platform: TargetPlatform.linux,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: viewer,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 / 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('saving a picture twice asks before the second copy', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.imageBytes['img-1'] = spaceTinyPng;
    final List<String> saved = <String>[];
    final SpaceDownloadLog log = SpaceDownloadLog(scopeKey: 'test-scope');

    await tester.pumpWidget(
      MaterialApp(
        home: SpaceImageViewer(
          images: <SpaceImage>[spaceImage(imageId: 'img-1')],
          initialIndex: 0,
          loader: SpaceImageLoader(gateway),
          downloadLog: log,
          saver: (SpaceImage image, Uint8List bytes) async {
            saved.add(image.imageId);
            return '/tmp/${image.imageId}.png';
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // First save goes through without a prompt.
    await tester.tap(find.byKey(SpaceImageViewer.saveKey));
    await tester.pumpAndSettle();
    expect(saved.length, 1);
    expect(log.find('img-1'), isNotNull);

    // Second save asks; cancelling leaves the count untouched.
    await tester.tap(find.byKey(SpaceImageViewer.saveKey));
    await tester.pumpAndSettle();
    expect(find.text('这张图保存过'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saved.length, 1);

    // Confirming saves anyway.
    await tester.tap(find.byKey(SpaceImageViewer.saveKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然保存'));
    await tester.pumpAndSettle();
    expect(saved.length, 2);
  });
}
