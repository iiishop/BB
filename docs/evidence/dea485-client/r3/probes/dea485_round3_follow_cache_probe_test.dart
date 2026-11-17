// Review-only: a completed cache must also belong to the current follow revision.
import 'dart:async';

import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_button.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';
import '../test/support/space_test_harness.dart';

void main() {
  for (final restore in [false, true]) {
    testWidgets(
      restore
          ? 'R3 following cache cannot restore an unfollowed author while reload is pending'
          : 'R3 ordinary unfollow reload removes the author without switching scopes',
      (tester) async {
        final gateway = FakeSpaceGateway();
        final peer = spacePost(
          postId: 'followed-author-post',
          text: 'Author removed from following',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: true,
        );
        gateway.followStates[spacePeerAccount] = true;
        gateway.postPages[''] = spacePagePost([peer]);
        gateway.followingPages[''] = spacePagePost([peer]);
        final follows = SpaceFollowStore(
          gateway: gateway,
          viewerAccount: gateway.account,
        );
        await pumpSpacePage(tester, gateway: gateway, followStore: follows);
        await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
        await tester.pumpAndSettle();
        expect(find.text('Author removed from following'), findsOneWidget);

        // A successful unfollow makes the receiver's next following page empty.
        // Delay delivery of that legitimate empty page, not the write itself.
        gateway.followingPages[''] = spacePagePost([]);
        gateway.holdListPosts = true;
        gateway.listPostsCaptured = Completer<void>();
        gateway.listPostsGate = Completer<void>();
        await tester.tap(
          find.byKey(const Key('space-post-follow-followed-author-post')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(SpaceFollowButton.dialogKey), findsOneWidget);
        await tester.tap(find.byKey(SpaceFollowButton.confirmKey));
        await tester.pump();
        await tester.pump();
        expect(follows.stateFor(spacePeerAccount), isFalse);
        expect(gateway.followStates[spacePeerAccount], isFalse);
        expect(gateway.listPostsCaptured!.isCompleted, isTrue);

        // The old active list was loaded before the follow revision changed.
        // It must not become an authoritative completed cache merely by parking.
        if (restore) {
          await tester.tap(find.byKey(SpacePage.scopeAllKey));
          await tester.pump();
          await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
          await tester.pump();
        }
        gateway.listPostsGate!.complete();
        await tester.pumpAndSettle();
        expect(
          find.text('Author removed from following'),
          findsNothing,
          reason: 'A relationship-invalidated active snapshot cannot be restored as a valid following cache',
        );
        expect(find.byKey(SpacePage.followingEmptyKey), findsOneWidget);
      },
    );
  }
}
