import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/space_fixtures.dart';

/// Real TCP path through the same [SpaceServiceGateway] the UI consumes.
///
/// Opt-in so CI does not need a server:
///   BB_SPACE_API_BASE=http://127.0.0.1:8765 \
///     flutter test test/space_real_api_test.dart
///
/// Synthetic accounts only; the caller is responsible for an isolated server.
void main() {
  final String? base = Platform.environment['BB_SPACE_API_BASE'];
  final String? skipReason = base == null
      ? 'BB_SPACE_API_BASE 未设置：本次未运行真实 API 路径'
      : null;

  test('real HTTP round trip: draft, image, publish, comment, like, visits, delete', () async {
    final Uri baseUri = Uri.parse(base!);
    final Directory cache = Directory.systemTemp.createTempSync('space-real-');
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
      'alice$suffix',
    );
    final SpaceServiceGateway bob = await _login(baseUri, cache, 'bob$suffix');

    final SpaceOverview overview = await alice.overview();
    expect(overview.contract, 'dea481-space-v1');

    final SpaceOperation created = await alice.createDraft(
      operationId: 'it-draft-$suffix',
      text: '真实接口草稿',
    );
    final String draftId = created.resourceId!;
    expect(created.resourceVersion, 1);

    final SpaceOperation imageAdded = await alice.addImage(
      draftId: draftId,
      operationId: 'it-image-$suffix',
      expectedVersion: created.resourceVersion!,
      filename: 'real.png',
      bytes: spaceTinyPng,
    );
    expect(imageAdded.resourceId, isNotNull);

    final SpaceDraft draft = await alice.getDraft(draftId);
    expect(draft.images, hasLength(1));
    final SpaceImage image = draft.images.single;

    final SpaceOperation updated = await alice.updateDraft(
      draftId: draftId,
      operationId: 'it-update-$suffix',
      expectedVersion: draft.version,
      text: '真实接口草稿（已排序）',
      imageIds: <String>[image.imageId],
    );

    final SpaceOperation published = await alice.publishDraft(
      draftId: draftId,
      operationId: 'it-publish-$suffix',
      expectedVersion: updated.resourceVersion!,
    );
    final String postId = published.resourceId!;
    expect(published.status, 'succeeded');

    final SpacePost post = await alice.getPost(
      postId,
      visitId: 'it-visit-$suffix',
    );
    expect(post.text, '真实接口草稿（已排序）');
    expect(post.images.single.imageId, image.imageId);
    expect(post.viewCount, greaterThanOrEqualTo(1));

    final SpaceImageContent bytes = await alice.image(
      image.imageId,
      variant: 'original',
    );
    final List<int> decoded = base64Decode(bytes.base64);
    expect(decoded.take(8).toList(), <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);

    final SpacePagePost bobFeed = await bob.listPosts(limit: 20);
    expect(bobFeed.items.map((SpacePost p) => p.postId), contains(postId));

    final SpaceOperation comment = await alice.createComment(
      postId,
      text: '真实评论',
      operationId: 'it-comment-$suffix',
    );
    final SpaceOperation reply = await bob.createComment(
      postId,
      text: '真实回复',
      replyToId: comment.resourceId,
      operationId: 'it-reply-$suffix',
    );
    expect(reply.resourceId, isNotNull);

    final SpaceOperation like = await bob.setLike(
      postId,
      liked: true,
      operationId: 'it-like-$suffix',
    );
    expect(like.status, 'succeeded');

    final SpacePageComment roots = await alice.listComments(postId, limit: 20);
    expect(
      roots.items.map((SpaceComment c) => c.commentId),
      contains(comment.resourceId),
    );
    final SpacePageComment replies = await alice.listComments(
      postId,
      rootId: comment.resourceId,
      limit: 20,
    );
    expect(
      replies.items.map((SpaceComment c) => c.commentId),
      contains(reply.resourceId),
    );

    final SpacePageNotification notifications = await alice.listNotifications(
      limit: 20,
    );
    expect(notifications.items, isNotEmpty);
    final SpaceNotification firstUnread = notifications.items.first;
    await alice.ackNotifications(<SpaceAckVersion>[
      SpaceAckVersion(
        notificationId: firstUnread.notificationId,
        version: firstUnread.version,
      ),
    ], operationId: 'it-ack-$suffix');

    final SpacePageVisitor visitors = await alice.listVisitors(postId);
    expect(visitors.items, isNotEmpty);
    await expectLater(
      bob.listVisitors(postId),
      throwsA(
        isA<AuthFailure>().having((AuthFailure e) => e.status, 'status', 403),
      ),
    );

    await alice.markRead(<String>[postId], operationId: 'it-read-$suffix');
    final SpacePagePost unread = await alice.listPosts(
      limit: 20,
      unreadOnly: true,
    );
    expect(
      unread.items.map((SpacePost p) => p.postId),
      isNot(contains(postId)),
    );

    final SpaceEventPage events = await alice.readEvents(afterEventId: 0);
    expect(events.items, isNotEmpty);

    final SpaceOperation deleted = await alice.deletePost(
      postId,
      operationId: 'it-delete-$suffix',
    );
    expect(deleted.resourceId, postId);
    await expectLater(alice.getPost(postId), throwsA(isA<AuthFailure>()));
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
    password: 'SpaceIT1pass',
  );
  final LoginResult login = await authApi.login(
    account: registered.account,
    password: 'SpaceIT1pass',
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
