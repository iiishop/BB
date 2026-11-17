import 'dart:async';

import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_button.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

/// Round-3 regression: a completed following cache is only usable while the
/// follow revision it was loaded under is still current.
void main() {
  for (final bool roundTrip in <bool>[false, true]) {
    testWidgets(
      roundTrip
          ? 'R3 an unfollowed author cannot return through a parked following cache'
          : 'R3 ordinary unfollow reload removes the author without a scope switch',
      (WidgetTester tester) async {
        final _Rig rig = await _pumpUnfollowFeed(tester);
        final FakeSpaceGateway gateway = rig.gateway;
        expect(find.text('Author removed from following'), findsOneWidget);

        // A successful unfollow makes the receiver's next following page empty;
        // delay that legitimate empty page, not the write itself.
        gateway.followingPages[''] = spacePagePost(<SpacePost>[]);
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
        expect(rig.store.stateFor(spacePeerAccount), isFalse);
        expect(gateway.followStates[spacePeerAccount], isFalse);
        expect(gateway.listPostsCaptured!.isCompleted, isTrue);

        if (roundTrip) {
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
          reason: 'A relationship-invalidated snapshot cannot restore as a valid cache',
        );
        expect(find.byKey(SpacePage.followingEmptyKey), findsOneWidget);
      },
    );
  }

  testWidgets(
    'R3 neighbouring valid path: a revision-valid completed cache restores '
    'without a redundant first page',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'following-good',
          text: 'Following ready',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: true,
        ),
      ]);
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      await pumpSpacePage(tester, gateway: gateway, followStore: store);
      await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpacePage.scopeAllKey));
      await tester.pumpAndSettle();
      final int beforeRestore = gateway.requestedScopes.length;

      await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
      await tester.pumpAndSettle();

      expect(find.text('Following ready'), findsOneWidget);
      expect(
        gateway.requestedScopes.length,
        beforeRestore,
        reason:
            'No relationship change happened, so the completed cache is valid',
      );
    },
  );

  testWidgets(
    'R3 neighbouring valid path: an invalidation while "all" is active forces '
    'a fresh following query',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'all-1',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: false,
        ),
      ]);
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'following-old',
          text: 'Old following page',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: true,
        ),
      ]);
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      await pumpSpacePage(tester, gateway: gateway, followStore: store);
      await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpacePage.scopeAllKey));
      await tester.pumpAndSettle();

      // Relationship changes while the following page is parked.
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'following-new',
          text: 'Fresh following page',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: true,
        ),
      ]);
      await store.setFollowing(spacePeerAccount, true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
      await tester.pumpAndSettle();

      expect(gateway.requestedScopes.last, 'following');
      expect(gateway.postCursors.last, isNull);
      expect(find.text('Fresh following page'), findsOneWidget);
      expect(find.text('Old following page'), findsNothing);
    },
  );
}

class _Rig {
  _Rig({required this.gateway, required this.store});

  final FakeSpaceGateway gateway;
  final SpaceFollowStore store;
}

Future<_Rig> _pumpUnfollowFeed(WidgetTester tester) async {
  final FakeSpaceGateway gateway = FakeSpaceGateway();
  final SpacePost peer = spacePost(
    postId: 'followed-author-post',
    text: 'Author removed from following',
    author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
    authorFollowing: true,
  );
  gateway.followStates[spacePeerAccount] = true;
  gateway.postPages[''] = spacePagePost(<SpacePost>[peer]);
  gateway.followingPages[''] = spacePagePost(<SpacePost>[peer]);
  final SpaceFollowStore store = SpaceFollowStore(
    gateway: gateway,
    viewerAccount: gateway.account,
  );
  await pumpSpacePage(tester, gateway: gateway, followStore: store);
  await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
  await tester.pumpAndSettle();
  return _Rig(gateway: gateway, store: store);
}
