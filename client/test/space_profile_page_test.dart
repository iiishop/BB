import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/ui/space/space_format.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/profile/space_profile_month_directory.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:bb_client/ui/space/profile/space_profile_posts_module.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/fake_space_profile_gateway.dart';
import 'support/space_fixtures.dart';

const SpaceProfileMonth _nov = SpaceProfileMonth(year: 2026, month: 11);
const SpaceProfileMonth _oct = SpaceProfileMonth(year: 2026, month: 10);
const SpaceProfileMonth _sep = SpaceProfileMonth(year: 2026, month: 9);

void main() {
  testWidgets('renders identity and the reused post cards', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    await _pumpProfile(tester, gateway: gateway);

    expect(find.byKey(SpaceProfilePage.pageKey), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('在海边写代码。'), findsOneWidget);
    expect(find.byKey(const Key('space-post-post-nov-1')), findsOneWidget);
    expect(find.byKey(SpaceProfilePostsModule.listKey), findsOneWidget);
    // The author-scoped timeline is requested, not the global feed.
    expect(gateway.calls.single.userId, gateway.account);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a repost row is displayed and archived by the repost time', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    // Reposted in November; the original was published in August.
    final SpaceProfileEntry entry = profileEntry(
      postId: 'post-repost',
      timelineAt: '2026-11-10T12:00:00Z',
      postCreatedAt: '2026-08-10T12:00:00Z',
      text: '转发了八月的一条原文',
    );
    gateway.putPage(items: <SpaceProfileEntry>[entry]);
    await _pumpProfile(tester, gateway: gateway);

    expect(
      find.text(spaceRelativeTime(entry.timelineAt)),
      findsOneWidget,
      reason:
          'the card must show the timeline time, not the original post time',
    );
    expect(find.text(spaceRelativeTime(entry.post.createdAt)), findsNothing);
    expect(_dateLabel(tester), '2026 年 11 月');
  });

  testWidgets('narrow layout opens a month drawer, jumps and closes', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    await _pumpProfile(tester, gateway: gateway);

    expect(find.byKey(SpaceProfilePage.sideDirectoryKey), findsNothing);
    expect(_dateLabel(tester), '2026 年 11 月');

    await tester.tap(find.byKey(SpaceProfilePage.dateButtonKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('space-profile-directory')), findsOneWidget);
    expect(find.text('2026 年'), findsOneWidget);
    expect(find.text('2025 年'), findsOneWidget);
    // The empty August 2026 month is absent because the server did not list it.
    expect(find.byKey(SpaceMonthDirectory.monthKey(2026, 8)), findsNothing);

    await tester.tap(find.byKey(SpaceMonthDirectory.monthKey(2026, 10)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('space-profile-directory')), findsNothing);
    expect(gateway.calls.last.month, _oct);
    expect(find.byKey(const Key('space-post-post-oct-1')), findsOneWidget);
    expect(_dateLabel(tester), '2026 年 10 月');
    expect(tester.takeException(), isNull);
  });

  testWidgets('drawer "回到最新" reloads the newest page', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    await _pumpProfile(tester, gateway: gateway);

    await tester.tap(find.byKey(SpaceProfilePage.dateButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceMonthDirectory.monthKey(2026, 9)));
    await tester.pumpAndSettle();
    expect(gateway.calls.last.month, _sep);

    await tester.tap(find.byKey(SpaceProfilePage.dateButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceMonthDirectory.latestKey));
    await tester.pumpAndSettle();

    expect(gateway.calls.last.month, isNull);
    expect(_dateLabel(tester), '2026 年 11 月');
    expect(find.byKey(const Key('space-post-post-nov-1')), findsOneWidget);
  });

  testWidgets('wide layout puts the directory beside the list', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    await _pumpProfile(tester, gateway: gateway, size: const Size(1440, 900));

    expect(find.byKey(SpaceProfilePage.sideDirectoryKey), findsOneWidget);
    expect(find.byKey(SpaceProfilePage.dateButtonKey), findsNothing);
    final Offset directory = tester.getTopLeft(
      find.byKey(SpaceProfilePage.sideDirectoryKey),
    );
    expect(directory.dx, greaterThan(1000));
    expect(directory.dx, lessThan(1200));
    expect(find.byKey(const Key('space-post-post-nov-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat fold puts the directory in the second pane', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    await _pumpProfile(
      tester,
      gateway: gateway,
      size: const Size(1440, 900),
      features: <DisplayFeature>[
        DisplayFeature(
          bounds: const Rect.fromLTWH(700, 0, 1, 900),
          type: DisplayFeatureType.fold,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );

    expect(find.byKey(SpaceProfilePage.sideDirectoryKey), findsOneWidget);
    final Offset directory = tester.getTopLeft(
      find.byKey(SpaceProfilePage.sideDirectoryKey),
    );
    expect(directory.dx, greaterThan(640));
    expect(directory.dx, lessThan(760));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a server without months/follow degrades without dead controls', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory(
      supportsMonths: false,
      supportsFollow: false,
    );
    await _pumpProfile(tester, gateway: gateway);

    expect(find.byKey(SpaceProfilePage.dateButtonKey), findsNothing);
    expect(find.byKey(SpaceProfilePage.sideDirectoryKey), findsNothing);
    expect(find.byKey(SpaceProfilePage.followKey), findsNothing);
    expect(find.byKey(const Key('space-post-post-nov-1')), findsOneWidget);
  });

  testWidgets('the visible month follows scrolling', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    gateway.putPage(items: _scrollingHistory());
    await _pumpProfile(tester, gateway: gateway);
    expect(_dateLabel(tester), '2026 年 11 月');

    await tester.drag(
      find.byKey(SpaceProfilePostsModule.listKey),
      const Offset(0, -2600),
    );
    await tester.pumpAndSettle();

    expect(_dateLabel(tester), isNot('2026 年 11 月'));
    expect(<String>['2026 年 10 月', '2026 年 9 月'], contains(_dateLabel(tester)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed first page offers a retry that really reloads', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    gateway.timelineFailure = const AuthFailure(
      status: 503,
      code: 'upstream_unavailable',
      message: 'offline',
    );
    await _pumpProfile(tester, gateway: gateway);

    expect(find.byKey(SpaceProfilePostsModule.retryKey), findsOneWidget);
    expect(find.byKey(SpaceProfilePostsModule.listKey), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.byKey(SpaceProfilePostsModule.listKey), findsOneWidget);
    expect(find.byKey(const Key('space-post-post-nov-1')), findsOneWidget);
  });

  testWidgets('a month with no visible entries shows its own empty state', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = _gatewayWithHistory();
    gateway.putPage(month: _sep, items: <SpaceProfileEntry>[]);
    await _pumpProfile(tester, gateway: gateway);

    await tester.tap(find.byKey(SpaceProfilePage.dateButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceMonthDirectory.monthKey(2026, 9)));
    await tester.pumpAndSettle();

    expect(find.byKey(SpaceProfilePostsModule.emptyKey), findsOneWidget);
    expect(find.text('这个月份没有可见内容，换个日期看看。'), findsOneWidget);
  });
}

FakeSpaceProfileGateway _gatewayWithHistory({
  bool supportsMonths = true,
  bool supportsFollow = true,
}) {
  final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway(
    supportsMonths: supportsMonths,
    supportsFollow: supportsFollow,
  );
  gateway.monthList.addAll(<SpaceProfileMonth>[
    _nov,
    _oct,
    _sep,
    const SpaceProfileMonth(year: 2025, month: 12),
  ]);
  gateway.putPage(
    items: <SpaceProfileEntry>[
      profileEntry(postId: 'post-nov-1', timelineAt: '2026-11-10T12:00:00Z'),
    ],
  );
  gateway.putPage(
    month: _oct,
    items: <SpaceProfileEntry>[
      profileEntry(postId: 'post-oct-1', timelineAt: '2026-10-10T12:00:00Z'),
    ],
  );
  gateway.putPage(
    month: _sep,
    items: <SpaceProfileEntry>[
      profileEntry(postId: 'post-sep-1', timelineAt: '2026-09-10T12:00:00Z'),
    ],
  );
  return gateway;
}

List<SpaceProfileEntry> _scrollingHistory() {
  final List<SpaceProfileEntry> entries = <SpaceProfileEntry>[];
  for (int i = 0; i < 12; i++) {
    entries.add(
      profileEntry(
        postId: 'post-nov-$i',
        timelineAt: '2026-11-${(15 - i).toString().padLeft(2, '0')}T12:00:00Z',
      ),
    );
  }
  for (int i = 0; i < 12; i++) {
    entries.add(
      profileEntry(
        postId: 'post-oct-$i',
        timelineAt: '2026-10-${(15 - i).toString().padLeft(2, '0')}T12:00:00Z',
      ),
    );
  }
  for (int i = 0; i < 12; i++) {
    entries.add(
      profileEntry(
        postId: 'post-sep-$i',
        timelineAt: '2026-09-${(15 - i).toString().padLeft(2, '0')}T12:00:00Z',
      ),
    );
  }
  return entries;
}

Future<void> _pumpProfile(
  WidgetTester tester, {
  required FakeSpaceProfileGateway gateway,
  Size size = const Size(390, 844),
  List<DisplayFeature> features = const <DisplayFeature>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeSpaceGateway space = FakeSpaceGateway(account: spaceSelfAccount);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
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
  );
  await tester.pumpAndSettle();
}

String _dateLabel(WidgetTester tester) {
  final Finder button = find.byKey(SpaceProfilePage.dateButtonKey);
  if (button.evaluate().isEmpty) {
    return '';
  }
  final Finder label = find.descendant(of: button, matching: find.byType(Text));
  return tester.widget<Text>(label.first).data ?? '';
}
