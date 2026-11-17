// Review-only assertion for the production avatar -> profile route.
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_profile_gateway.dart';
import '../test/support/fake_space_gateway.dart';
import '../test/support/space_fixtures.dart';
import '../test/support/space_test_harness.dart';

void main() {
  testWidgets(
    'QA avatar entry loads the saved signature for the same identity',
    (tester) async {
      final gateway = FakeSpaceGateway();
      final profile = FakeProfileGateway(
        profile: const Profile(
          account: spacePeerAccount,
          username: 'bob',
          signature: 'QA saved signature',
          avatarUrl: '/avatars/10000002.png',
          avatarVersion: 'v1',
        ),
      );
      gateway.postPages[''] = spacePagePost([
        spacePost(
          postId: 'qa-identity',
          author: spaceAuthor(account: spacePeerAccount, username: 'bob'),
        ),
      ]);
      await pumpSpacePage(tester, gateway: gateway, profile: profile);
      await tester.tap(find.byKey(const Key('space-post-author-qa-identity')));
      await tester.pumpAndSettle();
      expect(find.byKey(SpaceProfilePage.pageKey), findsOneWidget);
      expect(find.text('bob'), findsWidgets);
      expect(
        find.text('QA saved signature'),
        findsOneWidget,
        reason: 'The seed from a card has no signature and must be hydrated from Profile',
      );
    },
  );
}
