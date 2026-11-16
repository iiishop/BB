import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_avatars.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:bb_client/ui/space/space_people_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

FakeSpaceGateway feedWith(List<SpacePost> posts) {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  for (final SpacePost post in posts) {
    gateway.posts[post.postId] = post;
  }
  gateway.postPages[''] = spacePagePost(posts);
  return gateway;
}

SpaceAuthor authorWithAvatar(String account, String username) => spaceAuthor(
  account: account,
  username: username,
  avatarUrl: '/avatars/$account.png',
);

void main() {
  testWidgets('feed avatar renders the authorized Profile bytes, once', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway profile = FakeProfileGateway();
    final FakeSpaceGateway gateway = feedWith(<SpacePost>[
      spacePost(
        postId: 'post-1',
        author: authorWithAvatar('40000002', 'bob'),
        text: '带头像的说说',
      ),
    ]);

    await pumpSpacePage(tester, gateway: gateway, profile: profile);

    expect(
      find.descendant(
        of: find.byKey(const Key('space-post-post-1')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    // The real image replaces the initials placeholder.
    expect(find.text('b'), findsNothing);
    expect(profile.loadAvatarAccounts, <String>['40000002']);

    // A rebuild does not ask again during this visit.
    await tester.pumpAndSettle();
    expect(profile.loadAvatarByAccount['40000002'], 1);
  });

  testWidgets('authors without an advertised avatar keep initials', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway profile = FakeProfileGateway();
    final FakeSpaceGateway gateway = feedWith(<SpacePost>[
      spacePost(
        postId: 'post-1',
        author: spaceAuthor(account: '40000003', username: 'carol'),
        text: '没有头像',
      ),
    ]);

    await pumpSpacePage(tester, gateway: gateway, profile: profile);

    expect(find.text('c'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(profile.loadAvatarCalls, 0);
  });

  testWidgets('failed avatar fetch falls back to initials without retrying', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway profile = FakeProfileGateway()
      ..avatarFailure = const AuthFailure(
        status: 500,
        code: 'upstream_unavailable',
        message: 'avatar unavailable',
      );
    final FakeSpaceGateway gateway = feedWith(<SpacePost>[
      spacePost(
        postId: 'post-1',
        author: authorWithAvatar('40000004', 'dave'),
        text: '头像失败',
      ),
    ]);

    await pumpSpacePage(tester, gateway: gateway, profile: profile);
    expect(find.text('d'), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.pumpAndSettle();
    expect(profile.loadAvatarByAccount['40000004'], 1);
  });

  testWidgets('likes sheet reuses the page avatar store', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway profile = FakeProfileGateway();
    final FakeSpaceGateway gateway = feedWith(<SpacePost>[
      spacePost(
        postId: 'post-1',
        author: authorWithAvatar('40000002', 'bob'),
        text: '点赞名单头像',
        likeCount: 2,
      ),
    ]);
    gateway.likePages['post-1|'] = spacePageAuthor(<SpaceAuthor>[
      authorWithAvatar('40000006', 'frank'),
    ]);

    await pumpSpacePage(tester, gateway: gateway, profile: profile);
    await tester.tap(find.byKey(const Key('space-post-body-post-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 人赞过'));
    await tester.pumpAndSettle();

    expect(find.byType(SpaceLikesSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SpaceLikesSheet),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(profile.loadAvatarAccounts, contains('40000006'));

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('SpacePage without a profile gateway keeps initials', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = feedWith(<SpacePost>[
      spacePost(
        postId: 'post-1',
        author: authorWithAvatar('40000005', 'erin'),
        text: '无 Profile 入口',
      ),
    ]);

    await pumpSpacePage(tester, gateway: gateway);

    expect(find.text('e'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(SpacePage.pageKey), findsOneWidget);
  });

  testWidgets('explicit refresh revalidates author avatars', (
    WidgetTester tester,
  ) async {
    final FakeProfileGateway profile = FakeProfileGateway();
    final FakeSpaceGateway gateway = feedWith(<SpacePost>[
      spacePost(
        postId: 'post-1',
        author: authorWithAvatar('40000007', 'frank'),
        text: '换过头像的用户',
      ),
    ]);

    await pumpSpacePage(tester, gateway: gateway, profile: profile);
    expect(profile.loadAvatarCalls, 1);

    // 头像 store 按「每次访问每个账号只问一次」缓存，页内换头像本来是看不到的。
    // 显式刷新必须重新校验一次（服务端 304 兜底，没变就是零成本）。
    await tester.drag(
      find.byKey(SpacePage.feedListKey),
      const Offset(0, 320),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(profile.loadAvatarCalls, greaterThan(1));
    expect(profile.loadAvatarAccounts.last, '40000007');
  });

  test('reset drops cached avatar bytes so the next load revalidates', () async {
    final FakeProfileGateway profile = FakeProfileGateway();
    final SpaceAvatarStore store = SpaceAvatarStore(profile: profile);

    await store.ensureLoaded('40000008');
    expect(profile.loadAvatarCalls, 1);
    expect(store.bytesFor('40000008'), isNotNull);

    store.reset();
    expect(store.bytesFor('40000008'), isNull);

    await store.ensureLoaded('40000008');
    expect(profile.loadAvatarCalls, 2);
    store.dispose();
  });
}
