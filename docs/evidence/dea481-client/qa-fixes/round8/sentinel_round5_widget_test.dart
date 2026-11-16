import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test/space_detail_test.dart' show gatewayWithPost;
import '../../test/support/fake_space_gateway.dart';
import '../../test/support/space_fixtures.dart';
import '../../test/support/space_test_harness.dart';

void main() {
  testWidgets('T07 open viewer stops displaying image after deletion event', (tester) async {
    final gateway = gatewayWithPost(spacePost(postId: 'post-1',
      images: <SpaceImage>[spaceImage(imageId: 'img-1')]));
    await pumpSpacePage(tester, gateway: gateway, autoPoll: true,
      pollInterval: const Duration(seconds: 10));
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.tap(find.byKey(const Key('space-image-img-1')));
    await tester.pumpAndSettle();
    final rendered = find.descendant(of: find.byType(SpaceImageViewer), matching: find.byType(Image));
    expect(rendered, findsOneWidget);
    gateway.posts.remove('post-1');
    gateway.postPages[''] = spacePagePost([]);
    gateway.failNext('get_image', spaceNotFound);
    gateway.eventPages.add(spaceEventPage([
      spaceEvent(eventId: 11, type: 'post.deleted', postId: 'post-1'),
    ]));
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(gateway.eventPages, isEmpty, reason: 'actual page polling consumed deletion');
    expect(rendered, findsNothing,
      reason: 'online viewer must clear displayed image after its post is deleted');
  });
}
