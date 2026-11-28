import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/chat/user_directory_picker.dart';
import 'package:bb_client/ui/profile/group_profile_host.dart';
import 'package:bb_client/ui/profile/group_profile_panel.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _ownerUser = AuthUser(account: '10000001', username: '林照');
const AuthUser _memberUser = AuthUser(account: '10000002', username: '阿澈');
const AuthUser _visitorUser = AuthUser(account: '10000099', username: '路人');

final ConversationRef _groupConv = ConversationRef.group(
  'group:${'a1b2c3d4' * 4}',
);

const String _longDesc =
    '每周五 21:00 一起看一部老电影，散场后聊二十分钟。'
    '本周放《花样年华》4K 修复版，片源已经放进群文件。'
    '进群请把群昵称改成「城市 · 昵称」，方便对号。'
    '如果临时赶不上开场，也可以在群里留一句话，大家会等你一起讨论片尾。';

List<GroupMember> _sampleMembers() => List<GroupMember>.of(const <GroupMember>[
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
]);

class _FakeGroupApi extends GroupApiClient {
  _FakeGroupApi({required this.profile, required this.members})
    : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  GroupProfile profile;
  final List<GroupMember> members;
  int listMembersCalls = 0;
  int applyCalls = 0;
  int leaveCalls = 0;
  int dissolveCalls = 0;
  final List<List<String>> invitedAccounts = <List<String>>[];
  final List<String> removedAccounts = <String>[];

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
  }) async {
    listMembersCalls += 1;
    final int online = members
        .where((GroupMember m) => m.presence == Presence.online)
        .length;
    return GroupMemberPage(
      items: List<GroupMember>.unmodifiable(members),
      counts: includeCounts
          ? GroupMemberCounts(online: online, total: members.length)
          : null,
    );
  }

  @override
  Future<GroupProfile> updateGroup({
    required String token,
    required ConversationRef conversation,
    String? name,
    String? description,
    bool? allowMemberInvites,
    GroupAvatarBytes? avatar,
    bool resetAvatar = false,
  }) async {
    profile = GroupProfile(
      conversation: profile.conversation,
      groupNumber: profile.groupNumber,
      name: name ?? profile.name,
      description: description ?? profile.description,
      avatarUrl: resetAvatar ? '' : profile.avatarUrl,
      avatarVersion: profile.avatarVersion,
      status: profile.status,
      role: profile.role,
      canInvite:
          profile.role == GroupRole.owner ||
          (allowMemberInvites ?? profile.allowMemberInvites ?? false),
      allowMemberInvites: allowMemberInvites ?? profile.allowMemberInvites,
    );
    return profile;
  }

  @override
  Future<GroupRequestsResult> inviteToGroup({
    required String token,
    required ConversationRef conversation,
    required List<String> accounts,
  }) async {
    invitedAccounts.add(accounts);
    return GroupRequestsResult(
      requestIds: <String>[for (final String a in accounts) 'req-$a'],
    );
  }

  @override
  Future<GroupRequestsResult> applyToGroup({
    required String token,
    required ConversationRef conversation,
  }) async {
    applyCalls += 1;
    return const GroupRequestsResult(requestIds: <String>['req-apply-1']);
  }

  @override
  Future<GroupProfile> removeGroupMember({
    required String token,
    required ConversationRef conversation,
    required String account,
  }) async {
    removedAccounts.add(account);
    members.removeWhere((GroupMember m) => m.account == account);
    return profile;
  }

  @override
  Future<GroupProfile> leaveGroup({
    required String token,
    required ConversationRef conversation,
  }) async {
    leaveCalls += 1;
    profile = GroupProfile(
      conversation: profile.conversation,
      groupNumber: profile.groupNumber,
      name: profile.name,
      description: profile.description,
      avatarUrl: profile.avatarUrl,
      avatarVersion: profile.avatarVersion,
      status: profile.status,
      role: null,
      canInvite: false,
      allowMemberInvites: null,
    );
    return profile;
  }

  @override
  Future<GroupProfile> dissolveGroup({
    required String token,
    required ConversationRef conversation,
  }) async {
    dissolveCalls += 1;
    profile = GroupProfile(
      conversation: profile.conversation,
      groupNumber: profile.groupNumber,
      name: profile.name,
      description: profile.description,
      avatarUrl: profile.avatarUrl,
      avatarVersion: profile.avatarVersion,
      status: GroupStatus.dissolved,
      role: profile.role,
      canInvite: false,
      allowMemberInvites: false,
    );
    return profile;
  }
}

