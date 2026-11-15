import 'package:bb_client/models/space_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';
import 'support/space_test_harness.dart';

void main() {
  testWidgets('feed renders a post from contract-valid fixtures', (
    WidgetTester tester,
  ) async {
    final FakeSpaceGateway gateway = FakeSpaceGateway();
    final SpacePost post = spacePost(
      postId: 'post-1',
      text: '今天的海风很好，顺手拍了几张。',
      likeCount: 3,
      commentCount: 2,
      viewCount: 7,
    );
    gateway.posts['post-1'] = post;
    gateway.postPages[''] = spacePagePost(<SpacePost>[post]);

    await pumpSpacePage(tester, gateway: gateway, size: spacePhone);

    expect(find.text('BB 空间'), findsOneWidget);
    expect(find.text('今天的海风很好，顺手拍了几张。'), findsOneWidget);
    expect(find.byKey(const Key('space-post-post-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
