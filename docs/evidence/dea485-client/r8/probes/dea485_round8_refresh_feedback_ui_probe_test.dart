import 'dart:async';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_button.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';
import '../test/support/space_test_harness.dart';

void main() {
  for (final concurrent in [false, true]) {
    testWidgets('R8 failed card unfollow keeps feedback after refresh: replay=$concurrent', (tester) async {
      final gateway = _FailureGateway();
      gateway.followStates[spacePeerAccount] = true;
      gateway.followStates[spaceThirdAccount] = false;
      gateway.postPages[''] = spacePagePost([
        spacePost(postId: 'first', text: 'Author A', author: spaceAuthor(account: spacePeerAccount), authorFollowing: true),
        spacePost(postId: 'second', text: 'Author B', author: spaceAuthor(account: spaceThirdAccount), authorFollowing: false),
      ]);
      final store = SpaceFollowStore(gateway: gateway, viewerAccount: gateway.account);
      await pumpSpacePage(tester, gateway: gateway, followStore: store, size: spaceWide);
      await tester.tap(find.byKey(const Key('space-post-follow-first')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpaceFollowButton.confirmKey));
      for (var i = 0; i < 8; i++) { await tester.pump(const Duration(milliseconds: 10)); }
      expect(gateway.captured.isCompleted, isTrue);
      expect(store.isWriting(spacePeerAccount), isTrue);
      expect(store.error, isNotNull);
      if (concurrent) {
        store.handleFollowChanged();
        for (var i = 0; i < 8; i++) { await tester.pump(const Duration(milliseconds: 10)); }
        expect(store.stateFor(spacePeerAccount), isTrue);
      }
      gateway.release.complete();
      await tester.pumpAndSettle();
      expect(store.stateFor(spacePeerAccount), isTrue);
      expect(store.isWriting(spacePeerAccount), isFalse);
      expect(find.text('暂时无法连接服务器，请稍后重试'), findsOneWidget,
          reason: 'An unfollow that never reached the receiver still needs its own failure feedback');
    });
  }
}

class _FailureGateway extends FakeSpaceGateway {
  bool held = false;
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpaceFollowState> setFollow(String account, {required bool following}) async {
    if (account == spacePeerAccount) {
      throw const AuthFailure(status: 503, code: 'upstream_unavailable', message: 'not sent');
    }
    return super.setFollow(account, following: following);
  }
  @override
  Future<SpaceFollowState> getFollow(String account) async {
    final state = await super.getFollow(account);
    if (account == spacePeerAccount && !held) {
      held = true;
      captured.complete();
      await release.future;
    }
    return state;
  }
}
