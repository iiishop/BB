import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_detail_controller.dart'
    show SpacePhase;
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

/// Round-2 mechanism regressions (R2-A/R2-B/R2-C) plus their neighbouring
/// valid paths, collected by the default test entry.
void main() {
  testWidgets(
    'R2-A an unfinished parked scope resumes with a real first page',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(postId: 'all-good', text: 'All ready'),
      ]);
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
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

      // The selector stays usable while the first page is still pending.
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
        reason: 'An unfinished cached scope must refetch, not become an empty result',
      );
      expect(find.byKey(SpacePage.followingEmptyKey), findsNothing);
    },
  );

  testWidgets(
    'R2-A neighbouring valid path: a completed parked scope restores without '
    'a redundant first page',
    (WidgetTester tester) async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(postId: 'all-good', text: 'All ready'),
      ]);
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        spacePost(postId: 'following-good', text: 'Following ready'),
      ]);
      await pumpSpacePage(tester, gateway: gateway);
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
        reason: 'A completed cache restore must not re-query',
      );
    },
  );

  test(
    'R2-B an abandoned first-page failure cannot poison the visible scope',
    () async {
      final _OldErrorGateway gateway = _OldErrorGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(postId: 'all-good'),
      ]);
      final SpaceController controller = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'r2-old-error'),
        autoPoll: false,
      );
      addTearDown(controller.dispose);
      await controller.start();
      final Future<void> old = controller.switchScope(SpaceFeedScope.following);
      await gateway.captured.future;
      await controller.switchScope(SpaceFeedScope.all);
      expect(controller.posts.single.postId, 'all-good');
      expect(controller.feedError, isNull);

      gateway.response.completeError(
        const AuthFailure(status: 503, code: 'storage_busy', message: 'busy'),
      );
      await old;
      expect(controller.posts.single.postId, 'all-good');
      expect(
        controller.feedError,
        isNull,
        reason: 'The error belongs to an abandoned scope generation',
      );
      expect(controller.offline, isFalse);
    },
  );

  test(
    'R2-B neighbouring valid path: a current first-page failure still surfaces',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(postId: 'all-good'),
      ]);
      final SpaceController controller = SpaceController(
        gateway: gateway,
        store: SpaceLocalStore(scopeKey: 'r2-current-error'),
        autoPoll: false,
      );
      addTearDown(controller.dispose);
      await controller.start();

      gateway.failNext(
        'list_posts',
        const AuthFailure(status: 503, code: 'storage_busy', message: 'busy'),
      );
      await controller.switchScope(SpaceFeedScope.following);

      expect(controller.feedError, '暂时无法连接服务器，请稍后重试');
      expect(controller.phase, SpacePhase.error);
      expect(controller.scope, SpaceFeedScope.following);
    },
  );

  test(
    'R2-C repeated follow invalidations still reconcile the known target',
    () async {
      final _HeldFollowGateway gateway = _HeldFollowGateway();
      final SpaceFollowStore follows = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      addTearDown(follows.dispose);
      follows.seedFromPosts(<SpacePost>[
        spacePost(
          author: spaceAuthor(account: spacePeerAccount),
          authorFollowing: false,
        ),
      ]);
      expect(follows.stateFor(spacePeerAccount), isFalse);

      // Follow, then unfollow, before the first read returns: two distinct
      // persisted events for the same viewer.
      gateway.followStates[spacePeerAccount] = true;
      follows.handleFollowChanged();
      await gateway.captured.future;
      gateway.followStates[spacePeerAccount] = false;
      follows.handleFollowChanged();
      gateway.response.complete(
        const SpaceFollowState(
          targetAccount: spacePeerAccount,
          following: true,
        ),
      );
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        follows.stateFor(spacePeerAccount),
        isFalse,
        reason:
            'A discarded read must schedule reconciliation of the known target',
      );
      expect(gateway.reads, 2);
    },
  );

  test(
    'R2-C neighbouring valid path: one invalidation reconciles once',
    () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpaceFollowStore follows = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      addTearDown(follows.dispose);
      follows.seedFromPosts(<SpacePost>[
        spacePost(
          author: spaceAuthor(account: spacePeerAccount),
          authorFollowing: false,
        ),
      ]);
      gateway.followStates[spacePeerAccount] = true;

      follows.handleFollowChanged();
      await pumpEventQueue();

      expect(follows.stateFor(spacePeerAccount), isTrue);
      expect(
        gateway.followReads.where((String a) => a == spacePeerAccount),
        hasLength(1),
      );
    },
  );

  test(
    'R2-C neighbouring valid path: a write during a pending read wins',
    () async {
      final _HeldFollowGateway gateway = _HeldFollowGateway();
      final SpaceFollowStore follows = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      addTearDown(follows.dispose);
      follows.seedFromPosts(<SpacePost>[
        spacePost(
          author: spaceAuthor(account: spacePeerAccount),
          authorFollowing: false,
        ),
      ]);

      follows.handleFollowChanged();
      await gateway.captured.future;
      expect(follows.stateFor(spacePeerAccount), isNull);
      final Future<bool> write = follows.setFollowing(spacePeerAccount, true);
      gateway.response.complete(
        const SpaceFollowState(
          targetAccount: spacePeerAccount,
          following: false,
        ),
      );
      await write;
      await pumpEventQueue();

      expect(follows.stateFor(spacePeerAccount), isTrue);
      expect(
        gateway.reads,
        1,
        reason: 'A successful write needs no extra read',
      );
    },
  );
}

class _OldErrorGateway extends FakeSpaceGateway {
  final Completer<void> captured = Completer<void>();
  final Completer<SpacePagePost> response = Completer<SpacePagePost>();

  @override
  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
    String? author,
    String scope = 'all',
  }) async {
    if (scope == 'following') {
      if (!captured.isCompleted) {
        captured.complete();
      }
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
  final Completer<void> captured = Completer<void>();
  final Completer<SpaceFollowState> response = Completer<SpaceFollowState>();
  int reads = 0;

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) {
    reads++;
    if (reads == 1) {
      captured.complete();
      return response.future;
    }
    return super.getFollow(targetAccount);
  }
}