void main() {
  Future<void> openLiveGroup(
    WidgetTester tester, {
    required Size size,
    required AuthUser viewer,
    required GroupProfile group,
    required List<GroupMember> members,
    List<DisplayFeature> features = const <DisplayFeature>[],
    bool disableAnimations = false,
    _FakeGroupApi? apiOverride,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AuthSession session = AuthSession()
      ..establish(token: 'tok-v4', user: viewer);
    final _FakeGroupApi api =
        apiOverride ?? _FakeGroupApi(profile: group, members: members);
    final GroupService groups = GroupService(
      api: api,
      session: session,
      avatarCache: AvatarCache(),
    );
    final FakeChatService chat = FakeChatService(
      self: viewer,
      users: const <ChatUser>[
        ChatUser(
          account: '10000001',
          username: '林照',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
        ChatUser(
          account: '10000008',
          username: '苏晚',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
      ],
    );
    final FakeProfileGateway profileGateway = FakeProfileGateway();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            displayFeatures: features,
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: Scaffold(
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
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开群资料'));
    await tester.pumpAndSettle();
  }

  GroupProfile ownerGroup({
    String description = _longDesc,
    bool allowMemberInvites = true,
    GroupStatus status = GroupStatus.active,
  }) => GroupProfile(
    conversation: _groupConv,
    groupNumber: '40284007',
    name: '晚风放映室',
    description: description,
    avatarUrl: '',
    avatarVersion: 'gv0',
    status: status,
    role: GroupRole.owner,
    canInvite: status == GroupStatus.active,
    allowMemberInvites: allowMemberInvites,
  );

  testWidgets(
    'Plan A v4 adapts across mobile, folded, and desktop viewports with member-first ordering',
    (WidgetTester tester) async {
      // 1. Mobile (390x844)
      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _ownerUser,
        group: ownerGroup(),
        members: _sampleMembers(),
      );
      expect(find.byKey(ProfilePanelFrame.desktopCardKey), findsNothing);
      expect(find.byKey(GroupProfilePanel.haloKey), findsOneWidget);
      expect(find.byKey(GroupProfilePanel.membersCardKey), findsOneWidget);
      expect(find.text('群号 40284007'), findsOneWidget);
      expect(find.text('7 位成员'), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('4 人在线 · 阿澈、小满、沈青'), findsOneWidget);

      // Member-first ordering: member card is above description and owner management.
      final double membersTop = tester
          .getTopLeft(find.byKey(GroupProfilePanel.membersCardKey))
          .dy;
      final double introTop = tester.getTopLeft(find.text('群介绍')).dy;
      final double manageTop = tester.getTopLeft(find.text('群主管理')).dy;
      expect(membersTop, lessThan(introTop));
      expect(introTop, lessThan(manageTop));
      expect(tester.takeException(), isNull);

      // 2. Folded (900x768 with vertical hinge at x=450)
      await openLiveGroup(
        tester,
        size: const Size(900, 768),
        features: const <DisplayFeature>[
          DisplayFeature(
            bounds: Rect.fromLTWH(450, 0, 8, 768),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ],
        viewer: _ownerUser,
        group: ownerGroup(),
        members: _sampleMembers(),
      );
      expect(find.bySemanticsLabel('右侧内容已模糊'), findsOneWidget);
      final Rect foldedPanelRect = tester.getRect(
        find.byType(GroupProfilePanel),
      );
      expect(foldedPanelRect.width, 450);
      expect(tester.takeException(), isNull);

      // 3. Desktop (1280x900)
      await openLiveGroup(
        tester,
        size: const Size(1280, 900),
        viewer: _ownerUser,
        group: ownerGroup(),
        members: _sampleMembers(),
      );
      final Finder desktopCard = find.byKey(ProfilePanelFrame.desktopCardKey);
      expect(desktopCard, findsOneWidget);
      final Size cardSize = tester.getSize(desktopCard);
      expect(cardSize.width, lessThanOrEqualTo(440));
      expect(cardSize.height, lessThanOrEqualTo(700));
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Plan A v4 supports copy number feedback, intro expand/collapse, and empty description',
    (WidgetTester tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map<dynamic, dynamic>)['text']
                ?.toString();
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _ownerUser,
        group: ownerGroup(),
        members: _sampleMembers(),
      );

      // Copy group number -> copies text, shows checkmark & snackbar.
      await tester.tap(find.byKey(GroupProfilePanel.copyNumberKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(copiedText, '40284007');
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('群号已复制'), findsOneWidget);

      // Let copy icon reset after 1.6s so no pending timer remains.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

      // Intro expand/collapse.
      expect(find.text('展开'), findsOneWidget);
      await tester.tap(find.byKey(GroupProfilePanel.introToggleKey));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      await tester.tap(find.byKey(GroupProfilePanel.introToggleKey));
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);

      // Empty description state.
      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _ownerUser,
        group: ownerGroup(description: ''),
        members: _sampleMembers(),
      );
      expect(find.text('暂无介绍'), findsOneWidget);
      expect(find.byKey(GroupProfilePanel.introToggleKey), findsNothing);
    },
  );

  testWidgets(
    'Plan A v4 enforces owner/member/visitor/dissolved permissions, confirmations, and invite exclusion',
    (WidgetTester tester) async {
      // Owner: members subpage -> remove member confirm -> collapses row;
      // invite picker excludes existing members; toggle allowMemberInvites; disband confirm.
      final List<GroupMember> members = _sampleMembers();
      final _FakeGroupApi ownerApi = _FakeGroupApi(
        profile: ownerGroup(),
        members: members,
      );
      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _ownerUser,
        group: ownerApi.profile,
        members: members,
        apiOverride: ownerApi,
      );

      // Invite excludes 10000001 (existing) and selects 10000008 (苏晚).
      await tester.tap(find.byKey(GroupProfilePanel.inviteButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('苏晚'), findsOneWidget);
      await tester.tap(find.text('苏晚'));
      await tester.pump();
      await tester.tap(find.byKey(UserDirectoryPicker.confirmKey));
      await tester.pumpAndSettle();
      expect(ownerApi.invitedAccounts.single, <String>['10000008']);

      // Open members subpage -> verify summary, owner/self badges, and remove member.
      await tester.tap(find.byKey(GroupProfilePanel.membersCardKey));
      await tester.pumpAndSettle();
      expect(find.text('群成员（7）'), findsOneWidget);
      expect(find.text('7 位成员 · 4 人在线'), findsOneWidget);
      expect(find.text('群主 · 林照'), findsOneWidget);
      expect(find.text('你'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('remove-member-10000002')),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认将 阿澈（10000002）移出群聊吗？'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(ownerApi.removedAccounts, <String>['10000002']);
      expect(find.text('群成员（6）'), findsOneWidget);

      // Return to details -> count updated -> disband confirm.
      await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
      await tester.pumpAndSettle();
      expect(find.text('6 位成员'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(GroupProfilePanel.disbandButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('解散后所有成员将无法再收发消息且不可恢复。确定解散吗？'), findsOneWidget);
      await tester.tap(find.text('解散'));
      await tester.pumpAndSettle();
      expect(ownerApi.dissolveCalls, 1);
      expect(find.text('该群已解散'), findsOneWidget);
      expect(find.byKey(GroupProfilePanel.membersCardKey), findsNothing);

      // Member with allowMemberInvites=false sees locked note, no owner management, and leave confirmation.
      final _FakeGroupApi memberApi = _FakeGroupApi(
        profile: GroupProfile(
          conversation: _groupConv,
          groupNumber: '40284007',
          name: '晚风放映室',
          description: '群简介',
          avatarUrl: '',
          avatarVersion: 'gv0',
          status: GroupStatus.active,
          role: GroupRole.member,
          canInvite: false,
          allowMemberInvites: false,
        ),
        members: _sampleMembers(),
      );
      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _memberUser,
        group: memberApi.profile,
        members: memberApi.members,
        apiOverride: memberApi,
      );
      expect(find.byKey(GroupProfilePanel.inviteLockedNoteKey), findsOneWidget);
      expect(find.text('群主已关闭成员邀请'), findsOneWidget);
      expect(find.text('群主管理'), findsNothing);
      await tester.tap(find.byKey(GroupProfilePanel.leaveButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('退出后群会话将从列表移除，且无法再接收消息。确定退出吗？'), findsOneWidget);
      await tester.tap(find.text('退出'));
      await tester.pumpAndSettle();
      expect(memberApi.leaveCalls, 1);
      expect(find.byType(GroupProfilePanel), findsNothing);

      // Visitor: apply button only, never calls listGroupMembers.
      final _FakeGroupApi visitorApi = _FakeGroupApi(
        profile: GroupProfile(
          conversation: _groupConv,
          groupNumber: '40284007',
          name: '晚风放映室',
          description: '群简介',
          avatarUrl: '',
          avatarVersion: 'gv0',
          status: GroupStatus.active,
          role: null,
          canInvite: false,
        ),
        members: _sampleMembers(),
      );
      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _visitorUser,
        group: visitorApi.profile,
        members: visitorApi.members,
        apiOverride: visitorApi,
      );
      expect(visitorApi.listMembersCalls, 0);
      expect(find.byKey(GroupProfilePanel.membersCardKey), findsNothing);
      expect(find.text('申请加入'), findsOneWidget);
      await tester.tap(find.text('申请加入'));
      await tester.pumpAndSettle();
      expect(visitorApi.applyCalls, 1);
    },
  );

  testWidgets(
    'Plan A v4 respects reduced motion without animations or layout errors',
    (WidgetTester tester) async {
      await openLiveGroup(
        tester,
        size: const Size(390, 844),
        viewer: _ownerUser,
        group: ownerGroup(),
        members: _sampleMembers(),
        disableAnimations: true,
      );
      expect(find.byType(GroupProfilePanel), findsOneWidget);
      await tester.tap(find.byKey(GroupProfilePanel.introToggleKey));
      await tester.pump();
      expect(find.text('收起'), findsOneWidget);

      await tester.tap(find.byKey(GroupProfilePanel.membersCardKey));
      await tester.pump();
      expect(find.text('群成员（7）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
