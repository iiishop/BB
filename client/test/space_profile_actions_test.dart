import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/profile/space_post_detail_page.dart';
import 'package:bb_client/ui/space/space_detail_view.dart';
import 'package:bb_client/ui/space/space_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_space_profile_gateway.dart';
import 'support/profile_test_harness.dart';

void main() {
  testWidgets('a home-page card likes through the shared Space contract', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    final SpaceProfileEntry entry = _entry(postId: 'post-1');
    space.posts['post-1'] = entry.post;
    final FakeSpaceProfileGateway profile = _profile(<SpaceProfileEntry>[
      entry,
    ]);
    await pumpProfilePage(tester, profile: profile, space: space);

    await tester.tap(find.byKey(const Key('space-post-like-post-1')));
    await tester.pumpAndSettle();

    expect(space.likeCalls.single.liked, isTrue);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  testWidgets('a failed like reverts the card and reports it', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    final SpaceProfileEntry entry = _entry(postId: 'post-1');
    space.posts['post-1'] = entry.post;
    final FakeSpaceProfileGateway profile = _profile(<SpaceProfileEntry>[
      entry,
    ]);
    space.failNext(
      'set_like',
      const AuthFailure(status: 503, code: 'storage_busy', message: 'busy'),
    );
    await pumpProfilePage(tester, profile: profile, space: space);

    await tester.tap(find.byKey(const Key('space-post-like-post-1')));
    await tester.pumpAndSettle();

    expect(space.calls, contains('set_like'));
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    expect(find.text('暂时无法连接服务器，请稍后重试'), findsOneWidget);
  });

  testWidgets('deleting from a card removes it and refreshes the directory', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    final SpaceProfileEntry entry = _entry(postId: 'post-1', canDelete: true);
    space.posts['post-1'] = entry.post;
    final FakeSpaceProfileGateway profile = _profile(<SpaceProfileEntry>[
      entry,
    ]);
    profile.monthList.add(const SpaceProfileMonth(year: 2026, month: 11));
    await pumpProfilePage(tester, profile: profile, space: space);
    final int monthReads = profile.monthOffsets.length;

    await tester.tap(find.byKey(const Key('space-post-delete-post-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('space-post-post-1')), findsNothing);
    expect(profile.monthOffsets.length, greaterThan(monthReads));
    expect(space.calls, contains('delete_post'));
  });

  testWidgets('a card opens the existing detail route and returns to the '
      'home page position', (WidgetTester tester) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    final SpaceProfileEntry entry = _entry(postId: 'post-1');
    space.posts['post-1'] = entry.post;
    final FakeSpaceProfileGateway profile = _profile(<SpaceProfileEntry>[
      entry,
    ]);
    await pumpProfilePage(tester, profile: profile, space: space);

    await tester.tap(find.byKey(const Key('space-post-body-post-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(SpacePostDetailPage.pageKey), findsOneWidget);
    expect(find.byKey(SpaceDetailView.detailKey), findsOneWidget);

    await tester.tap(find.byKey(SpaceDetailView.closeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(SpacePostDetailPage.pageKey), findsNothing);
    expect(find.byKey(const Key('space-post-post-1')), findsOneWidget);
  });

  testWidgets('directory and card dates use the same fixed offset', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway space = FakeSpaceGateway();
    // 23:59Z is still October at UTC but November at +05:45.
    final SpaceProfileEntry entry = _entry(
      postId: 'post-edge',
      timelineAt: '2026-10-31T23:59:59Z',
    );
    space.posts['post-edge'] = entry.post;
    final FakeSpaceProfileGateway profile = _profile(<SpaceProfileEntry>[
      entry,
    ]);
    profile.monthList.add(const SpaceProfileMonth(year: 2026, month: 11));
    await pumpProfilePage(
      tester,
      profile: profile,
      space: space,
      displayOffsetMinutes: 345,
    );

    expect(profile.calls.single.offset, 345);
    expect(profile.monthOffsets.single, 345);
    // The date button shows the archived month under the same offset.
    final Finder label = find.descendant(
      of: find.byKey(const Key('space-profile-date')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(label.first).data, '2026 年 11 月');
    expect(
      find.text(spaceRelativeTime(entry.timelineAt, offsetMinutes: 345)),
      findsOneWidget,
    );
  });
}

SpaceProfileEntry _entry({
  required String postId,
  String timelineAt = '2026-11-10T12:00:00Z',
  bool canDelete = false,
}) {
  return profileEntry(
    postId: postId,
    timelineAt: timelineAt,
    canDelete: canDelete,
    text: '主页上的一条说说',
  );
}

FakeSpaceProfileGateway _profile(List<SpaceProfileEntry> entries) {
  final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
  gateway.putPage(items: entries);
  return gateway;
}
