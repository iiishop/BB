// Independent review-only counterexamples. Product code is untouched.
import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';
import '../test/support/space_test_harness.dart';

void main() {
  testWidgets('R2 pending following first page survives all-following return', (
    tester,
  ) async {
    final gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost([
      spacePost(postId: 'all-good', text: 'All ready'),
    ]);
    gateway.followingPages[''] = spacePagePost([
      spacePost(
        postId: 'following-good',
        text: 'Following ready',
        author: spaceAuthor(account: spacePeerAccount),
        authorFollowing: true,
      ),
    ]);
    await pumpSpacePage(tester, gateway: gateway);
    gateway.holdListPosts = true;
    gateway.listPostsCaptured = Completer<void>();
    gateway.listPostsGate = Completer<void>();
    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pump();
    expect(gateway.listPostsCaptured!.isCompleted, isTrue);
    // The scope selector stays interactive while the first page is pending.
    await tester.tap(find.byKey(SpacePage.scopeAllKey));
    await tester.pump();
    expect(find.text('All ready'), findsOneWidget);
    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pump();
    gateway.listPostsGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.text('Following ready'),
      findsOneWidget,
      reason: 'An unfinished cached scope must resume or refetch rather than become a false empty result',
    );
    expect(find.byKey(SpacePage.followingEmptyKey), findsNothing);
  });

  test(
    'R2 old first page failure cannot poison a restored successful scope',
    () async {
      final gateway = _OldErrorGateway();
      gateway.postPages[''] = spacePagePost([spacePost(postId: 'all-good')]);
      final c = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'r2-old-error'),
        autoPoll: false,
      );
      addTearDown(c.dispose);
      await c.start();
      final old = c.switchScope(SpaceFeedScope.following);
      await gateway.captured.future;
      await c.switchScope(SpaceFeedScope.all);
      expect(c.posts.single.postId, 'all-good');
      expect(c.feedError, isNull);
      gateway.response.completeError(
        const AuthFailure(status: 503, code: 'storage_busy', message: 'busy'),
      );
      await old;
      expect(c.posts.single.postId, 'all-good');
      expect(
        c.feedError,
        isNull,
        reason: 'The error belongs to an abandoned scope generation',
      );
      expect(c.offline, isFalse);
    },
  );

  test('R2 repeated follow invalidations finish with a usable authoritative state', () async {
    final gateway = _HeldFollowGateway();
    final follows = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(follows.dispose);
    follows.seedFromPosts([
      spacePost(
        author: spaceAuthor(account: spacePeerAccount),
        authorFollowing: false,
      ),
    ]);
    expect(follows.stateFor(spacePeerAccount), isFalse);
    // External follow, then external unfollow, before the first read returns.
    // Both are valid distinct persisted follow.changed events for this viewer.
    gateway.followStates[spacePeerAccount] = true;
    follows.handleFollowChanged();
    await gateway.captured.future;
    gateway.followStates[spacePeerAccount] = false;
    follows.handleFollowChanged();
    gateway.response.complete(
      SpaceFollowState(targetAccount: spacePeerAccount, following: true),
    );
    await pumpEventQueue();
    expect(
      follows.stateFor(spacePeerAccount),
      isFalse,
      reason: 'Discarding an obsolete read must still schedule reconciliation of the known target',
    );
  });
}

class _OldErrorGateway extends FakeSpaceGateway {
  final captured = Completer<void>();
  final response = Completer<SpacePagePost>();
  @override
  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
    String? author,
    String scope = 'all',
  }) async {
    if (scope == 'following') {
      if (!captured.isCompleted) captured.complete();
      return response.future;
    }
    return super.listPosts(
      cursor: cursor,
      limit: limit,
      unreadOnly: unreadOnly,
      author: author,
      scope: scope,
    );
  }
}

class _HeldFollowGateway extends FakeSpaceGateway {
  final captured = Completer<void>();
  final response = Completer<SpaceFollowState>();
  int reads = 0;
  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    reads++;
    if (reads == 1) {
      captured.complete();
      return response.future;
    }
    return super.getFollow(targetAccount);
  }
}
