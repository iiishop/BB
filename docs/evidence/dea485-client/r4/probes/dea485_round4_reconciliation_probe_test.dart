// Real receiver, injected delivery uncertainty at the gateway return boundary.
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
  for (final outcome in ['confirmed', 'reply_lost', 'not_sent']) {
    test(
      'R4 real receiver unfollow reconciliation keeps feed consistent: $outcome',
      () async {
        final base = Uri.parse(Platform.environment['BB_SPACE_API_BASE']!);
        final cache = Directory.systemTemp.createTempSync('dea485-r4-');
        addTearDown(() => cache.deleteSync(recursive: true));
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final publisher = await _login(base, cache, 'pub$suffix');
        final viewer = await _login(base, cache, 'view$suffix');
        final draft = await publisher.createDraft(
          operationId: 'r4-d-$suffix',
          text: 'receiver-authoritative-$suffix',
        );
        final published = await publisher.publishDraft(
          draftId: draft.resourceId!,
          operationId: 'r4-p-$suffix',
          expectedVersion: draft.resourceVersion!,
        );
        final postId = published.resourceId!;
        await viewer.setFollow(publisher.account, following: true);

        final gateway = _FaultGateway(viewer.service);
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
        addTearDown(feed.dispose);
        addTearDown(follows.dispose);
        await feed.start();
        await feed.switchScope(SpaceFeedScope.following);
        expect(feed.posts.map((p) => p.postId), contains(postId));
        expect(follows.stateFor(publisher.account), isTrue);

        gateway.fault = outcome;
        final applied = await follows.setFollowing(publisher.account, false);
        final remainsFollowing = outcome == 'not_sent';
        expect(applied, outcome == 'confirmed');
        expect(follows.error, outcome == 'confirmed' ? isNull : isNotNull);
        expect(
          (await viewer.getFollow(publisher.account)).following,
          remainsFollowing,
        );
        expect(follows.stateFor(publisher.account), remainsFollowing);
        final actual = await viewer.listPosts(scope: 'following');
        expect(actual.items.any((p) => p.postId == postId), remainsFollowing);

        // Only wait for a request the production controller actually launched.
        // Lost reply currently starts none: the assertion must reveal that.
        for (var i = 0; gateway.pendingFeedReads > 0 && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(gateway.pendingFeedReads, 0);
        expect(feed.scope, SpaceFeedScope.following);
        expect(
          feed.posts.map((p) => p.postId).toSet(),
          actual.items.map((p) => p.postId).toSet(),
          reason: 'Authoritative reconciliation must invalidate following snapshots just like a confirmed mutation',
        );
      },
    );
  }
}

class _FaultGateway extends SpaceServiceGateway {
  _FaultGateway(super.service);
  String? fault;
  int pendingFeedReads = 0;

  @override
  Future<SpaceFollowState> setFollow(
    String targetAccount, {
    required bool following,
  }) async {
    final selected = fault;
    fault = null;
    if (selected == 'not_sent') throw upstreamUnavailable;
    final state = await super.setFollow(targetAccount, following: following);
    if (selected == 'reply_lost') throw upstreamUnavailable;
    return state;
  }

  @override
  Future<SpacePagePost> listPosts({
    String? cursor,
    int limit = 20,
    bool unreadOnly = false,
    String? author,
    String scope = 'all',
  }) async {
    pendingFeedReads++;
    try {
      return await super.listPosts(
        cursor: cursor,
        limit: limit,
        unreadOnly: unreadOnly,
        author: author,
        scope: scope,
      );
    } finally {
      pendingFeedReads--;
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
