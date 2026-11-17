import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:bb_client/ui/space/profile/space_profile_adapter.dart';
import 'package:bb_client/ui/space/profile/space_profile_controller.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real TCP path for the DEA-485 profile/follow contract, through the same
/// [SpaceServiceGateway] the UI consumes.
///
/// Opt-in so CI does not need a server:
///   BB_SPACE_API_BASE=http://127.0.0.1:8766 \
///     flutter test test/space_profile_real_api_test.dart
///
/// Synthetic accounts only; the caller must point this at an isolated server.
void main() {
  final String? base = Platform.environment['BB_SPACE_API_BASE'];
  final String? skipReason = base == null
      ? 'BB_SPACE_API_BASE 未设置：本次未运行真实后端双账号路径'
      : null;

  test('real HTTP: profile timeline, months, follow scope and stale cursor', () async {
    final Uri baseUri = Uri.parse(base!);
    final Directory cache = Directory.systemTemp.createTempSync(
      'profile-real-',
    );
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort; the temporary cache holds no user content.
      }
    });
    final String suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final SpaceServiceGateway alice = await _login(
      baseUri,
      cache,
      'palice$suffix',
    );
    final SpaceServiceGateway bob = await _login(baseUri, cache, 'pbob$suffix');
    final String aliceAccount = alice.account;
    final String bobAccount = bob.account;

    Future<String> publish(SpaceServiceGateway who, String text) async {
      final SpaceOperation draft = await who.createDraft(
        operationId: 'p-draft-$suffix-${text.hashCode}',
        text: text,
      );
      final SpaceOperation published = await who.publishDraft(
        draftId: draft.resourceId!,
        operationId: 'p-pub-$suffix-${text.hashCode}',
        expectedVersion: draft.resourceVersion!,
      );
      return published.resourceId!;
    }

    final String bobPost = await publish(bob, 'bob 的原文');
    final String first = await publish(alice, 'alice 第一条');
    final String second = await publish(alice, 'alice 第二条');
    final String third = await publish(alice, 'alice 第三条');

    // Bob reads Alice's author-scoped timeline and directory.
    final SpacePagePost timeline = await bob.listProfilePosts(
      targetAccount: aliceAccount,
      timezoneOffsetMinutes: 0,
    );
    expect(timeline.items.map((SpacePost p) => p.postId).toSet(), <String>{
      first,
      second,
      third,
    });
    final SpaceProfileMonthDirectory months = await bob.listProfileMonths(
      targetAccount: aliceAccount,
      timezoneOffsetMinutes: 0,
    );
    expect(months.items, isNotEmpty);
    expect(months.items.any((m) => m.year >= 2026), isTrue);

    // Authoritative follow state and the following-scope feed.
    expect((await bob.getFollow(aliceAccount)).following, isFalse);
    expect(
      (await bob.setFollow(aliceAccount, following: true)).following,
      isTrue,
    );
    final SpacePagePost followingFeed = await bob.listPosts(
      scope: 'following',
      limit: 20,
    );
    expect(
      followingFeed.items.map((SpacePost p) => p.postId).toSet(),
      containsAll(<String>[first, second, third]),
    );
    expect(
      followingFeed.items.every((SpacePost p) => p.authorFollowing),
      isTrue,
    );

    // Month-anchored continuation: the receiver binds the cursor to the
    // selected month, so the client must repeat it (Q1 regression).
    final SpaceMonthCoordinate month = months.items.first;
    final String wireMonth =
        '${month.year}-${month.month.toString().padLeft(2, '0')}';
    final SpacePagePost monthFirst = await bob.listProfilePosts(
      targetAccount: aliceAccount,
      timezoneOffsetMinutes: 0,
      month: wireMonth,
      limit: 1,
    );
    expect(monthFirst.items, hasLength(1));
    final SpacePagePost monthNext = await bob.listProfilePosts(
      targetAccount: aliceAccount,
      timezoneOffsetMinutes: 0,
      month: wireMonth,
      cursor: monthFirst.nextCursor,
      limit: 1,
    );
    expect(monthNext.items, hasLength(1));
    expect(
      monthNext.items.single.postId,
      isNot(monthFirst.items.single.postId),
    );

    final SpaceProfileController profileController = SpaceProfileController(
      gateway: SpaceProfileAdapter(space: bob),
      space: bob,
      userId: aliceAccount,
      viewerAccount: bobAccount,
      displayOffsetMinutes: 0,
      pageSize: 1,
    );
    addTearDown(profileController.dispose);
    await profileController.start();
    await profileController.jumpToMonth(
      SpaceProfileMonth(year: month.year, month: month.month),
    );
    expect(profileController.entries, hasLength(1));
    expect(profileController.hasMore, isTrue);
    await profileController.loadMore();
    expect(
      profileController.error,
      isNull,
      reason: 'Month-anchored continuation must be accepted by the real server',
    );
    expect(profileController.entries, hasLength(2));

    // A stale following cursor is rejected after the relationship changes; the
    // UI restarts the view from its first page on this code.
    final SpacePagePost firstPage = await bob.listPosts(
      scope: 'following',
      limit: 1,
    );
    final String? staleCursor = firstPage.nextCursor;
    expect(staleCursor, isNotNull);
    await bob.setFollow(aliceAccount, following: false);
    await expectLater(
      bob.listPosts(scope: 'following', cursor: staleCursor, limit: 1),
      throwsA(
        isA<AuthFailure>()
            .having((AuthFailure e) => e.status, 'status', 422)
            .having((AuthFailure e) => e.code, 'code', 'validation_error'),
      ),
    );

    // Following never leaks as a permission change.
    expect(
      (await bob.setFollow(aliceAccount, following: true)).following,
      isTrue,
    );
    expect(bobAccount, isNot(aliceAccount));
    expect(bobPost, isNotEmpty);
  }, skip: skipReason);
}

Future<SpaceServiceGateway> _login(
  Uri baseUri,
  Directory cache,
  String username,
) async {
  final AuthApiClient authApi = AuthApiClient(baseUri: baseUri);
  final AuthUser registered = await authApi.register(
    username: username,
    password: 'ProfileIT1pass',
  );
  final LoginResult login = await authApi.login(
    account: registered.account,
    password: 'ProfileIT1pass',
  );
  final AuthSession session = AuthSession()
    ..establish(token: login.token, user: login.user);
  final ChatService chat = ChatService(
    api: ChatApiClient(baseUri: baseUri),
    session: session,
    ledger: ChatLedger.inMemory(),
    cacheRoot: cache,
    webSocketHints: false,
  );
  return SpaceServiceGateway(
    SpaceService(
      api: SpaceApiClient(baseUri: baseUri),
      session: session,
      chat: chat,
    ),
  );
}
