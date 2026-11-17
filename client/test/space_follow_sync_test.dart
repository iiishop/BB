import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

void main() {
  testWidgets('one follow updates every card and the home page header', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceAuthor peer = spaceAuthor(
      account: spacePeerAccount,
      username: 'bob',
    );
    gateway.postPages[''] = spacePagePost(<SpacePost>[
      spacePost(
        postId: 'post-a',
        author: peer,
        authorFollowing: false,
        text: '同一作者的第一条',
      ),
      spacePost(
        postId: 'post-b',
        author: peer,
        authorFollowing: false,
        text: '同一作者的第二条',
      ),
    ]);
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    await pumpSpacePage(
      tester,
      gateway: gateway,
      followStore: store,
      profile: FakeProfileGateway(),
    );

    Finder cardFollow(String postId) =>
        find.byKey(Key('space-post-follow-$postId'));
    expect(
      find.descendant(of: cardFollow('post-a'), matching: find.text('关注')),
      findsOneWidget,
    );

    // Follow from one card; the sibling card must show the same state.
    await tester.tap(cardFollow('post-a'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: cardFollow('post-a'), matching: find.text('已关注')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: cardFollow('post-b'), matching: find.text('已关注')),
      findsOneWidget,
    );

    // The same store drives the author home page header.
    await tester.tap(find.byKey(const Key('space-post-author-post-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(SpaceProfilePage.pageKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(SpaceProfilePage.followKey),
        matching: find.text('已关注'),
      ),
      findsOneWidget,
    );

    // Unfollow from the home page; the feed cards read the same owner.
    await tester.tap(find.byKey(SpaceProfilePage.followKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SpaceProfilePage.unfollowConfirmKey));
    await tester.pumpAndSettle();
    expect(store.stateFor(spacePeerAccount), isFalse);

    await tester.tap(find.byKey(SpaceProfilePage.backKey));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: cardFollow('post-a'), matching: find.text('关注')),
      findsOneWidget,
    );
    await tester.tap(cardFollow('post-b'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: cardFollow('post-b'), matching: find.text('已关注')),
      findsOneWidget,
    );
  });

  testWidgets('the viewer never sees a follow control on their own cards', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost(<SpacePost>[
      spacePost(postId: 'own-1', text: '我自己的说说'),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    expect(find.byKey(const Key('space-post-follow-own-1')), findsNothing);
  });
}
