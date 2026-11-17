import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_button.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

/// Round-6 regression: an unresolved relation must be reported as an explicit
/// failure (applied=false + error), never silently completed, while a readable
/// truth still settles and preserves the older-value protection.
void main() {
  test('an unavailable settlement read reports an unresolved write', () async {
    final _SettlementGateway gateway = _SettlementGateway();
    gateway.followStates[spacePeerAccount] = true;
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(store.dispose);
    store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);

    final Future<bool> write = store.setFollowing(spacePeerAccount, false);
    await gateway.captured.future;
    // Newer event observed while the request is still in flight; the receiver
    // has not committed this request yet.
    gateway.followStates[spacePeerAccount] = true;
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(store.stateFor(spacePeerAccount), isTrue);

    // The request commits afterwards, but the ordering-resolution read is
    // unavailable.
    gateway.failReads = true;
    gateway.release.complete();
    expect(await write, isFalse);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(
      store.stateFor(spacePeerAccount),
      isTrue,
      reason: 'The last known relationship may be kept',
    );
    expect(
      store.error,
      isNotNull,
      reason: 'An unresolved settlement must surface a failure to the caller',
    );

    // Recovery: once reads work again, the normal invalidation path settles the
    // authoritative receiver value.
    gateway.failReads = false;
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(store.stateFor(spacePeerAccount), isFalse);
    expect(store.error, isNull);
    expect((await gateway.getFollow(spacePeerAccount)).following, isFalse);
  });

  test('a readable settlement settles silently and succeeds', () async {
    final _SettlementGateway gateway = _SettlementGateway();
    gateway.followStates[spacePeerAccount] = true;
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(store.dispose);
    store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);

    final Future<bool> write = store.setFollowing(spacePeerAccount, false);
    await gateway.captured.future;
    gateway.followStates[spacePeerAccount] = true;
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();

    gateway.release.complete();
    expect(await write, isTrue);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(store.stateFor(spacePeerAccount), isFalse);
    expect(store.error, isNull);
  });

  testWidgets(
    'R6 the existing UI surfaces the unavailable settlement as an error',
    (WidgetTester tester) async {
      final _SettlementGateway gateway = _SettlementGateway();
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
      expect(find.text('Still followed'), findsOneWidget);

      // Unfollow through the real card control; the write is held, then a newer
      // event syncs true, then the write commits but cannot be settled.
      await tester.tap(
        find.byKey(const Key('space-post-follow-followed-author-post')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(SpaceFollowButton.dialogKey), findsOneWidget);
      await tester.tap(find.byKey(SpaceFollowButton.confirmKey));
      await tester.pump();
      await gateway.captured.future;
      gateway.followStates[spacePeerAccount] = true;
      store.handleFollowChanged();
      // The held write keeps the busy spinner animating; pump frames only.
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      gateway.failReads = true;
      gateway.release.complete();
      await tester.pumpAndSettle();

      expect(find.text('暂时无法连接服务器，请稍后重试'), findsOneWidget);
      expect(find.text('Still followed'), findsOneWidget);
    },
  );
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

/// Holds the request before the receiver commits it, then returns a successful
/// ACK. `failReads` makes every follow read unavailable afterwards.
class _SettlementGateway extends FakeSpaceGateway {
  final Completer<void> captured = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool failReads = false;

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    captured.complete();
    await release.future;
    followStates[targetAccount] = following;
    return SpaceFollowState(targetAccount: targetAccount, following: following);
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    if (failReads) {
      throw const AuthFailure(
        status: 503,
        code: 'upstream_unavailable',
        message: 'unavailable',
      );
    }
    return super.getFollow(targetAccount);
  }
}
