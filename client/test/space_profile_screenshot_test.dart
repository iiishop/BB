import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_space_profile_gateway.dart';
import 'support/space_fixtures.dart';

/// Renders the home page at phone, PC and simulated-fold sizes.
///
/// Opt-in because it writes files:
///   QA_SPACE_PROFILE_SCREENSHOT_DIR=`<repo>/docs/evidence/dea485-client/screenshots` \
///   QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///   QA_ICON_FONT=$HOME/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
///   flutter test test/space_profile_screenshot_test.dart --update-goldens
///
/// These are widget-test renders against a test double, not Android/Windows or
/// real-device screenshots. The evidence note records that explicitly.
void main() {
  final String? outputDir =
      Platform.environment['QA_SPACE_PROFILE_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_SPACE_PROFILE_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture the home page in three form factors', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory(outputDir!);
    directory.createSync(recursive: true);
    await _loadFonts(tester, fontPath, iconFontPath);

    final FakeSpaceProfileGateway gateway = _screenshotGateway();
    final FakeSpaceGateway space = FakeSpaceGateway(account: spaceSelfAccount);
    final GlobalKey boundary = GlobalKey();

    Future<void> pumpAt(
      Size size, {
      List<DisplayFeature> features = const <DisplayFeature>[],
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(size: size, displayFeatures: features),
              child: child!,
            ),
            home: Scaffold(
              body: SpaceProfilePage(
                gateway: gateway,
                userId: gateway.account,
                viewerAccount: gateway.viewer,
                images: SpaceImageLoader(space),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile('${directory.path}${Platform.pathSeparator}$name'),
      );
    }

    await pumpAt(const Size(390, 844));
    await capture('space-profile-phone.png');

    await tester.tap(find.byKey(SpaceProfilePage.dateButtonKey));
    await tester.pumpAndSettle();
    await capture('space-profile-phone-directory.png');
    await tester.tap(find.text('10 月'));
    await tester.pumpAndSettle();
    await capture('space-profile-phone-october.png');

    await pumpAt(const Size(1440, 900));
    await capture('space-profile-wide.png');

    await pumpAt(
      const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 1, 768),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await capture('space-profile-fold.png');
  }, skip: skipReason != null);
}

FakeSpaceProfileGateway _screenshotGateway() {
  final SpaceProfileMonth nov = const SpaceProfileMonth(year: 2026, month: 11);
  final SpaceProfileMonth oct = const SpaceProfileMonth(year: 2026, month: 10);
  final SpaceProfileMonth sep = const SpaceProfileMonth(year: 2026, month: 9);
  final SpaceProfileMonth jul = const SpaceProfileMonth(year: 2026, month: 7);
  final SpaceProfileMonth dec2025 = const SpaceProfileMonth(
    year: 2025,
    month: 12,
  );
  final SpaceAuthor owner = spaceAuthor(
    account: spacePeerAccount,
    username: '阿坡',
    avatarUrl: '',
  );
  final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway(
    identity: SpaceProfileIdentity(
      account: spacePeerAccount,
      username: '阿坡',
      signature: '在海边写代码，偶尔拍照。',
    ),
  );
  gateway.followingState = true;
  gateway.monthList.addAll(<SpaceProfileMonth>[nov, oct, sep, jul, dec2025]);
  gateway.putPage(
    items: <SpaceProfileEntry>[
      profileEntry(
        postId: 'post-photo',
        author: owner,
        timelineAt: '2026-11-16T09:10:00Z',
        text: '傍晚的风把海面吹出一条一条的线。最近在整理八月到现在的照片，慢慢发。',
        likeCount: 12,
        commentCount: 3,
      ),
      profileEntry(
        postId: 'post-repost',
        author: owner,
        timelineAt: '2026-11-14T08:30:00Z',
        postCreatedAt: '2026-08-20T08:30:00Z',
        text: '转给也喜欢唱片的人。',
        reference: spaceReference(
          postId: 'post-ref',
          author: spaceAuthor(account: spaceThirdAccount, username: '青禾'),
          text: '周末的唱片店，人不多。',
        ),
        repostCount: 2,
      ),
      profileEntry(
        postId: 'post-late-oct',
        author: owner,
        timelineAt: '2026-10-30T12:00:00Z',
        text: '十月最后几天，把阳台的灯换成暖色。',
        likeCount: 5,
      ),
    ],
  );
  gateway.putPage(
    month: oct,
    items: <SpaceProfileEntry>[
      profileEntry(
        postId: 'post-oct-start',
        author: owner,
        timelineAt: '2026-10-30T12:00:00Z',
        text: '从十月最新的一条开始，往下还能继续读到九月和七月。',
      ),
      profileEntry(
        postId: 'post-oct-early',
        author: owner,
        timelineAt: '2026-10-03T12:00:00Z',
        text: '十月初。',
      ),
    ],
  );
  gateway.putPage(
    month: sep,
    items: <SpaceProfileEntry>[
      profileEntry(
        postId: 'post-sep',
        author: owner,
        timelineAt: '2026-09-18T12:00:00Z',
        text: '九月。',
      ),
    ],
  );
  return gateway;
}

Future<void> _loadFonts(
  WidgetTester tester,
  String? fontPath,
  String? iconFontPath,
) async {
  if (fontPath != null && File(fontPath).existsSync()) {
    final Uint8List bytes = File(fontPath).readAsBytesSync();
    await tester.runAsync(() async {
      for (final String family in <String>['Roboto', 'Ahem']) {
        await (FontLoader(
          family,
        )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
      }
    });
  }
  if (iconFontPath != null && File(iconFontPath).existsSync()) {
    final Uint8List bytes = File(iconFontPath).readAsBytesSync();
    await tester.runAsync(() async {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
    });
  }
}
