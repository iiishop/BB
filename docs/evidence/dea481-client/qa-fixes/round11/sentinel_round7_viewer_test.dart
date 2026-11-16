import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test/space_detail_test.dart' show gatewayWithPost;
import '../../test/support/fake_space_gateway.dart';
import '../../test/support/space_fixtures.dart';
import '../../test/support/space_test_harness.dart';

void main() {
  testWidgets('T07 deleting repost preserves open viewer of live source', (tester) async {
    final gateway = gatewayWithPost(spacePost(postId: 'post-1',
      images: <SpaceImage>[spaceImage(imageId: 'img-1')]));
    final repost = spacePost(postId: 'repost-1', reference: spaceReference(postId: 'post-1', image: spaceImage(imageId: 'img-1')));
    gateway.posts['repost-1'] = repost;
    gateway.postPages[''] = spacePagePost([gateway.posts['post-1']!, repost]);
    await pumpSpacePage(tester, gateway: gateway, autoPoll: true,
      pollInterval: const Duration(seconds: 10));
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.tap(find.byKey(const Key('space-image-img-1')));
    await tester.pumpAndSettle();
    final rendered = find.descendant(of: find.byType(SpaceImageViewer), matching: find.byType(Image));
    expect(rendered, findsOneWidget);
    gateway.posts.remove('repost-1');
    gateway.postPages[''] = spacePagePost([gateway.posts['post-1']!]);
    gateway.eventPages.add(spaceEventPage([
      spaceEvent(eventId: 11, type: 'post.deleted', postId: 'repost-1'),
    ]));
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(gateway.eventPages, isEmpty, reason: 'actual page polling consumed deletion');
    expect(rendered, findsOneWidget,
      reason: 'deleting a repost must not invalidate the still-live source viewer');
  });
}
