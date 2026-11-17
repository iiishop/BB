import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

void main() {
  testWidgets('tapping a card author opens the shared home page and back '
      'keeps the feed position', (WidgetTester tester) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost post = spacePost(postId: 'post-1', text: '点我头像');
    gateway.posts['post-1'] = post;
    gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
    await pumpSpacePage(
      tester,
      gateway: gateway,
      profile: FakeProfileGateway(),
    );

    expect(find.byKey(const Key('space-post-author-post-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('space-post-author-post-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(SpaceProfilePage.pageKey), findsOneWidget);
    expect(find.byKey(SpaceProfilePage.identityKey), findsOneWidget);
    // The home timeline is the author-scoped page, not the global feed.
    expect(gateway.requestedAuthors, isNotEmpty);
    expect(gateway.requestedAuthors.last, post.author.account);

    await tester.tap(find.byKey(SpaceProfilePage.backKey));
    await tester.pumpAndSettle();

    expect(find.byKey(SpaceProfilePage.pageKey), findsNothing);
    expect(find.byKey(SpacePage.pageKey), findsOneWidget);
    expect(find.text('点我头像'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Profile panel offers the same home page entry', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final FakeProfileGateway profile = FakeProfileGateway();
    final AuthUser user = AuthUser(
      account: profile.profile.account,
      username: profile.profile.username,
    );
    ProfilePanelResult? captured;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  captured = await openProfilePanel(
                    context,
                    gateway: profile,
                    user: user,
                    onLogout: () async =>
                        const LogoutResult(serverNotified: true),
                  );
                },
                child: const Text('open-profile'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-profile'));
    await tester.pumpAndSettle();

    expect(find.byKey(ProfilePanel.homeButtonKey), findsOneWidget);
    await tester.tap(find.byKey(ProfilePanel.homeButtonKey));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.openHomeAccount, profile.profile.account);
  });

  testWidgets('a space card without a host profile keeps the avatar inert', (
    WidgetTester tester,
  ) async {
    // The card is reused by hosts that cannot open a home page (e.g. the
    // standalone read-only render); the author area must not look tappable.
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost post = spacePost(postId: 'post-1');
    gateway.postPages[''] = spacePagePost(<SpacePost>[post]);
    await pumpSpacePage(tester, gateway: gateway);

    expect(find.byKey(const Key('space-post-author-post-1')), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('space-post-author-post-1')))
          .onTap,
      isNotNull,
    );
  });
}
