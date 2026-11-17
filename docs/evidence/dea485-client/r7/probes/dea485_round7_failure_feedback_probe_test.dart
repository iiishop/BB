// Real receiver and production store; one not-sent SDK failure at gateway.
import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:bb_client/ui/space/space_controller.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final concurrent in [false, true]) {
    test('R7 failed write keeps its feedback across another target: concurrent=$concurrent', () async {
      final base = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
      final cache = Directory.systemTemp.createTempSync('dea485-r7-');
      addTearDown(() => cache.deleteSync(recursive: true));
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final a = await _login(base, cache, 'authora$suffix');
      final b = await _login(base, cache, 'authorb$suffix');
      final viewer = await _login(base, cache, 'viewer$suffix');
      await viewer.setFollow(a.account, following: true);
      final gateway = _FailedWriteGateway(viewer.service, a.account);
      final follows = SpaceFollowStore(gateway: gateway, viewerAccount: viewer.account);
      addTearDown(follows.dispose);
      await follows.ensureLoaded(a.account);
      await follows.ensureLoaded(b.account);
      gateway.armed = true;
      final write = follows.setFollowing(a.account, false);
      await gateway.captured.future.timeout(const Duration(seconds: 5));
      expect(follows.isWriting(a.account), isTrue);
      expect(follows.error, isNotNull);
      if (concurrent) {
        expect(await follows.setFollowing(b.account, true), isTrue);
        expect((await viewer.getFollow(b.account)).following, isTrue);
      }
      gateway.release.complete();
      final applied = await write;
      expect(applied, isFalse);
      expect(follows.isWriting(a.account), isFalse);
      expect((await viewer.getFollow(a.account)).following, isTrue);
      expect(follows.stateFor(a.account), isTrue);
      print('R7 concurrent=$concurrent: receiverA=true storeA=${follows.stateFor(a.account)} applied=$applied hasError=${follows.error != null}');
      expect(follows.error, isNotNull,
          reason: 'A different author successful write must not erase the failed unfollow feedback before its caller can display it');
    });
  }
}

class _FailedWriteGateway extends SpaceServiceGateway {
  _FailedWriteGateway(super.service, this.target);
  final String target;
  bool armed = false;
  bool held = false;
  final captured = Completer<void>();
  final release = Completer<void>();
  @override
  Future<SpaceFollowState> setFollow(String account, {required bool following}) async {
    if (armed && account == target) throw upstreamUnavailable;
    return super.setFollow(account, following: following);
  }
  @override
  Future<SpaceFollowState> getFollow(String account) async {
    final state = await super.getFollow(account);
    if (armed && account == target && !held) {
      held = true;
      captured.complete();
      await release.future;
    }
    return state;
  }
}

Future<SpaceServiceGateway> _login(
  Uri base,
  Directory cache,
  String username,
) async {
  final auth = AuthApiClient(baseUri: base);
  final user = await auth.register(
    username: username,
    password: 'ProfileIT1pass',
  );
  final login = await auth.login(
    account: user.account,
    password: 'ProfileIT1pass',
  );
  final session = AuthSession()
    ..establish(token: login.token, user: login.user);
  final chat = ChatService(
    api: ChatApiClient(baseUri: base),
    session: session,
    ledger: ChatLedger.inMemory(),
    cacheRoot: cache,
    webSocketHints: false,
  );
  return SpaceServiceGateway(
    SpaceService(
      api: SpaceApiClient(baseUri: base),
      session: session,
      chat: chat,
    ),
  );
}
