// Review-only failing probes for b6becc4. Never part of default test/ CI.
// Move each scenario into the existing normal entry after its production fix.
import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:bb_client/ui/space/profile/space_profile_adapter.dart';
import 'package:bb_client/ui/space/profile/space_profile_controller.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';
import '../test/support/space_test_harness.dart';

void main() {
  testWidgets('QA follow success survives an older feed snapshot', (
    tester,
  ) async {
    final gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost([
      spacePost(
        postId: 'qa-old-page',
        author: spaceAuthor(account: spacePeerAccount),
        authorFollowing: false,
      ),
    ]);
    final follows = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    await pumpSpacePage(tester, gateway: gateway, followStore: follows);
    gateway.holdListPosts = true;
    gateway.listPostsCaptured = Completer<void>();
    gateway.listPostsGate = Completer<void>();
    // Actual refresh callback used by the pull-to-refresh widget.
    final pending = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(gateway.listPostsCaptured!.isCompleted, isTrue);
    // The card's follow button remains enabled during a feed refresh.
    await tester.tap(find.byKey(const Key('space-post-follow-qa-old-page')));
    await tester.pump();
    await tester.pump();
    expect(gateway.followStates[spacePeerAccount], isTrue);
    expect(follows.stateFor(spacePeerAccount), isTrue);
    gateway.listPostsGate!.complete();
    await pending;
    await tester.pumpAndSettle();
    expect(
      follows.stateFor(spacePeerAccount),
      isTrue,
      reason: 'An older page must not undo a confirmed follow',
    );
    expect(find.text('已关注'), findsOneWidget);
  });

  test(
    'QA returning to a parked scope cannot resurrect a deleted post',
    () async {
      final gateway = FakeSpaceGateway();
      final peerPost = spacePost(
        postId: 'qa-deleted',
        author: spaceAuthor(account: spacePeerAccount),
        authorFollowing: true,
      );
      gateway.postPages[''] = spacePagePost([peerPost]);
      gateway.followingPages[''] = spacePagePost([peerPost]);
      final c = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'qa-delete'),
        autoPoll: false,
      );
      addTearDown(c.dispose);
      await c.start();
      await c.switchScope(SpaceFeedScope.following);
      gateway.eventPages.add(
        spaceEventPage([
          spaceEvent(eventId: 1, type: 'post.deleted', postId: peerPost.postId),
        ]),
      );
      await c.pollEventsOnce();
      expect(c.posts, isEmpty);
      await c.switchScope(SpaceFeedScope.all);
      expect(
        c.posts,
        isEmpty,
        reason: 'A parked scope must reapply deletion tombstones',
      );
    },
  );

  test('QA scope change releases the old pagination loading flag', () async {
    final gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost(
      [spacePost(postId: 'qa-all')],
      nextCursor: 'all-c1',
      hasMore: true,
    );
    gateway.followingPages[''] = spacePagePost(
      [spacePost(postId: 'qa-following')],
      nextCursor: 'following-c1',
      hasMore: true,
    );
    final c = SpaceController(
      gateway: gateway,
      store: SpaceLocalStore(scopeKey: 'qa-page'),
      autoPoll: false,
    );
    addTearDown(c.dispose);
    await c.start();
    gateway.holdListPosts = true;
    gateway.listPostsCaptured = Completer<void>();
    gateway.listPostsGate = Completer<void>();
    final oldPage = c.loadMore();
    await gateway.listPostsCaptured!.future;
    await c.switchScope(SpaceFeedScope.following);
    gateway.listPostsGate!.complete();
    await oldPage;
    expect(
      c.loadingMore,
      isFalse,
      reason: 'The new scope must remain able to paginate after the old page finishes',
    );
    final before = gateway.postCursors.length;
    await c.loadMore();
    expect(gateway.postCursors.length, before + 1);
  });
}
