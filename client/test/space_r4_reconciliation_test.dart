import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

/// Round-4 regression: a relationship change discovered during reconciliation
/// is authoritative and must invalidate consumers exactly like a confirmed
/// write. A write that never reached the receiver keeps the real relationship.
void main() {
  group('SpaceFollowStore reconciliation', () {
    test(
      'a lost reply reconciled to a changed state advances the revision',
      () async {
        final _LostReplyGateway gateway = _LostReplyGateway(
          applyOnServer: true,
        );
        final SpaceFollowStore store = SpaceFollowStore(
          gateway: gateway,
          viewerAccount: gateway.account,
        );
        addTearDown(store.dispose);
        store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);
        final int before = store.revision;

        final bool applied = await store.setFollowing(spacePeerAccount, false);

        expect(applied, isFalse);
        expect(store.error, isNotNull);
        expect(store.stateFor(spacePeerAccount), isFalse);
        expect(
          store.revision,
          before + 1,
          reason: 'A reconciled real change must invalidate consumers',
        );
      },
    );

    test(
      'a write that never reached the receiver keeps state and revision',
      () async {
        final _LostReplyGateway gateway = _LostReplyGateway(
          applyOnServer: false,
        )..followStates[spacePeerAccount] = true;
        final SpaceFollowStore store = SpaceFollowStore(
          gateway: gateway,
          viewerAccount: gateway.account,
        );
        addTearDown(store.dispose);
        store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);
        final int before = store.revision;

        final bool applied = await store.setFollowing(spacePeerAccount, false);

        expect(applied, isFalse);
        expect(store.error, isNotNull);
        expect(store.stateFor(spacePeerAccount), isTrue);
        expect(
          store.revision,
          before,
          reason: 'No authoritative change happened',
        );
      },
    );

    test(
      'a failed reconciliation keeps the previous authoritative value',
      () async {
        final _LostReplyGateway gateway = _LostReplyGateway(
          applyOnServer: true,
          failReconciliation: true,
        );
        final SpaceFollowStore store = SpaceFollowStore(
          gateway: gateway,
          viewerAccount: gateway.account,
        );
        addTearDown(store.dispose);
        store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);
        final int before = store.revision;

        final bool applied = await store.setFollowing(spacePeerAccount, false);

        expect(applied, isFalse);
        expect(store.error, isNotNull);
        expect(store.stateFor(spacePeerAccount), isTrue);
        expect(store.revision, before);
      },
    );

    test('a confirmed duplicate desired state is a true no-op', () async {
      final FakeSpaceGateway gateway = FakeSpaceGateway();
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      addTearDown(store.dispose);
      store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);
      final int before = store.revision;

      final bool applied = await store.setFollowing(spacePeerAccount, true);

      expect(applied, isTrue);
      expect(store.stateFor(spacePeerAccount), isTrue);
      expect(store.revision, before);
    });
  });

  testWidgets(
    'R4 a lost reply reconciled to unfollowed empties the following feed',
    (WidgetTester tester) async {
      final _LostReplyGateway gateway = _LostReplyGateway(applyOnServer: true);
      gateway.followStates[spacePeerAccount] = true;
      gateway.followingPages[''] = spacePagePost(<SpacePost>[
        _peerPost(authorFollowing: true, text: 'Author removed from following'),
      ]);
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      await pumpSpacePage(tester, gateway: gateway, followStore: store);
      await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
      await tester.pumpAndSettle();
      expect(find.text('Author removed from following'), findsOneWidget);
      final int before = gateway.requestedScopes.length;

      // The receiver applied the unfollow; only its reply was lost.
      gateway.followingPages[''] = spacePagePost(<SpacePost>[]);
      await store.setFollowing(spacePeerAccount, false);
      await tester.pumpAndSettle();

      expect(store.error, isNotNull);
      expect(store.stateFor(spacePeerAccount), isFalse);
      expect(find.text('Author removed from following'), findsNothing);
      expect(find.byKey(SpacePage.followingEmptyKey), findsOneWidget);
      expect(gateway.requestedScopes.length, before + 1);
      expect(gateway.requestedScopes.last, 'following');
      expect(gateway.postCursors.last, isNull);
    },
  );

  testWidgets('R4 an unsent unfollow keeps the author and the real error', (
    WidgetTester tester,
  ) async {
    final _LostReplyGateway gateway = _LostReplyGateway(applyOnServer: false);
    gateway.followStates[spacePeerAccount] = true;
    gateway.followingPages[''] = spacePagePost(<SpacePost>[
      _peerPost(authorFollowing: true, text: 'Still followed'),
    ]);
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    await pumpSpacePage(tester, gateway: gateway, followStore: store);
    await tester.tap(find.byKey(SpacePage.scopeFollowingKey));
    await tester.pumpAndSettle();
    final int before = gateway.requestedScopes.length;

    await store.setFollowing(spacePeerAccount, false);
    await tester.pumpAndSettle();

    expect(store.error, isNotNull);
    expect(store.stateFor(spacePeerAccount), isTrue);
    expect(find.text('Still followed'), findsOneWidget);
    expect(
      gateway.requestedScopes.length,
      before,
      reason: 'No authoritative change means no following reload',
    );
  });
}

SpacePost _peerPost({
  required bool authorFollowing,
  String text = 'peer post',
}) {
  return spacePost(
    postId: 'followed-author-post',
    text: text,
    author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
    authorFollowing: authorFollowing,
  );
}

/// Simulates an unknown write outcome at the gateway boundary:
/// * [applyOnServer] true — receiver applied the write, reply was lost;
/// * false — the request never reached the receiver.
class _LostReplyGateway extends FakeSpaceGateway {
  _LostReplyGateway({
    required this.applyOnServer,
    this.failReconciliation = false,
  });

  final bool applyOnServer;
  final bool failReconciliation;

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    if (applyOnServer) {
      followStates[targetAccount] = following;
    }
    throw const AuthFailure(
      status: 503,
      code: 'upstream_unavailable',
      message: 'reply lost',
    );
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    if (failReconciliation) {
      throw const AuthFailure(
        status: 503,
        code: 'upstream_unavailable',
        message: 'reconcile failed',
      );
    }
    return super.getFollow(targetAccount);
  }
}
