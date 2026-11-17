// Real receiver / production event consumer, pending write and refresh.
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
  for (final replay in [false, true]) {
    test('R8 pending failed write keeps feedback through event refresh: replay=$replay', () async {
      final base = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
      final cache = Directory.systemTemp.createTempSync('dea485-r8-');
      addTearDown(() => cache.deleteSync(recursive: true));
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final a = await _login(base, cache, 'authora$suffix');
      final b = await _login(base, cache, 'authorb$suffix');
      final viewer = await _login(base, cache, 'viewer$suffix');
      final draft = await a.createDraft(operationId: 'r8-d-$suffix', text: 'author A');
      await a.publishDraft(draftId: draft.resourceId!, operationId: 'r8-p-$suffix', expectedVersion: draft.resourceVersion!);
      await viewer.setFollow(a.account, following: true);
      final gateway = _RefreshGateway(viewer.service, a.account);
      final follows = SpaceFollowStore(gateway: gateway, viewerAccount: viewer.account);
      final feed = SpaceController(gateway: gateway, followStore: follows,
          store: SpaceLocalStore(scopeKey: gateway.scopeKey), autoPoll: false);
      addTearDown(follows.dispose);addTearDown(feed.dispose);
      await feed.start();
      await follows.ensureLoaded(a.account);
      gateway.armed = true;
      final write = follows.setFollowing(a.account, false);
      await gateway.captured.future.timeout(const Duration(seconds: 5));
      expect(follows.error, isNotNull);
      expect(follows.isWriting(a.account), isTrue);
      if (replay) {
        // Existing persisted event path, no store-level test invalidation:
        // another real client changes B; production polling refreshes known A.
        await viewer.setFollow(b.account, following: true);
        await feed.pollEventsOnce();
        await gateway.refreshed.future.timeout(const Duration(seconds: 5));
        for (var i=0;i<100;i++) {
          await pumpEventQueue();
          if (follows.stateFor(a.account)==true) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gateway.backgroundReads, greaterThan(0));
        expect(follows.stateFor(a.account), isTrue);
      }
      gateway.release.complete();
      final applied = await write;
      expect(applied, isFalse);
      expect(follows.isWriting(a.account), isFalse);
      expect((await viewer.getFollow(a.account)).following, isTrue);
      expect(follows.stateFor(a.account), isTrue);
      print('R8 replay=$replay: receiverA=true storeA=${follows.stateFor(a.account)} applied=$applied hasError=${follows.error != null} backgroundReads=${gateway.backgroundReads}');
      expect(follows.error, isNotNull,
          reason: 'A background refresh must not erase a still-pending failed unfollow feedback before its caller can display it');
    });
  }
}

class _RefreshGateway extends SpaceServiceGateway {
  _RefreshGateway(super.service, this.target);
  final String target;
  bool armed=false;bool held=false;int backgroundReads=0;
  final captured=Completer<void>();final release=Completer<void>();final refreshed=Completer<void>();
  @override
  Future<SpaceFollowState> setFollow(String account,{required bool following}) async {
    if(armed && account==target) throw upstreamUnavailable;
    return super.setFollow(account,following:following);
  }
  @override
  Future<SpaceFollowState> getFollow(String account) async {
    final state=await super.getFollow(account);
    if(armed && account==target) {
      if(!held) {held=true;captured.complete();await release.future;}
      else {backgroundReads++;if(!refreshed.isCompleted) refreshed.complete();}
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
