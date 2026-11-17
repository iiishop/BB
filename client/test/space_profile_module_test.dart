import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';
import 'package:bb_client/ui/space/profile/space_profile_modules.dart';
import 'package:bb_client/ui/space/profile/space_profile_page.dart';
import 'package:bb_client/ui/space/profile/space_profile_posts_module.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_space_profile_gateway.dart';
import 'support/profile_test_harness.dart';

void main() {
  group('module registry', () {
    test('standard composition registers only the posts module', () {
      final SpaceProfileModuleRegistry registry =
          SpaceProfileModuleRegistry.standard();
      expect(registry.length, 1);
      expect(
        registry.contains(SpaceProfileModuleRegistry.postsModuleId),
        isTrue,
      );
      expect(registry.ordered.single.title, '说说');
    });

    test('a module can be registered without touching the posts module', () {
      final SpaceProfileModuleRegistry registry =
          SpaceProfileModuleRegistry.standard();
      registry.register(
        const SpaceProfileModule(
          id: 'test.albums',
          title: '相册（测试）',
          order: 5,
          builder: _testModuleBuilder,
        ),
      );
      expect(registry.length, 2);
      expect(
        registry.contains(SpaceProfileModuleRegistry.postsModuleId),
        isTrue,
      );
      expect(registry.ordered.last.id, 'test.albums');
    });

    test('duplicate ids are rejected instead of silently replacing', () {
      final SpaceProfileModuleRegistry registry =
          SpaceProfileModuleRegistry.standard();
      expect(
        () => registry.register(spacePostsModule()),
        throwsA(isA<StateError>()),
      );
    });

    test('order is stable and independent of registration order', () {
      final SpaceProfileModuleRegistry registry = SpaceProfileModuleRegistry(
        <SpaceProfileModule>[
          const SpaceProfileModule(
            id: 'b',
            title: 'B',
            order: 20,
            builder: _testModuleBuilder,
          ),
          const SpaceProfileModule(
            id: 'a',
            title: 'A',
            order: 10,
            builder: _testModuleBuilder,
          ),
        ],
      );
      expect(
        registry.ordered.map((SpaceProfileModule m) => m.id).toList(),
        <String>['a', 'b'],
      );
    });
  });

  testWidgets('a registered test module renders next to the posts module', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    gateway.putPage(
      items: <SpaceProfileEntry>[
        profileEntry(postId: 'post-1', timelineAt: '2026-11-10T12:00:00Z'),
      ],
    );
    final SpaceProfileModuleRegistry registry =
        SpaceProfileModuleRegistry.standard();
    registry.register(
      const SpaceProfileModule(
        id: 'test.module',
        title: '测试模块',
        order: 90,
        builder: _testModuleBuilder,
      ),
    );

    await _pumpProfile(tester, gateway: gateway, modules: registry);

    expect(find.byKey(const Key('space-profile-test-module')), findsOneWidget);
    expect(find.byKey(SpaceProfilePostsModule.listKey), findsOneWidget);
    expect(find.byKey(const Key('space-post-post-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a composition without modules shows the empty container state', (
    WidgetTester tester,
  ) async {
    final FakeSpaceProfileGateway gateway = FakeSpaceProfileGateway();
    await _pumpProfile(
      tester,
      gateway: gateway,
      modules: SpaceProfileModuleRegistry(),
    );
    expect(find.byKey(SpaceProfilePage.emptyModulesKey), findsOneWidget);
  });
}

Widget _testModuleBuilder(BuildContext context, SpaceProfileModuleScope scope) {
  return const Center(
    child: Text('测试模块', key: Key('space-profile-test-module')),
  );
}

Future<void> _pumpProfile(
  WidgetTester tester, {
  required FakeSpaceProfileGateway gateway,
  SpaceProfileModuleRegistry? modules,
  Size size = const Size(390, 844),
}) async {
  await pumpProfilePage(tester, profile: gateway, modules: modules, size: size);
}
