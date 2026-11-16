import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_compose_page.dart';
import 'package:bb_client/ui/space/space_detail_view.dart';
import 'package:bb_client/ui/space/space_lists_view.dart';
import 'package:bb_client/ui/space/space_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

FakeSpaceGateway notificationGateway(List<SpaceNotification> items) {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  final SpacePost post = spacePost(postId: 'post-1', text: '被互动的说说');
  gateway.posts['post-1'] = post;
  gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
  gateway.notificationPage = spacePageNotification(items);
  gateway.commentPages['post-1||'] = spacePageComment(const <SpaceComment>[]);
  return gateway;
}

void main() {
  testWidgets('notification rows show live kinds and deleted targets', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = notificationGateway(<SpaceNotification>[
      spaceNotification(
        notificationId: 'n-like',
        kind: 'like',
        version: 3,
        actorCount: 3,
        actors: <SpaceAuthor>[
          spaceAuthor(account: spacePeerAccount, username: 'bob'),
          spaceAuthor(account: spaceThirdAccount, username: 'carol'),
          spaceAuthor(account: '10000004', username: 'dave'),
        ],
      ),
      spaceNotification(
        notificationId: 'n-comment',
        kind: 'comment',
        version: 1,
        commentId: 'comment-1',
        snippet: '说得很对',
      ),
      spaceNotification(
        notificationId: 'n-deleted',
        kind: 'repost',
        version: 5,
        deleted: true,
        accessible: false,
        snippet: null,
      ),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('等 3 人赞了你的说说'), findsOneWidget);
    expect(find.textContaining('评论了你的说说'), findsOneWidget);
    expect(find.text('内容已删除'), findsOneWidget);
    expect(
      find.byKey(SpaceNotificationsView.unreadKey('n-like')),
      findsOneWidget,
    );
    // Reading the list acknowledges nothing.
    expect(gateway.ackCalls, isEmpty);
  });

  testWidgets(
    'tapping a notification opens the target and acknowledges its version',
    (WidgetTester tester) async {
      final SpaceNotification notification = spaceNotification(
        notificationId: 'n-comment',
        kind: 'comment',
        commentId: 'comment-1',
        version: 7,
        snippet: '来说一句',
      );
      final FakeSpaceGateway gateway = notificationGateway(<SpaceNotification>[
        notification,
      ]);
      await pumpSpacePage(tester, gateway: gateway);
      await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpaceNotificationsView.rowKey('n-comment')));
      await tester.pumpAndSettle();
      expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);
      expect(gateway.ackCalls.single.single.notificationId, 'n-comment');
      expect(gateway.ackCalls.single.single.version, 7);
    },
  );

  testWidgets('deleted target acknowledges without a broken detail', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = notificationGateway(<SpaceNotification>[
      spaceNotification(
        notificationId: 'n-gone',
        kind: 'comment',
        version: 2,
        deleted: true,
        accessible: false,
        snippet: null,
      ),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceNotificationsView.rowKey('n-gone')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceDetailView.detailKey), findsNothing);
    expect(gateway.ackCalls.single.single.version, 2);
    expect(gateway.getPostCalls, isEmpty);
  });

  testWidgets('"全部标读" is explicit and only covers observed versions', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = notificationGateway(<SpaceNotification>[
      spaceNotification(notificationId: 'n1', version: 1, kind: 'like'),
      spaceNotification(notificationId: 'n2', version: 4, kind: 'comment'),
    ]);
    gateway.overviewResult = spaceOverview(unreadNotifications: 2);
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
    await tester.pumpAndSettle();
    expect(gateway.ackCalls, isEmpty);
    await tester.tap(find.byKey(SpaceNotificationsView.ackAllKey));
    await tester.pumpAndSettle();
    expect(
      gateway.ackCalls.single
          .map((SpaceAckVersion v) => '${v.notificationId}:${v.version}')
          .toList(),
      <String>['n1:1', 'n2:4'],
    );
    expect(find.byKey(SpaceNotificationsView.unreadKey('n1')), findsNothing);
    expect(find.byKey(SpaceNotificationsView.unreadKey('n2')), findsNothing);
  });

  testWidgets('notification read failure is an error, not an empty list', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = notificationGateway(<SpaceNotification>[]);
    gateway.failNext('list_notifications', upstreamUnavailable);
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(SpaceSectionHeader.notificationsKey));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceNotificationsView.errorKey), findsOneWidget);
    expect(find.text('通知读取失败'), findsOneWidget);
    expect(find.text('还没有互动通知'), findsNothing);
  });

  testWidgets(
    'draft box continues an existing draft and discards from the list',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(postId: 'post-1'),
      ]);
      gateway.drafts['draft-a'] = spaceDraft(
        draftId: 'draft-a',
        version: 3,
        text: '还没发布的草稿',
        images: <SpaceImage>[spaceImage(imageId: 'img-1')],
      );
      await pumpSpacePage(tester, gateway: gateway);
      await tester.tap(find.byKey(SpaceSectionHeader.draftsKey));
      await tester.pumpAndSettle();
      expect(find.byKey(SpaceDraftsView.viewKey), findsOneWidget);
      expect(find.text('还没发布的草稿'), findsOneWidget);
      expect(find.textContaining('3 张图片'), findsNothing);
      expect(find.textContaining('1 张图片'), findsOneWidget);

      await tester.tap(find.byKey(SpaceDraftsView.rowKey('draft-a')));
      await tester.pumpAndSettle();
      expect(find.byKey(SpaceComposePage.composeKey), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(SpaceComposePage.textKey))
            .controller!
            .text,
        '还没发布的草稿',
      );
      await tester.tap(find.byKey(SpaceComposePage.closeKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SpaceDraftsView.discardKey('draft-a')));
      await tester.pumpAndSettle();
      expect(gateway.drafts, isEmpty);
      expect(find.text('没有草稿'), findsOneWidget);
    },
  );
}
