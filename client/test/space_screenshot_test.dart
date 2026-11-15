import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_detail_view.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:bb_client/ui/space/space_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/space_fixtures.dart';

const String _photoOneBase64 =
    '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';
const String _photoTwoBase64 =
    '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';

/// Renders the Space surface at phone, PC and simulated-fold sizes.
///
/// Opt-in because it writes files:
///   QA_SPACE_SCREENSHOT_DIR=.qa-artifacts/space-screenshots \
///   QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///   QA_ICON_FONT=/home/iiishop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
///   flutter test test/space_screenshot_test.dart --update-goldens
///
/// These are widget-test renders, not Android/Windows/fold-device screenshots.
void main() {
  final String? outputDir = Platform.environment['QA_SPACE_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_SPACE_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture Space in three form factors', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory(outputDir!);
    directory.createSync(recursive: true);
    await _loadFonts(tester, fontPath, iconFontPath);

    final FakeSpaceGateway gateway = _screenshotGateway();
    final SpaceLocalStore store = SpaceLocalStore(scopeKey: gateway.scopeKey);
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
              body: SpacePage(
                gateway: gateway,
                store: store,
                autoPoll: false,
                pollInterval: null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Decode the photo bytes on a real engine task before rasterizing.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> capture(String name) async {
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile('${directory.path}${Platform.pathSeparator}$name'),
      );
    }

    await pumpAt(const Size(390, 844));
    await capture('space-feed-phone.png');
    await tester.tap(find.byKey(const Key('space-post-body-post-photo')));
    await tester.pumpAndSettle();
    await capture('space-detail-phone.png');

    await pumpAt(const Size(1440, 900));
    await tester.tap(find.byKey(const Key('space-post-body-post-photo')));
    await tester.pumpAndSettle();
    await capture('space-detail-wide.png');
    await tester.tap(find.byKey(SpaceDetailView.closeKey));
    await tester.pumpAndSettle();
    await capture('space-feed-wide.png');

    await pumpAt(
      const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('space-post-body-post-photo')));
    await tester.pumpAndSettle();
    await capture('space-detail-folded.png');

    await pumpAt(const Size(390, 844));
    await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
    await tester.pumpAndSettle();
    await capture('space-notifications-phone.png');

    await pumpAt(const Size(1440, 900));
    await tester.tap(find.byKey(SpaceSectionHeader.publishKey));
    await tester.pumpAndSettle();
    await capture('space-compose-wide.png');

    for (final String name in <String>[
      'space-feed-phone.png',
      'space-detail-phone.png',
      'space-detail-wide.png',
      'space-feed-wide.png',
      'space-detail-folded.png',
      'space-notifications-phone.png',
      'space-compose-wide.png',
    ]) {
      expect(
        File('${directory.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);

  testWidgets('capture the signed-in shell in three form factors', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory(outputDir!);
    directory.createSync(recursive: true);
    await _loadFonts(tester, fontPath, iconFontPath);

    final FakeSpaceGateway gateway = _screenshotGateway();
    final GlobalKey boundary = GlobalKey();
    final FakeChatService chat = FakeChatService(
      self: const AuthUser(account: spaceSelfAccount, username: '小鹿'),
      users: const <ChatUser>[],
    );
    final FakeProfileGateway profile = FakeProfileGateway(
      profile: const Profile(
        account: spaceSelfAccount,
        username: '小鹿',
        signature: null,
        avatarUrl: '',
        avatarVersion: 'v1',
      ),
    );
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);

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
            home: HomeView(
              user: const AuthUser(account: spaceSelfAccount, username: '小鹿'),
              profile: profile,
              auth: FakeAuthGateway(),
              heartbeat: heartbeat,
              chat: chat,
              space: gateway,
              onSignedOut: (LogoutResult? result) {},
              onSessionExpired: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> capture(String name) async {
      await expectLater(
        find.byKey(boundary),
        matchesGoldenFile('${directory.path}${Platform.pathSeparator}$name'),
      );
    }

    await pumpAt(const Size(390, 844));
    await tester.tap(find.text('BB空间'));
    await tester.pumpAndSettle();
    await capture('space-shell-phone.png');

    await pumpAt(const Size(1440, 900));
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    await capture('space-shell-wide.png');

    await pumpAt(
      const Size(1024, 768),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(512, 0, 0, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    await tester.tap(find.byKey(HomeView.navSpaceKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('space-post-body-post-photo')));
    await tester.pumpAndSettle();
    await capture('space-shell-folded.png');

    for (final String name in <String>[
      'space-shell-phone.png',
      'space-shell-wide.png',
      'space-shell-folded.png',
    ]) {
      expect(
        File('${directory.path}${Platform.pathSeparator}$name').existsSync(),
        isTrue,
      );
    }
    expect(tester.takeException(), isNull);
  }, skip: skipReason != null);
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

FakeSpaceGateway _screenshotGateway() {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  final SpaceAuthor alice = spaceAuthor(
    account: spaceSelfAccount,
    username: '小鹿',
  );
  final SpaceAuthor bob = spaceAuthor(
    account: spacePeerAccount,
    username: '阿坡',
  );
  final SpaceAuthor carol = spaceAuthor(
    account: spaceThirdAccount,
    username: '青禾',
  );
  final List<SpaceImage> photos = <SpaceImage>[
    for (int i = 0; i < 10; i++)
      spaceImage(imageId: 'photo-$i', filename: '海边 $i.png'),
  ];
  final SpaceComment root = spaceComment(
    commentId: 'root-1',
    postId: 'post-photo',
    author: bob,
    text: '第九张的浪花好看，是哪一段海岸？',
    createdAt: '2026-11-15T09:40:00Z',
  );
  final SpaceComment reply = spaceComment(
    commentId: 'reply-1',
    postId: 'post-photo',
    rootId: 'root-1',
    replyToId: 'root-1',
    replyToAuthor: bob,
    author: alice,
    text: '在岛东边，早上六点的光。',
    createdAt: '2026-11-15T09:42:00Z',
  );
  final SpaceComment deep = spaceComment(
    commentId: 'reply-2',
    postId: 'post-photo',
    rootId: 'root-1',
    replyToId: 'reply-1',
    replyToAuthor: alice,
    author: carol,
    text: '下次带我一起。',
    createdAt: '2026-11-15T09:44:00Z',
  );

  final SpacePost photoPost = spacePost(
    postId: 'post-photo',
    author: alice,
    text:
        '今天沿着海岸走了很久。风把云推得很低，海面一层一层地亮起来。'
        '这是最近最喜欢的一段路，想留在这里。',
    createdAt: '2026-11-15T09:30:00Z',
    images: photos,
    likeCount: 12,
    commentCount: 6,
    rootCount: 2,
    repostCount: 2,
    viewCount: 48,
    canDelete: true,
    canListVisitors: true,
    previewComments: <SpaceBranch>[
      spaceBranch(
        root: root,
        replies: <SpaceComment>[reply, deep],
        remainingReplies: 1,
      ),
      spaceBranch(
        root: spaceComment(
          commentId: 'root-2',
          postId: 'post-photo',
          author: carol,
          text: '收藏了。',
          createdAt: '2026-11-15T09:50:00Z',
        ),
      ),
    ],
    remainingRoots: 1,
  );
  final SpacePost referencePost = spacePost(
    postId: 'post-ref',
    author: bob,
    text: '周末的唱片店，人不多。',
    createdAt: '2026-11-15T08:10:00Z',
    images: <SpaceImage>[spaceImage(imageId: 'ref-photo')],
  );
  final SpacePost repost = spacePost(
    postId: 'post-repost',
    author: carol,
    text: '转给也喜欢唱片的人。',
    createdAt: '2026-11-15T08:30:00Z',
    reference: spaceReference(
      postId: referencePost.postId,
      author: bob,
      text: referencePost.text,
    ),
    likeCount: 3,
    viewCount: 9,
  );
  gateway.posts[photoPost.postId] = photoPost;
  gateway.posts[referencePost.postId] = referencePost;
  gateway.posts[repost.postId] = repost;
  gateway.postPages[''] = spacePagePost(<SpacePost>[photoPost, repost]);
  gateway.commentPages['post-photo||'] = spacePageComment(<SpaceComment>[
    root,
    spaceComment(commentId: 'root-2', postId: 'post-photo', text: '收藏了。'),
  ]);
  gateway.notificationPage = spacePageNotification(<SpaceNotification>[
    spaceNotification(
      notificationId: 'n-like',
      kind: 'like',
      version: 4,
      actorCount: 3,
      actors: <SpaceAuthor>[bob, carol],
      postId: 'post-photo',
    ),
    spaceNotification(
      notificationId: 'n-comment',
      kind: 'comment',
      version: 2,
      commentId: 'root-1',
      postId: 'post-photo',
      snippet: '第九张的浪花好看',
      actors: <SpaceAuthor>[bob],
    ),
  ]);
  gateway.overviewResult = spaceOverview(
    unreadNotifications: 2,
    unreadPosts: 3,
  );
  for (int i = 0; i < 10; i++) {
    gateway.imageBytes['photo-$i'] = base64Decode(
      i.isEven ? _photoOneBase64 : _photoTwoBase64,
    );
  }
  gateway.imageBytes['ref-photo'] = base64Decode(_photoTwoBase64);
  return gateway;
}
