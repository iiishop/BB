import 'dart:ui' show DisplayFeature;

import 'package:bb_client/app.dart';
import 'package:bb_client/ui/space/profile/space_profile_modules.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:bb_client/ui/space/space_follow_store.dart';
import 'package:bb_client/ui/space/space_image_viewer.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_space_gateway.dart';
import 'fake_space_profile_gateway.dart';
import 'space_fixtures.dart';

/// Collaborators of one pumped author home page.
class ProfileRig {
  ProfileRig({required this.profile, required this.space, required this.store});

  final FakeSpaceProfileGateway profile;
  final FakeSpaceGateway space;
  final SpaceFollowStore store;
}

/// Pumps the author home page with the fixed browsing offset explicit, so the
/// directory/card-date convention is testable without depending on the host
/// machine zone.
Future<ProfileRig> pumpProfilePage(
  WidgetTester tester, {
  FakeSpaceProfileGateway? profile,
  FakeSpaceGateway? space,
  SpaceFollowStore? followStore,
  int displayOffsetMinutes = 0,
  Size size = const Size(390, 844),
  List<DisplayFeature> features = const <DisplayFeature>[],
  SpaceProfileModuleRegistry? modules,
  SpaceLocalStore? localStore,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final FakeSpaceProfileGateway profileGateway =
      profile ?? FakeSpaceProfileGateway();
  final FakeSpaceGateway spaceGateway =
      space ?? FakeSpaceGateway(account: spaceSelfAccount);
  final SpaceFollowStore store =
      followStore ??
      SpaceFollowStore(
        gateway: spaceGateway,
        viewerAccount: spaceGateway.account,
      );
  final SpaceLocalStore local =
      localStore ?? SpaceLocalStore(scopeKey: 'http://profile.test|test');

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(size: size, displayFeatures: features),
        child: child!,
      ),
      home: Scaffold(
        body: SpaceProfilePage(
          gateway: profileGateway,
          space: spaceGateway,
          followStore: store,
          userId: profileGateway.account,
          viewerAccount: profileGateway.viewer,
          images: SpaceImageLoader(spaceGateway),
          displayOffsetMinutes: displayOffsetMinutes,
          modules: modules,
          localStore: local,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
  return ProfileRig(profile: profileGateway, space: spaceGateway, store: store);
}
