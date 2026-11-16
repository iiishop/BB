import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_compose_page.dart';
import 'package:bb_client/ui/space/space_detail_view.dart';
import 'package:bb_client/ui/space/space_lists_view.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:bb_client/ui/space/space_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

FakeSpaceGateway gatewayWith(List<SpacePost> posts) {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  for (final SpacePost post in posts) {
    gateway.posts[post.postId] = post;
  }
  gateway.postPages[''] = spacePagePost(posts);
  return gateway;
}

void main() {
  testWidgets('feed shows loading then contract-valid posts', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      spacePost(postId: 'post-1', text: '第一条'),
      spacePost(postId: 'post-2', text: '第二条', viewCount: 12),
    ]);
    await pumpSpacePage(tester, gateway: gateway, settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('space-post-post-1')), findsOneWidget);
    expect(find.byKey(const Key('space-post-post-2')), findsOneWidget);
    expect(find.text('浏览 12'), findsOneWidget);
  });

  testWidgets('empty, offline and old-server states are distinct', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway empty = FakeSpaceGateway();
    await pumpSpacePage(tester, gateway: empty);
    expect(find.text('还没有说说'), findsOneWidget);

    final FakeSpaceGateway offline = FakeSpaceGateway();
    offline.failNext('list_posts', upstreamUnavailable);
    await pumpSpacePage(
      tester,
      gateway: offline,
      pageKey: const Key('offline-space'),
    );
    expect(find.byKey(SpacePage.retryKey), findsOneWidget);
    expect(find.text('暂时无法连接服务器'), findsOneWidget);

    final FakeSpaceGateway old = FakeSpaceGateway();
    old.failNext(
      'overview',
      const AuthFailure(
        status: 404,
        code: 'unsupported_space',
        message: 'unsupported',
      ),
    );
    old.failNext(
      'list_posts',
      const AuthFailure(
        status: 404,
        code: 'unsupported_space',
        message: 'unsupported',
      ),
    );
    await pumpSpacePage(tester, gateway: old, pageKey: const Key('old-space'));
    expect(find.byKey(SpacePage.capabilityKey), findsOneWidget);
    expect(find.text('当前服务器不支持 BB 空间'), findsOneWidget);
  });

  testWidgets('long body clamps at four lines and opens detail', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      spacePost(postId: 'post-long', text: '海风' * 220),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    final Key expand = Key('space-post-expand-post-long');
    expect(find.byKey(expand), findsOneWidget);
    await tester.tap(find.byKey(expand));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    expect(find.byKey(SpaceDetailView.bodyKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('body tap opens detail; action taps do not', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      spacePost(postId: 'post-1', likeCount: 1),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(const Key('space-post-like-post-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsNothing);
    expect(gateway.likeCalls.single.liked, isTrue);
    expect(
      tester.widget<SpacePostCard>(find.byType(SpacePostCard)).post.likeCount,
      2,
    );
    expect(find.text('2'), findsWidgets);

    await tester.tap(find.byKey(const Key('space-post-body-post-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    expect(gateway.getPostCalls.single.postId, 'post-1');
    expect(gateway.getPostCalls.single.visitId, isNotNull);
    expect(gateway.markReadCalls.single, <String>['post-1']);
  });

  testWidgets('image grid previews nine with hidden count and no fake gaps', (
    WidgetTester tester,
  ) async {
    final List<SpaceImage> ten = <SpaceImage>[
      for (int i = 0; i < 10; i++)
        spaceImage(imageId: 'img-$i', filename: '$i.png'),
    ];
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      spacePost(postId: 'post-many', images: ten),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    for (int i = 0; i < 9; i++) {
      expect(find.byKey(Key('space-image-img-$i')), findsOneWidget);
    }
    expect(find.byKey(const Key('space-image-img-9')), findsNothing);
    expect(find.byKey(const Key('space-image-more')), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    final FakeSpaceGateway seven = gatewayWith(<SpacePost>[
      spacePost(
        postId: 'post-seven',
        images: <SpaceImage>[
          for (int i = 0; i < 7; i++) spaceImage(imageId: 'seven-$i'),
        ],
      ),
    ]);
    await pumpSpacePage(
      tester,
      gateway: seven,
      pageKey: const Key('seven-space'),
    );
    for (int i = 0; i < 7; i++) {
      expect(find.byKey(Key('space-image-seven-$i')), findsOneWidget);
    }
    expect(find.byKey(const Key('space-image-more')), findsNothing);
  });

  testWidgets('feed scroll position survives an open/close detail', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      for (int i = 0; i < 18; i++)
        spacePost(postId: 'post-$i', text: '第 $i 条说说'),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    final Finder feed = find.byKey(SpacePage.feedListKey);
    final Finder scrollable = find.descendant(
      of: feed,
      matching: find.byType(Scrollable),
    );
    await tester.drag(feed, const Offset(0, -600));
    await tester.pumpAndSettle();
    final double before = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect(before, greaterThan(0));

    await tester.tap(find.byKey(const Key('space-post-body-post-5')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
    await tester.tap(find.byKey(SpaceDetailView.closeKey));
    await tester.pumpAndSettle();
    final double after = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(SpacePage.feedListKey),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;
    expect(after, before);
  });

  testWidgets('notification badge reflects unread interactions only', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      spacePost(postId: 'post-1'),
    ]);
    gateway.overviewResult = spaceOverview(
      unreadNotifications: 3,
      unreadPosts: 9,
    );
    gateway.notificationPage = spacePageNotification(<SpaceNotification>[
      spaceNotification(notificationId: 'n1', version: 2),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    expect(find.byKey(SpaceSectionHeader.notificationDotKey), findsOneWidget);

    await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceNotificationsView.viewKey), findsOneWidget);
    // Opening the list is not acknowledgement.
    expect(gateway.ackCalls, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(gateway.ackCalls, isEmpty);
  });

  testWidgets('publish entry opens the draft editor', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = gatewayWith(<SpacePost>[
      spacePost(postId: 'post-1'),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(SpaceSectionHeader.publishKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceComposePage.composeKey), findsOneWidget);
    expect(gateway.drafts, isNotEmpty);
  });
}
