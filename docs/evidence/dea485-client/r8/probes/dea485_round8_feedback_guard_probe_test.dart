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
  testWidgets('R8 successful B must not display retained A error through fallback', (tester) async {
    final gateway=_FailureGateway();
    gateway.followStates[spacePeerAccount]=true;
    gateway.followStates[spaceThirdAccount]=false;
    gateway.postPages['']=spacePagePost([
      spacePost(postId:'first',text:'A',author:spaceAuthor(account:spacePeerAccount),authorFollowing:true),
      spacePost(postId:'second',text:'B',author:spaceAuthor(account:spaceThirdAccount),authorFollowing:false),
    ]);
    final store=SpaceFollowStore(gateway:gateway,viewerAccount:gateway.account);
    await pumpSpacePage(tester,gateway:gateway,followStore:store,size:spaceWide);
    gateway.release.complete();
    expect(await store.setFollowing(spacePeerAccount,false),isFalse);
    expect(store.errorFor(spacePeerAccount),isNotNull);
    expect(find.byType(SnackBar),findsNothing);
    await tester.tap(find.byKey(const Key('space-post-follow-second')));
    await tester.pumpAndSettle();
    expect(store.stateFor(spaceThirdAccount),isTrue);
    expect(store.errorFor(spacePeerAccount),isNotNull);
    expect(store.errorFor(spaceThirdAccount),isNull);
    expect(find.byType(SnackBar),findsNothing,
        reason:'A retained failure is not feedback for a successful B operation');
  });
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
