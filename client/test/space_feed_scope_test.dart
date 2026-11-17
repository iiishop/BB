import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

void main() {
  testWidgets('the following scope shows only followed publishers, with its '
      'own empty state', (WidgetTester tester) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost(<SpacePost>[
      spacePost(postId: 'all-1', text: '全部信息流'),
    ]);
    gateway.followingPages[''] = spacePagePost(<SpacePost>[]);
    await pumpSpacePage(tester, gateway: gateway);

    expect(find.text('全部信息流'), findsOneWidget);
    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pumpAndSettle();

    expect(gateway.requestedScopes.last, 'following');
    expect(find.text('全部信息流'), findsNothing);
    expect(find.byKey(SpacePage.followingEmptyKey), findsOneWidget);
    expect(find.text('只看已关注里还没有说说'), findsOneWidget);
  });

  testWidgets('both scopes keep an independent scroll position', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost(<SpacePost>[
      for (int i = 0; i < 20; i++)
        spacePost(postId: 'all-$i', text: '全部第 $i 条'),
    ]);
    gateway.followingPages[''] = spacePagePost(<SpacePost>[
      for (int i = 0; i < 20; i++)
        spacePost(postId: 'following-$i', text: '关注第 $i 条'),
    ]);
    await pumpSpacePage(tester, gateway: gateway);

    ScrollController feedController() =>
        tester.widget<ListView>(find.byKey(SpacePage.feedListKey)).controller!;

    await tester.drag(find.byKey(SpacePage.feedListKey), const Offset(0, -520));
    await tester.pumpAndSettle();
    final double allOffset = feedController().offset;
    expect(allOffset, greaterThan(0));

    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pumpAndSettle();
    expect(feedController().offset, 0);
    expect(find.text('关注第 0 条'), findsOneWidget);

    await tester.drag(find.byKey(SpacePage.feedListKey), const Offset(0, -220));
    await tester.pumpAndSettle();
    final double followingOffset = feedController().offset;
    expect(followingOffset, greaterThan(0));

    await tester.tap(find.byKey(SpacePage.scopeAllKey));
    await tester.pumpAndSettle();
    expect(feedController().offset, closeTo(allOffset, 1));

    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pumpAndSettle();
    expect(feedController().offset, closeTo(followingOffset, 1));
  });

  testWidgets('leaving the Space main area resets the scope to all', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.postPages[''] = spacePagePost(<SpacePost>[
      spacePost(postId: 'all-1', text: '全部信息流'),
    ]);
    gateway.followingPages[''] = spacePagePost(<SpacePost>[
      spacePost(postId: 'following-1', text: '关注信息流'),
    ]);
    await pumpSpacePage(tester, gateway: gateway, active: true);
    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pumpAndSettle();
    expect(find.text('关注信息流'), findsOneWidget);

    // Switch to another primary section and back; the Space session restarts.
    await pumpSpacePage(
      tester,
      gateway: gateway,
      active: false,
      remount: false,
    );
    await pumpSpacePage(tester, gateway: gateway, active: true, remount: false);
    await tester.pumpAndSettle();

    expect(gateway.requestedScopes.last, 'all');
    expect(find.text('全部信息流'), findsOneWidget);
  });

  testWidgets('a stale following cursor 422 refreshes from the first page', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.followingPages[''] = spacePagePost(
      <SpacePost>[spacePost(postId: 'following-1', text: '关注的第一页')],
      nextCursor: 'c1',
      hasMore: true,
    );
    await pumpSpacePage(tester, gateway: gateway);
    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pumpAndSettle();

    gateway.failNext(
      'list_posts',
      const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'validation_error',
      ),
    );
    await tester.tap(find.byKey(SpacePage.loadMoreKey));
    await tester.pumpAndSettle();

    expect(find.text('关注关系已变化，已从首屏刷新'), findsOneWidget);
    expect(gateway.requestedScopes.last, 'following');
    // The failed cursor is not retried; the view restarted at cursor null.
    final List<String?> cursors = gateway.postCursors;
    expect(cursors.last, isNull);
    expect(find.text('关注的第一页'), findsOneWidget);
  });

  testWidgets(
    'a follow write invalidates the following view and refreshes it',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'peer-1',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          text: '关注前的历史',
        ),
      ]);
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      await pumpSpacePage(tester, gateway: gateway, followStore: store);
      await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
      await tester.pumpAndSettle();
      final int before = gateway.requestedScopes.length;

      await store.setFollowing(spacePeerAccount, true);
      await tester.pumpAndSettle();

      expect(gateway.requestedScopes.length, greaterThan(before));
      expect(gateway.requestedScopes.last, 'following');
      expect(gateway.postCursors.last, isNull);
    },
  );

  testWidgets(
    'switching accounts starts a fresh Space session and follow view',
    (WidgetTester tester) async {
      final FakeSpaceGateway first = FakeSpaceGateway();
      first.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'a-1',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: true,
          text: '账号 A 的信息流',
        ),
      ]);
      await pumpSpacePage(
        tester,
        gateway: first,
        pageKey: const ValueKey<String>('space-account-a'),
      );
      expect(find.text('已关注'), findsOneWidget);

      // Another account: a new gateway, store and page key. Relationship state
      // must not leak across accounts and the scope starts at "all".
      final FakeSpaceGateway second = FakeSpaceGateway(account: '10000009');
      second.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'b-1',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          text: '账号 B 的信息流',
        ),
      ]);
      await pumpSpacePage(
        tester,
        gateway: second,
        pageKey: const ValueKey<String>('space-account-b'),
        remount: false,
      );
      await tester.pumpAndSettle();

      expect(second.requestedScopes.last, 'all');
      expect(find.text('账号 B 的信息流'), findsOneWidget);
      expect(find.text('关注'), findsOneWidget);
      expect(find.text('已关注'), findsNothing);
    },
  );

  test('a persisted follow.changed event invalidates state and the following '
      'cursor', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    gateway.followStates[spacePeerAccount] = true;
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    final SpaceController controller = SpaceController(
      gateway: gateway,
      store: SpaceLocalStore(scopeKey: 'test|scope'),
      followStore: store,
      autoPoll: false,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.switchScope(SpaceFeedScope.following);
    await store.ensureLoaded(spacePeerAccount);
    expect(store.stateFor(spacePeerAccount), isTrue);

    // Another client unfollowed; the persisted private event carries no IDs.
    gateway.followStates[spacePeerAccount] = false;
    gateway.eventPages.add(
      spaceEventPage(<SpaceEvent>[
        spaceEvent(eventId: 1, type: 'follow.changed', postId: null),
      ]),
    );
    await controller.pollEventsOnce();
    await pumpEventQueue();

    expect(store.stateFor(spacePeerAccount), isFalse);
    expect(gateway.requestedScopes.last, 'following');
    expect(gateway.postCursors.last, isNull);
  });

  test('an older page snapshot cannot undo a confirmed follow (Q2)', () async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    final SpacePost stale = spacePost(
      postId: 'stale-page',
      author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
      authorFollowing: false,
    );
    store.seedFromPosts(<SpacePost>[stale]);
    expect(store.stateFor(spacePeerAccount), isFalse);

    await store.setFollowing(spacePeerAccount, true);
    expect(store.stateFor(spacePeerAccount), isTrue);

    // The refresh page was captured before the follow; its late response must
    // not overwrite the relationship this store already confirmed.
    store.seedFromPosts(<SpacePost>[stale]);
    expect(store.stateFor(spacePeerAccount), isTrue);
    expect(gateway.followStates[spacePeerAccount], isTrue);
  });

  test(
    'returning to a parked scope cannot resurrect a deleted post (Q3)',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpacePost peerPost = spacePost(
        postId: 'qa-deleted',
        author: spaceAuthor(account: spacePeerAccount),
        authorFollowing: true,
      );
      gateway.postPages[''] = spacePagePost(<SpacePost>[peerPost]);
      gateway.followingPages[''] = spacePagePost(<SpacePost>[peerPost]);
      final SpaceController c = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'qa-delete'),
        autoPoll: false,
      );
      addTearDown(c.dispose);
      await c.start();
      await c.switchScope(SpaceFeedScope.following);
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
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

  test(
    'parked snapshots also scrub deleted references and comments (Q3)',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'repost-parked',
          author: spaceAuthor(account: spacePeerAccount),
          authorFollowing: true,
          reference: spaceReference(postId: 'source-parked'),
        ),
        spacePost(
          postId: 'commented-parked',
          author: spaceAuthor(account: spacePeerAccount),
          authorFollowing: true,
          previewComments: <SpaceBranch>[
            spaceBranch(
              root: spaceComment(
                commentId: 'comment-parked',
                postId: 'commented-parked',
              ),
            ),
          ],
        ),
      ]);
      gateway.followingPages[''] = spacePagePost(<SpacePost>[]);
      final SpaceController c = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'qa-scrub'),
        autoPoll: false,
      );
      addTearDown(c.dispose);
      await c.start();
      await c.switchScope(SpaceFeedScope.following);
      gateway.eventPages.add(
        spaceEventPage(<SpaceEvent>[
          spaceEvent(eventId: 1, type: 'post.deleted', postId: 'source-parked'),
          spaceEvent(
            eventId: 2,
            type: 'comment.deleted',
            postId: 'commented-parked',
            commentId: 'comment-parked',
          ),
        ]),
      );
      await c.pollEventsOnce();
      await c.switchScope(SpaceFeedScope.all);

      final SpacePost repost = c.posts.firstWhere(
        (SpacePost p) => p.postId == 'repost-parked',
      );
      expect(repost.reference?.deleted, isTrue);
      expect(repost.reference?.text, isNull);
      final SpacePost commented = c.posts.firstWhere(
        (SpacePost p) => p.postId == 'commented-parked',
      );
      expect(commented.previewComments.single.root.deleted, isTrue);
      expect(commented.previewComments.single.root.text, isNull);
    },
  );

  test(
    'a scope change releases the old pagination loading flag (Q4)',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(
        <SpacePost>[spacePost(postId: 'qa-all')],
        nextCursor: 'all-c1',
        hasMore: true,
      );
      gateway.followingPages[''] = spacePagePost(
        <SpacePost>[spacePost(postId: 'qa-following')],
        nextCursor: 'following-c1',
        hasMore: true,
      );
      final SpaceController c = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'qa-page'),
        autoPoll: false,
      );
      addTearDown(c.dispose);
      await c.start();
      gateway.holdListPosts = true;
      gateway.listPostsCaptured = Completer<void>();
      gateway.listPostsGate = Completer<void>();
      final Future<void> oldPage = c.loadMore();
      await gateway.listPostsCaptured!.future;
      await c.switchScope(SpaceFeedScope.following);
      gateway.listPostsGate!.complete();
      await oldPage;

      expect(
        c.loadingMore,
        isFalse,
        reason: 'The new scope must remain able to paginate after the old page',
      );
      final int before = gateway.postCursors.length;
      await c.loadMore();
      expect(gateway.postCursors.length, before + 1);
    },
  );

  test(
    'a follow change during a refresh reloads following after it finishes',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'following-peer',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
          authorFollowing: true,
        ),
      ]);
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      final SpaceController c = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'qa-refresh-follow'),
        followStore: store,
        autoPoll: false,
      );
      addTearDown(c.dispose);
      await c.start();
      await c.switchScope(SpaceFeedScope.following);

      gateway.holdListPosts = true;
      gateway.listPostsCaptured = Completer<void>();
      gateway.listPostsGate = Completer<void>();
      final Future<void> refresh = c.refresh();
      await gateway.listPostsCaptured!.future;
      gateway.followStates[spacePeerAccount] = false;
      await store.setFollowing(spacePeerAccount, false);
      gateway.listPostsGate!.complete();
      await refresh;
      await pumpEventQueue();

      // The in-flight page predates the relationship change; the following view
      // must restart from its first page instead of staying stale.
      expect(gateway.requestedScopes.last, 'following');
      expect(gateway.postCursors.last, isNull);
      expect(store.stateFor(spacePeerAccount), isFalse);
    },
  );
}
