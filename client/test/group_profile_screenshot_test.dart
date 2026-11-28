import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/profile/group_profile_host.dart';
import 'package:bb_client/ui/profile/group_profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _shotOwner = AuthUser(account: '10000001', username: '林照');
final ConversationRef _shotConv = ConversationRef.group(
  'group:${'a1b2c3d4' * 4}',
);

const List<GroupMember> _shotMembers = <GroupMember>[
  GroupMember(
    account: '10000001',
    username: '林照',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.owner,
  ),
  GroupMember(
    account: '10000002',
    username: '阿澈',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.member,
  ),
  GroupMember(
    account: '10000003',
    username: '小满',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.member,
  ),
  GroupMember(
    account: '10000004',
    username: '阿桔',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.offline,
    role: GroupRole.member,
  ),
  GroupMember(
    account: '10000005',
    username: '沈青',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.member,
  ),
  GroupMember(
    account: '10000006',
    username: '迟野',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.offline,
    role: GroupRole.member,
  ),
  GroupMember(
    account: '10000007',
    username: '桃桃',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.offline,
    role: GroupRole.member,
  ),
  GroupMember(
    account: '10000008',
    username: '阿雾',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.member,
  ),
];

class _ShotGroupApi extends GroupApiClient {
  _ShotGroupApi(this.profile) : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final GroupProfile profile;

  @override
  Future<GroupProfile> findGroup({
    required String token,
    required String groupNumber,
  }) async => profile;

  @override
  Future<GroupMemberPage> listGroupMembers({
    required String token,
    required ConversationRef conversation,
    String afterAccount = '',
    int limit = 50,
    bool includeCounts = false,
  }) async => GroupMemberPage(
    items: _shotMembers,
    counts: includeCounts
        ? const GroupMemberCounts(online: 5, total: 12)
        : null,
  );
}

/// Opt-in PNG evidence generator for DEA-515 Plan A v4 across mobile,
/// folded, and desktop viewports.
void main() {
  final String? outputDir = Platform.environment['QA_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture DEA-515 Plan A v4 across three viewports', (
    WidgetTester tester,
  ) async {
    final bool previousDisableShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      final Directory directory = Directory(outputDir!);
      directory.createSync(recursive: true);
      if (fontPath != null && File(fontPath).existsSync()) {
        final Uint8List fontBytes = File(fontPath).readAsBytesSync();
        await tester.runAsync(() async {
          for (final String family in <String>['Roboto', 'Ahem']) {
            await (FontLoader(family)..addFont(
                  Future<ByteData>.value(ByteData.view(fontBytes.buffer)),
                ))
                .load();
          }
        });
      }
      if (iconFontPath != null && File(iconFontPath).existsSync()) {
        final Uint8List iconBytes = File(iconFontPath).readAsBytesSync();
        await tester.runAsync(() async {
          await (FontLoader('MaterialIcons')..addFont(
                Future<ByteData>.value(ByteData.view(iconBytes.buffer)),
              ))
              .load();
        });
      }

      final GlobalKey boundary = GlobalKey();
      final AuthSession session = AuthSession()
        ..establish(token: 'shot', user: _shotOwner);
      final FakeChatService chat = FakeChatService(
        self: _shotOwner,
        users: const <ChatUser>[],
      );
      final FakeProfileGateway profileGateway = FakeProfileGateway()
        ..avatarFailure = const AuthFailure(
          status: 404,
          code: 'not_found',
          message: 'no avatar',
        );

      Future<void> pumpViewport({
        required Size size,
        required GroupProfile group,
        List<DisplayFeature> features = const <DisplayFeature>[],
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final GroupService groups = GroupService(
          api: _ShotGroupApi(group),
          session: session,
          avatarCache: AvatarCache(),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(),
              builder: (BuildContext context, Widget? child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(size: size, displayFeatures: features),
                child: child!,
              ),
              home: Scaffold(
                backgroundColor: AppColors.navShelf,
                body: Builder(
                  builder: (BuildContext context) => Center(
                    child: TextButton(
                      onPressed: () => openGroupProfileByNumber(
                        context,
                        groupNumber: group.groupNumber,
                        groups: groups,
                        chat: chat,
                        profile: profileGateway,
                      ),
                      child: const Text('打开群资料'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开群资料'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        });
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        await expectLater(
          find.byKey(boundary),
          matchesGoldenFile('../$outputDir/$name'),
        );
      }

      final GroupProfile ownerProfile = GroupProfile(
        conversation: _shotConv,
        groupNumber: '40284007',
        name: '晚风放映室',
        description: '每周五 21:00 一起看一部老电影，散场后聊二十分钟。本周放《花样年华》4K 修复版，片源已经放进群文件。进群请把群昵称改成「城市 · 昵称」，方便对号。',
        avatarUrl: '',
        avatarVersion: 'gv0',
        status: GroupStatus.active,
        role: GroupRole.owner,
        canInvite: true,
        allowMemberInvites: true,
      );

      await pumpViewport(size: const Size(390, 844), group: ownerProfile);
      await capture('group-profile-mobile-owner.png');

      await tester.tap(find.byKey(GroupProfilePanel.membersCardKey));
      await tester.pumpAndSettle();
      await capture('group-profile-mobile-members.png');

      await pumpViewport(
        size: const Size(900, 768),
        group: ownerProfile,
        features: const <DisplayFeature>[
          DisplayFeature(
            bounds: Rect.fromLTWH(450, 0, 8, 768),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
      );
      await capture('group-profile-folded-owner.png');

      await pumpViewport(size: const Size(1280, 900), group: ownerProfile);
      await capture('group-profile-desktop-owner.png');

      final GroupProfile memberEmpty = GroupProfile(
        conversation: _shotConv,
        groupNumber: '40284007',
        name: '晚风放映室',
        description: '',
        avatarUrl: '',
        avatarVersion: 'gv0',
        status: GroupStatus.active,
        role: GroupRole.member,
        canInvite: false,
        allowMemberInvites: false,
      );
      await pumpViewport(size: const Size(390, 844), group: memberEmpty);
      await capture('group-profile-mobile-member-empty.png');
    } finally {
      debugDisableShadows = previousDisableShadows;
    }
  }, skip: skipReason != null);
}
