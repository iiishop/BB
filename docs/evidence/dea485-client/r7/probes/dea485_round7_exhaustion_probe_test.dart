import 'dart:async';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';

// Real production store; contract-valid gateway responses. A separate target's
// acknowledged writes advance the shared revision during recovery GETs. This
// exercises the actual bounded fencing loop without duplicating its logic.
void main() {
  for (final loseReply in [false, true]) {
    for (final races in [2, 3]) {
      test('R7 settlement fencing: lostReply=$loseReply races=$races', () async {
        final gateway = _FencingGateway(loseReply);
        final store = SpaceFollowStore(
          gateway: gateway,
          viewerAccount: gateway.account,
        );
        addTearDown(store.dispose);
        gateway.followStates[spacePeerAccount] = true;
        await store.ensureLoaded(spacePeerAccount);

        final write = store.setFollowing(spacePeerAccount, false);
        await gateway.captured.future;
        var otherFollowing = true;
        expect(await store.setFollowing(spaceThirdAccount, otherFollowing), isTrue);
        gateway.onRecoveryRead = (int index) async {
          if (index < races) {
            otherFollowing = !otherFollowing;
            expect(await store.setFollowing(spaceThirdAccount, otherFollowing), isTrue);
          }
        };
        gateway.release.complete();
        final applied = await write;
        expect(gateway.recoveryReads, 3);
        expect(store.isWriting(spacePeerAccount), isFalse);
        expect(gateway.followStates[spacePeerAccount], isFalse);
        if (races == 3) {
          expect(applied, isFalse,
              reason: 'Exhausted ordering recovery must report an unresolved operation');
          expect(store.error, isNotNull,
              reason: 'The shared card/profile UI must receive explicit failure feedback');
          expect(store.stateFor(spacePeerAccount), isTrue,
              reason: 'Discarded reads must not replace the last known relationship');
        } else {
          expect(applied, !loseReply);
          expect(store.stateFor(spacePeerAccount), isFalse);
          expect(store.error, loseReply ? isNotNull : isNull);
        }

        // Normal refresh is usable after terminal failure, clears the error,
        // and an idempotent retry does not invent a relationship change.
        gateway.onRecoveryRead = null;
        await store.ensureLoaded(spacePeerAccount, force: true);
        expect(store.stateFor(spacePeerAccount), isFalse);
        expect(store.error, isNull);
        final revision = store.revision;
        gateway.hold = false;
        gateway.loseReply = false;
        expect(await store.setFollowing(spacePeerAccount, false), isTrue);
        expect(store.revision, revision);
        expect(store.error, isNull);
      });
    }
  }
}

class _FencingGateway extends FakeSpaceGateway {
  _FencingGateway(this.loseReply);
  bool loseReply;
  bool hold = true;
  bool afterCommit = false;
  bool initialReconciliationDone = false;
  int recoveryReads = 0;
  Future<void> Function(int index)? onRecoveryRead;
  final captured = Completer<void>();
  final release = Completer<void>();

  @override
  Future<SpaceFollowState> setFollow(String targetAccount, {
    required bool following,
  }) async {
    if (targetAccount == spacePeerAccount && hold) {
      captured.complete();
      await release.future;
    }
    final result = await super.setFollow(targetAccount, following: following);
    if (targetAccount == spacePeerAccount) {
      afterCommit = true;
      if (loseReply) {
        throw const AuthFailure(status: 503, code: 'upstream_unavailable',
            message: 'lost ACK after commit');
      }
    }
    return result;
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    final result = await super.getFollow(targetAccount);
    if (afterCommit && targetAccount == spacePeerAccount) {
      if (loseReply && !initialReconciliationDone) {
        initialReconciliationDone = true;
      } else {
        final index = recoveryReads++;
        await onRecoveryRead?.call(index);
      }
    }
    return result;
  }
}
