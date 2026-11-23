import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/ui/profile/profile_artwork.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';

const AuthUser _user = AuthUser(account: '40218765', username: 'muse.tester');

/// DEA-492 cover: default wave, own upload, re-open freshness, failure keeps
/// the previous image.
void main() {
  late FakeProfileGateway gateway;

  final Uint8List coverA = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1]);
  final Uint8List coverB = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 2]);

  setUp(() {
    gateway = FakeProfileGateway();
  });

  CoverImage cover(Uint8List bytes, {bool isDefault = false}) => CoverImage(
    account: '40218765',
    bytes: bytes,
    version: 'sha256-${String.fromCharCode(97 + bytes.last) * 64}',
    mimeType: 'image/png',
    isDefault: isDefault,
  );

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => openProfilePanel(
                  context,
                  gateway: gateway,
                  user: _user,
                  avatarDecodeCheck: (Uint8List _) async => true,
                  onLogout: () async =>
                      const LogoutResult(serverNotified: true),
                ),
                child: const Text('open-profile'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsOneWidget);
  }

  Finder coverImage() => find.descendant(
    of: find.byKey(ProfileSeaCover.coverKey),
    matching: find.byType(Image),
  );

  MemoryImage shownCover(WidgetTester tester) {
    final Image image = tester.widget<Image>(coverImage().first);
    return image.image as MemoryImage;
  }

  testWidgets('no custom cover shows the packaged sea wave', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);
    expect(gateway.loadCoverCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an uploaded cover replaces the default image', (
    WidgetTester tester,
  ) async {
    gateway.cover = cover(coverA);
    await pumpHost(tester);
    expect(shownCover(tester).bytes, coverA);
    expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsNothing);
  });

  testWidgets('the edit sheet offers a cover entry with the 8 MB hint', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    await tester.tap(find.byKey(ProfilePanel.editProfileKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ProfilePanel.changeCoverKey), findsOneWidget);
    expect(find.text('封面'), findsOneWidget);

    await tester.tap(find.byKey(ProfilePanel.changeCoverKey));
    await tester.pumpAndSettle();
    expect(find.text('更换封面'), findsOneWidget);
    expect(find.textContaining('8 MB'), findsWidgets);
  });

  testWidgets('uploading from the page shows the new cover', (
    WidgetTester tester,
  ) async {
    gateway.cover = cover(coverA);
    await pumpHost(tester);
    await tester.tap(find.byKey(ProfilePanel.editProfileKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ProfilePanel.changeCoverKey));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Base64'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('avatar-source-field')),
      'data:image/png;base64,${base64Encode(coverB)}',
    );
    await tester.tap(find.byKey(const Key('avatar-source-apply')));
    await tester.pumpAndSettle();

    expect(gateway.coverSources.single, startsWith('base64:'));
    expect(find.textContaining('封面已更新'), findsOneWidget);
    expect(shownCover(tester).bytes, coverB);
  });

  testWidgets('a failed upload keeps the previous cover on screen', (
    WidgetTester tester,
  ) async {
    gateway.cover = cover(coverA);
    await pumpHost(tester);
    await tester.tap(find.byKey(ProfilePanel.editProfileKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ProfilePanel.changeCoverKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Base64'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('avatar-source-field')),
      'data:image/png;base64,${base64Encode(coverB)}',
    );
    gateway.coverUpdateFailure = const AuthFailure(
      status: 503,
      code: 'storage_unavailable',
      message: '存储暂不可用',
    );
    await tester.tap(find.byKey(const Key('avatar-source-apply')));
    await tester.pumpAndSettle();

    expect(find.text('存储暂不可用'), findsOneWidget);
    expect(find.textContaining('封面已更新'), findsNothing);
    expect(shownCover(tester).bytes, coverA);
  });

  testWidgets('reopening the page shows the server cover', (
    WidgetTester tester,
  ) async {
    gateway.cover = cover(coverA);
    await pumpHost(tester);
    expect(shownCover(tester).bytes, coverA);

    await tester.tap(find.byKey(ProfilePanel.closeButtonKey));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePanel), findsNothing);

    // Another client replaces the cover; the next open must revalidate.
    gateway.cover = cover(coverB);
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();
    expect(gateway.loadCoverCalls, greaterThanOrEqualTo(2));
    expect(shownCover(tester).bytes, coverB);
  });

  testWidgets('a cover read failure keeps the page usable with the default', (
    WidgetTester tester,
  ) async {
    gateway.coverFailure = const AuthFailure(
      status: 503,
      code: 'storage_unavailable',
      message: '存储暂不可用',
    );
    await pumpHost(tester);
    expect(find.byKey(ProfilePanel.panelKey), findsOneWidget);
    expect(find.byKey(ProfileSeaCover.defaultCoverKey), findsOneWidget);
    expect(find.byKey(ProfilePanel.nicknameValueKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
