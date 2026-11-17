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

/// Round-8 regression: feedback for a write that has not returned yet survives
/// a background refresh, while a refresh after the operation finished can clear
/// the old error. A successful operation never displays another target's error.
void main() {
  test('a pending write keeps its feedback through a background refresh', () async {
    final _PendingFeedbackGateway gateway = _PendingFeedbackGateway();
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
    expect(store.errorFor(spacePeerAccount), isNotNull);
    expect(store.isWriting(spacePeerAccount), isTrue);

    // Persisted event path: known targets are re-read while the write is still
    // pending. The successful read must not erase the pending failure.
    store.handleFollowChanged();
    await pumpEventQueue();
    await pumpEventQueue();
    expect(store.errorFor(spacePeerAccount), isNotNull);
    expect(store.stateFor(spacePeerAccount), isTrue);

    gateway.release.complete();
    expect(await write, isFalse);
    expect(store.isWriting(spacePeerAccount), isFalse);
    expect(store.errorFor(spacePeerAccount), isNotNull);

    // After the operation finished, a normal refresh may clear the old error.
    await store.ensureLoaded(spacePeerAccount, force: true);
    expect(store.errorFor(spacePeerAccount), isNull);
  });

  testWidgets(
    'R8 a card failure still shows feedback after a background refresh',
    (WidgetTester tester) async {
      final _PendingFeedbackGateway gateway = _PendingFeedbackGateway();
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

      gateway.armed = true;
      await tester.tap(find.byKey(const Key('space-post-follow-first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpaceFollowButton.confirmKey));
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(gateway.captured.isCompleted, isTrue);
      expect(store.isWriting(spacePeerAccount), isTrue);

      store.handleFollowChanged();
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(store.stateFor(spacePeerAccount), isTrue);

      gateway.release.complete();
      await tester.pumpAndSettle();

      expect(store.isWriting(spacePeerAccount), isFalse);
      expect(
        find.text('暂时无法连接服务器，请稍后重试'),
        findsOneWidget,
        reason: 'A pending failed unfollow needs its feedback after a refresh',
      );
    },
  );

  testWidgets('R8 a successful B never displays a retained A error', (
    WidgetTester tester,
  ) async {
    final _PendingFeedbackGateway gateway = _PendingFeedbackGateway();
    gateway.followStates[spacePeerAccount] = true;
    gateway.followStates[spaceThirdAccount] = false;
    gateway.postPages[''] = spacePagePost(<SpacePost>[
      spacePost(
        postId: 'first',
        text: 'A',
        author: spaceAuthor(account: spacePeerAccount, username: 'alice'),
        authorFollowing: true,
      ),
      spacePost(
        postId: 'second',
        text: 'B',
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

    // Retain A's failure without a UI caller (no snackbar).
    gateway.release.complete();
    expect(await store.setFollowing(spacePeerAccount, false), isFalse);
    expect(store.errorFor(spacePeerAccount), isNotNull);
    expect(find.byType(SnackBar), findsNothing);

    // A successful B operation must not show A's retained error.
    await tester.tap(find.byKey(const Key('space-post-follow-second')));
    await tester.pumpAndSettle();
    expect(store.stateFor(spaceThirdAccount), isTrue);
    expect(store.errorFor(spaceThirdAccount), isNull);
    expect(find.byType(SnackBar), findsNothing);
  });
}

class _PendingFeedbackGateway extends FakeSpaceGateway {
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
