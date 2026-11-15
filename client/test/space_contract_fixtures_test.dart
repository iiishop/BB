import 'dart:convert';

import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/ui/space/space_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/space_fixtures.dart';

void main() {
  test('every fixture builder validates against the single shared schema', () {
    final SpaceAuthor author = spaceAuthor();
    final SpaceImage image = spaceImage();
    final SpaceComment root = spaceComment(commentId: 'root-1');
    final SpaceComment reply = spaceComment(
      commentId: 'reply-1',
      rootId: 'root-1',
      replyToId: 'root-1',
      replyToAuthor: author,
    );
    final SpaceBranch branch = spaceBranch(
      root: root,
      replies: <SpaceComment>[reply],
    );
    final SpacePost post = spacePost(
      postId: 'post-1',
      author: author,
      images: <SpaceImage>[image],
      reference: spaceReference(),
      previewComments: <SpaceBranch>[branch],
      remainingRoots: 2,
    );
    expect(spacePagePost(<SpacePost>[post]).items.single.postId, 'post-1');
    expect(spacePageComment(<SpaceComment>[root, reply]).items, hasLength(2));
    expect(
      spaceContext(root: root, target: reply, parent: root).target.commentId,
      'reply-1',
    );
    expect(spaceNotification(notificationId: 'n1', version: 2).version, 2);
    expect(spaceOperation(operationId: 'op-1').status, 'succeeded');
    expect(spaceDraft().state, 'draft');
    expect(spaceOverview().contract, 'dea481-space-v1');
    expect(spaceViewSummary().viewCount, 0);
    expect(spaceVisitor().count, 1);
    expect(
      spacePageVisitor(<SpaceVisitor>[spaceVisitor()]).items,
      hasLength(1),
    );
    expect(spacePageAuthor(<SpaceAuthor>[author]).items, hasLength(1));
    expect(spaceEventPage(<SpaceEvent>[spaceEvent()]).nextEventId, 1);
    expect(spaceImageContent().mimeType, 'image/png');
    expect(base64Decode(spaceImageContent().base64), spaceTinyPng);
  });

  test('the contract validator actually rejects a drifted payload', () {
    expect(
      () => validateSpace('overview', <String, dynamic>{
        'contract': 'not-the-contract',
        'unread_posts': 0,
        'unread_notifications': 0,
        'latest_event_id': 0,
      }, kind: 'response'),
      throwsFormatException,
    );
    expect(
      () => validateSpace('get_post', <String, dynamic>{
        'post_id': 'post-1',
      }, kind: 'response'),
      throwsFormatException,
    );
  });

  test('image bytes use the same base64 transport as the service', () {
    expect(spaceBase64(spaceTinyPng), base64Encode(spaceTinyPng));
  });
}
