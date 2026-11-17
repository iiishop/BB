// Real receiver: unresolved ordering requires truth or an explicit failure.
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
  for (final mode in ['later_ok', 'later_unavailable', 'earlier_unavailable']) {
    test('R6 authority recovery resolves truth or reports failure: $mode', () async {
      final base = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
      final cache = Directory.systemTemp.createTempSync('dea485-r6-');
      addTearDown(() => cache.deleteSync(recursive: true));
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final publisher = await _login(base, cache, 'pub$suffix');
      final viewer = await _login(base, cache, 'view$suffix');
      final draft = await publisher.createDraft(
        operationId: 'r6-d-$suffix',
        text: 'recovery-$suffix',
      );
      await publisher.publishDraft(
        draftId: draft.resourceId!,
        operationId: 'r6-p-$suffix',
        expectedVersion: draft.resourceVersion!,
      );
      await viewer.setFollow(publisher.account, following: true);
      final gateway = _RecoveryGateway(viewer.service, mode, publisher.account);
      final follows = SpaceFollowStore(
        gateway: gateway,
        viewerAccount: viewer.account,
      );
      final feed = SpaceController(
        gateway: gateway,
        followStore: follows,
        store: SpaceLocalStore(scopeKey: gateway.scopeKey),
        autoPoll: false,
      );
      addTearDown(follows.dispose);
      addTearDown(feed.dispose);
      await feed.start();
      await feed.switchScope(SpaceFeedScope.following);
      expect(follows.stateFor(publisher.account), isTrue);

      gateway.armed = true;
      final write = follows.setFollowing(publisher.account, false);
      await gateway.captured.future.timeout(const Duration(seconds: 5));
      final earlier = mode == 'earlier_unavailable';
      expect((await viewer.getFollow(publisher.account)).following, !earlier);
      if (!earlier) await viewer.setFollow(publisher.account, following: false);
      await viewer.setFollow(publisher.account, following: true);
      await feed.pollEventsOnce();
      await gateway.newerRead.future.timeout(const Duration(seconds: 5));
      for (var i = 0; i < 100; i++) {
        await pumpEventQueue();
        if (gateway.pending == 0 && follows.stateFor(publisher.account) == true)
          break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gateway.pending, 0);
      expect(follows.stateFor(publisher.account), isTrue);

      // The write's own ACK succeeds. Only the new ordering-resolution GET is
      // unavailable; already observed event reads above succeeded normally.
      gateway.failFreshReads = mode != 'later_ok';
      gateway.release.complete();
      final applied = await write;
      for (var i = 0; gateway.pending > 0 && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gateway.pending, 0);
      final authoritative = await viewer.getFollow(publisher.account);
      expect(authoritative.following, earlier);
      final consistent =
          follows.stateFor(publisher.account) == authoritative.following;
      print(
        'R6 $mode: receiver=${authoritative.following} store=${follows.stateFor(publisher.account)} applied=$applied hasError=${follows.error != null} failedReads=${gateway.failedReads}',
      );
      if (!consistent) {
        expect(
          applied,
          isFalse,
          reason: 'Unresolved failed recovery must not report settled success while displayed relationship contradicts receiver',
        );
        expect(
          follows.error,
          isNotNull,
          reason: 'The existing UI requires applied=false and an error to surface inability to complete',
        );
      }
      if (mode == 'later_ok') {
        expect(consistent, isTrue);
        expect(applied, isTrue);
      }
    });
  }
}

class _RecoveryGateway extends SpaceServiceGateway {
  _RecoveryGateway(super.service, this.mode, this.target);
  final String mode;
  final String target;
  bool armed = false;
  bool afterCommit = false;
  bool failFreshReads = false;
  int failedReads = 0;
  int pending = 0;
  final captured = Completer<void>();
  final release = Completer<void>();
  final newerRead = Completer<void>();

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    if (armed && mode != 'earlier_unavailable') {
      captured.complete();
      await release.future;
    }
    final state = await super.setFollow(targetAccount, following: following);
    if (armed && mode == 'earlier_unavailable') {
      captured.complete();
      await release.future;
    }
    afterCommit = true;
    return state;
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    pending++;
    try {
      if (afterCommit && failFreshReads && targetAccount == target) {
        failedReads++;
        throw upstreamUnavailable;
      }
      final state = await super.getFollow(targetAccount);
      if (captured.isCompleted &&
          targetAccount == target &&
          state.following &&
          !newerRead.isCompleted)
        newerRead.complete();
      return state;
    } finally {
      pending--;
    }
  }

  @override
  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
    String? author,
    String scope = 'all',
  }) async {
    pending++;
    try {
      return await super.listPosts(
        cursor: cursor,
        limit: limit,
        unreadOnly: unreadOnly,
        author: author,
        scope: scope,
      );
    } finally {
      pending--;
    }
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
