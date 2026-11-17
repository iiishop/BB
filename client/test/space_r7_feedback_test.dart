import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_button.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

/// Round-7 regression: failure feedback belongs to its target/operation and a
/// concurrent success on another target must not erase it.
void main() {
  test('a failed target keeps its feedback across another target', () async {
    final _CrossTargetGateway gateway = _CrossTargetGateway();
    gateway.followStates[spacePeerAccount] = true;
    final SpaceFollowStore store = SpaceFollowStore(
      gateway: gateway,
      viewerAccount: gateway.account,
    );
    addTearDown(store.dispose);
    await store.ensureLoaded(spacePeerAccount);
    await store.ensureLoaded(spaceThirdAccount);
    gateway.armed = true;

    final Future<bool> writeA = store.setFollowing(spacePeerAccount, false);
    await gateway.captured.future;
    expect(store.errorFor(spacePeerAccount), isNotNull);
    expect(store.isWriting(spacePeerAccount), isTrue);

    // Another author succeeds while A's reconciliation is still pending.
    expect(await store.setFollowing(spaceThirdAccount, true), isTrue);
    expect(store.errorFor(spacePeerAccount), isNotNull);
    expect(
      store.errorFor(spaceThirdAccount),
      isNull,
      reason: 'A success has no failure feedback of its own',
    );

    gateway.release.complete();
    expect(await writeA, isFalse);
    expect(store.isWriting(spacePeerAccount), isFalse);
    expect(store.stateFor(spacePeerAccount), isTrue);
    expect(
      store.errorFor(spacePeerAccount),
      isNotNull,
      reason: 'Another target success must not erase this operation feedback',
    );
    expect(store.error, isNotNull);

    // A normal refresh settles the target and clears only its own feedback.
    await store.ensureLoaded(spacePeerAccount, force: true);
    expect(store.errorFor(spacePeerAccount), isNull);
    expect(store.stateFor(spacePeerAccount), isTrue);
  });

  test(
    'a failed target without concurrency still reports its own failure',
    () async {
      final _CrossTargetGateway gateway = _CrossTargetGateway();
      gateway.followStates[spacePeerAccount] = true;
      final SpaceFollowStore store = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: gateway.account,
      );
      addTearDown(store.dispose);
      await store.ensureLoaded(spacePeerAccount);
      gateway.armed = true;

      final Future<bool> write = store.setFollowing(spacePeerAccount, false);
      await gateway.captured.future;
      gateway.release.complete();
      expect(await write, isFalse);
      expect(store.errorFor(spacePeerAccount), isNotNull);
    },
  );

  testWidgets(
    'R7 a concurrent follow on another card cannot hide the card failure',
    (WidgetTester tester) async {
      final _CrossTargetGateway gateway = _CrossTargetGateway();
      gateway.followStates[spacePeerAccount] = true;
      gateway.followStates[spaceThirdAccount] = false;
      gateway.postPages[''] = spacePagePost(<SpacePost>[
        spacePost(
          postId: 'first',
          text: 'Author A',
          author: spaceAuthor(account: spacePeerAccount, username: 'alice'),
          authorFollowing: true,
        ),
        spacePost(
          postId: 'second',
          text: 'Author B',
          author: spaceAuthor(account: spaceThirdAccount, username: 'carol'),
          authorFollowing: false,
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
        size: spaceWide,
      );

      // Unfollow A through its real card control; the write fails and its
      // reconciliation read is held.
      gateway.armed = true;
      await tester.tap(find.byKey(const Key('space-post-follow-first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpaceFollowButton.confirmKey));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(gateway.captured.isCompleted, isTrue);
      expect(store.isWriting(spacePeerAccount), isTrue);
      expect(store.errorFor(spacePeerAccount), isNotNull);

      // B succeeds on another card while A is still pending.
      await tester.tap(find.byKey(const Key('space-post-follow-second')));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(store.stateFor(spaceThirdAccount), isTrue);

      gateway.release.complete();
      await tester.pumpAndSettle();

      expect(store.stateFor(spacePeerAccount), isTrue);
      expect(store.isWriting(spacePeerAccount), isFalse);
      expect(
        find.text('暂时无法连接服务器，请稍后重试'),
        findsOneWidget,
        reason: 'A failed unfollow still needs its own feedback',
      );
    },
  );
}

class _CrossTargetGateway extends FakeSpaceGateway {
  bool armed = false;
  bool _held = false;
  final Completer<void> captured = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    if (targetAccount == spacePeerAccount) {
      throw const AuthFailure(
        status: 503,
        code: 'upstream_unavailable',
        message: 'not sent',
      );
    }
    return super.setFollow(targetAccount, following: following);
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    final SpaceFollowState state = await super.getFollow(targetAccount);
    if (armed && targetAccount == spacePeerAccount && !_held) {
      _held = true;
      captured.complete();
      await release.future;
    }
    return state;
  }
}
