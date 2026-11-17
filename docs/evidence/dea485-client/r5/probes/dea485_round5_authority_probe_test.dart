// Real receiver/event replay: delivery order must not redefine relationship truth.
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
  for (final mode in ['ack', 'reconciliation', 'accepted_later']) {
    test(
      mode == 'accepted_later'
          ? 'R5 a later accepted write still completes after earlier events'
          : 'R5 older $mode result cannot overwrite newer event-reconciled truth',
      () async {
        final base = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
        final cache = Directory.systemTemp.createTempSync('dea485-r5-');
        addTearDown(() => cache.deleteSync(recursive: true));
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final publisher = await _login(base, cache, 'pub$suffix');
        final viewer = await _login(base, cache, 'view$suffix');
        final draft = await publisher.createDraft(
          operationId: 'r5-d-$suffix',
          text: 'authority-$suffix',
        );
        await publisher.publishDraft(
          draftId: draft.resourceId!,
          operationId: 'r5-p-$suffix',
          expectedVersion: draft.resourceVersion!,
        );
        await viewer.setFollow(publisher.account, following: true);
        final gateway = _EpochGateway(viewer.service, mode, publisher.account);
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

        // First request really commits false. Delay its ACK, or its subsequent
        // real get_follow(false) reconciliation result, at the gateway boundary.
        gateway.armed = true;
        final write = follows.setFollowing(publisher.account, false);
        await gateway.captured.future.timeout(const Duration(seconds: 5));
        expect(
          (await viewer.getFollow(publisher.account)).following,
          mode == 'accepted_later',
        );

        // A later request for the same synthetic viewer commits true. Consume the
        // actual persisted follow.changed events through the production reader.
        if (mode == 'accepted_later') {
          await viewer.setFollow(publisher.account, following: false);
        }
        await viewer.setFollow(publisher.account, following: true);
        await feed.pollEventsOnce();
        await gateway.newerRead.future.timeout(const Duration(seconds: 5));
        final heldReads = mode == 'reconciliation' ? 1 : 0;
        for (var i = 0; i < 100; i++) {
          await pumpEventQueue();
          if (gateway.pending == heldReads &&
              follows.stateFor(publisher.account) == true)
            break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gateway.pending, heldReads);
        expect(follows.stateFor(publisher.account), isTrue);

        // Deliver the older false outcome after the newer authoritative true.
        gateway.release.complete();
        final applied = await write;
        expect(applied, mode != 'reconciliation');
        for (var i = 0; gateway.pending > 0 && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gateway.pending, 0);
        final authoritative = await viewer.getFollow(publisher.account);
        expect(authoritative.following, mode != 'accepted_later');
        expect(
          follows.stateFor(publisher.account),
          authoritative.following,
          reason: mode == 'accepted_later'
              ? 'A legitimate later accepted write must still complete after earlier events'
              : 'An older delivered result must not roll back the newer persisted relationship already observed through events',
        );
      },
    );
  }
}

class _EpochGateway extends SpaceServiceGateway {
  _EpochGateway(super.service, this.mode, this.target);
  final String mode;
  final String target;
  bool armed = false;
  bool heldRead = false;
  int pending = 0;
  final captured = Completer<void>();
  final release = Completer<void>();
  final newerRead = Completer<void>();

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    if (armed && targetAccount == target && mode == 'accepted_later') {
      captured.complete();
      await release.future;
    }
    final state = await super.setFollow(targetAccount, following: following);
    if (armed && targetAccount == target) {
      if (mode == 'ack') {
        captured.complete();
        await release.future;
      } else if (mode == 'reconciliation') {
        throw upstreamUnavailable;
      }
    }
    return state;
  }

  @override
  Future<SpaceFollowState> getFollow(String targetAccount) async {
    pending++;
    try {
      final state = await super.getFollow(targetAccount);
      if (armed &&
          targetAccount == target &&
          mode == 'reconciliation' &&
          !heldRead) {
        heldRead = true;
        captured.complete();
        await release.future;
      } else if (captured.isCompleted &&
          targetAccount == target &&
          state.following &&
          !newerRead.isCompleted) {
        newerRead.complete();
      }
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
