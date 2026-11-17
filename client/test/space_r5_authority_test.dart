import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_page.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

/// Round-5 regression: a delivered write result must not redefine relationship
/// truth when a newer authoritative fact was already applied, while a write the
/// receiver accepted later must still complete.
void main() {
  test('a stale ACK cannot roll back a newer persisted relationship', () async {
    final _StaleAckGateway gateway = _StaleAckGateway();
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(store.dispose);
    store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);

    final Future<bool> write = store.setFollowing(spacePeerAccount, false);
    await gateway.captured.future;
    // The receiver committed false; a newer persisted event says true and is
    // observed through the same store.
    gateway.followStates[spacePeerAccount] = true;
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(store.stateFor(spacePeerAccount), isTrue);

    gateway.release.complete();
    expect(await write, isTrue);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(
      store.stateFor(spacePeerAccount),
      isTrue,
      reason: 'An older delivered ACK must not overwrite newer observed truth',
    );
    expect((await gateway.getFollow(spacePeerAccount)).following, isTrue);
  });

  test('a stale reconciliation result cannot roll back newer truth', () async {
    final _StaleReconcileGateway gateway = _StaleReconcileGateway();
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(store.dispose);
    store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);

    final Future<bool> write = store.setFollowing(spacePeerAccount, false);
    await gateway.captured.future;
    expect(store.error, isNotNull);
    gateway.followStates[spacePeerAccount] = true;
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(store.stateFor(spacePeerAccount), isTrue);

    gateway.release.complete();
    expect(await write, isFalse);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(
      store.stateFor(spacePeerAccount),
      isTrue,
      reason: 'An older reconciliation read must not roll back newer truth',
    );
    expect((await gateway.getFollow(spacePeerAccount)).following, isTrue);
  });

  test('a write accepted after a newer event still completes', () async {
    final _AcceptedLaterGateway gateway = _AcceptedLaterGateway();
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(store.dispose);
    store.seedFromPosts(<SpacePost>[_peerPost(authorFollowing: true)]);

    final Future<bool> write = store.setFollowing(spacePeerAccount, false);
    await gateway.captured.future;
    // Newer event observed while the request is still in flight; the receiver
    // has not processed the request yet.
    gateway.followStates[spacePeerAccount] = true;
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(store.stateFor(spacePeerAccount), isTrue);

    gateway.release.complete();
    expect(await write, isTrue);
    await pumpEventQueue();
    await pumpEventQueue();

    expect(
      store.stateFor(spacePeerAccount),
      isFalse,
      reason: 'A write accepted after the event is the newer truth',
    );
    expect((await gateway.getFollow(spacePeerAccount)).following, isFalse);
  });

  testWidgets(
    'R5 a write accepted after an event still invalidates the following feed',
    (WidgetTester tester) async {
      final _AcceptedLaterGateway gateway = _AcceptedLaterGateway();
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

      final Future<bool> write = store.setFollowing(spacePeerAccount, false);
      await gateway.captured.future;
      gateway.followStates[spacePeerAccount] = true;
      store.handleFollowChanged();
      // The held write keeps the card's busy spinner animating; pump frames
      // instead of waiting for full settle.
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('Still followed'), findsOneWidget);

      // The receiver processes the older request only now, after the event.
      gateway.followStates[spacePeerAccount] = false;
      gateway.followingPages[''] = spacePagePost(<SpacePost>[]);
      gateway.release.complete();
      expect(await write, isTrue);
      await tester.pumpAndSettle();

      expect(store.stateFor(spacePeerAccount), isFalse);
      expect(find.text('Still followed'), findsNothing);
      expect(find.byKey(SpacePage.followingEmptyKey), findsOneWidget);
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

/// Commits the write, then holds the ACK until released.
class _StaleAckGateway extends FakeSpaceGateway {
  final Completer<void> captured = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    followStates[targetAccount] = following;
    captured.complete();
    await release.future;
    return SpaceFollowState(targetAccount: targetAccount, following: following);
  }
}

/// Commits the write, loses the reply, then holds the reconciliation read.
class _StaleReconcileGateway extends FakeSpaceGateway {
  final Completer<void> captured = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _held = false;

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    followStates[targetAccount] = following;
    throw const AuthFailure(
      status: 503,
      code: 'upstream_unavailable',
      message: 'reply lost',
    );
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    final SpaceFollowState state = await super.getFollow(targetAccount);
    if (!_held) {
      _held = true;
      captured.complete();
      await release.future;
    }
    return state;
  }
}

/// Holds the request before the receiver processes it, then commits it.
class _AcceptedLaterGateway extends FakeSpaceGateway {
  final Completer<void> captured = Completer<void>();
  final Completer<void> release = Completer<void>();

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
}
