import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/chat_system_entry.dart';
import 'package:bb_client/ui/chat/user_directory_picker.dart';
import 'package:bb_client/ui/chat/user_identity_row.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/notifications/notification_center.dart';
import 'package:bb_client/ui/profile/group_profile_panel.dart';
import 'package:bb_client/ui/profile/profile_details.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '',
  avatarVersion: 'v1',
  presence: Presence.online,
  lastMessage: UserPreview(
    id: 'm1',
    senderAccount: '10000002',
    senderUsername: 'bob',
    previewBody: 'PRIVATE PREVIEW',
  ),
);
const ChatUser _carol = ChatUser(
  account: '10000003',
  username: 'carol',
  avatarUrl: '',
  avatarVersion: 'v1',
  presence: Presence.offline,
);

class _PeerProfile extends FakeProfileGateway {
  String? requested;
  @override
  Future<Profile> loadProfile({String? account, AuthIdentity? captured}) async {
    requested = account;
    return Profile(
      account: account!,
      username: 'peer profile',
      signature: 'peer signature',
      avatarUrl: '',
      avatarVersion: 'v1',
    );
  }
}

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;
  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: const [_bob, _carol],
      userPageSize: 1,
    );
    profile = FakeProfileGateway();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(375, 812),
    List<DisplayFeature> features = const [],
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            displayFeatures: features,
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(375, 812),
    const Size(1280, 900),
    const Size(900, 768),
  ]) {
    testWidgets('third navigation works without Space at $size', (
      tester,
    ) async {
      final heartbeat = HeartbeatController(
        auth: AuthService(
          api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
          session: AuthSession(),
        ),
      );
      addTearDown(heartbeat.dispose);
      await pump(
        tester,
        HomeView(
          user: _self,
          profile: profile,
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          chat: chat,
          onSignedOut: (_) {},
          onSessionExpired: () {},
        ),
        size: size,
        features: size.width == 900
            ? const [
                DisplayFeature(
                  bounds: Rect.fromLTWH(450, 0, 8, 768),
                  type: DisplayFeatureType.hinge,
                  state: DisplayFeatureState.postureFlat,
                ),
              ]
            : const [],
      );
      expect(find.byKey(HomeView.navNotificationsKey), findsOneWidget);
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await tester.pumpAndSettle();
      expect(find.text('通知暂不可用'), findsOneWidget);
      expect(find.byType(ChatPage), findsNothing);
      await tester.tap(find.byKey(HomeView.navChatKey));
      await tester.pumpAndSettle();
      expect(find.text('消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'directory paginates identity only, preserves selection across search, returns users',
    (tester) async {
      List<ChatUser>? result;
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await openUserDirectoryPicker(
                context,
                chat: chat,
                profile: profile,
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(chat.listUsersCalls.length, 2);
      expect(find.text('PRIVATE PREVIEW'), findsNothing);
      expect(find.text('尚未联系'), findsNothing);
      expect(chat.conversationCalls, isEmpty);
      await tester.tap(find.text('bob'));
      await tester.pump();
      await tester.enterText(
        find.byKey(UserDirectoryPicker.searchKey),
        'carol',
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(UserIdentityRow.rowKey(_carol.account)),
          matching: find.text('carol'),
        ),
      );
      await tester.pump();
      expect(find.text('确认选择（2）'), findsOneWidget);
      await tester.tap(find.byKey(UserDirectoryPicker.confirmKey));
      await tester.pumpAndSettle();
      expect(result!.map((u) => u.account), [_bob.account, _carol.account]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('directory supports skip and failed read retry', (tester) async {
    chat.listUsersFails = true;
    List<ChatUser>? result;
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await openUserDirectoryPicker(
              context,
              chat: chat,
              profile: profile,
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(UserDirectoryPicker.confirmKey))
          .onPressed,
      isNull,
    );
    chat.listUsersFails = false;
    await tester.tap(find.byKey(UserDirectoryPicker.retryKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(UserDirectoryPicker.confirmKey));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });

  testWidgets('directory selection survives desktop and phone reflow', (
    tester,
  ) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              openUserDirectoryPicker(context, chat: chat, profile: profile),
          child: const Text('open'),
        ),
      ),
      size: const Size(1280, 900),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bob'));
    await tester.pump();
    final state = tester.state(find.byType(UserDirectoryPicker));
    tester.view.physicalSize = const Size(375, 812);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(UserDirectoryPicker)), same(state));
    expect(find.text('确认选择（1）'), findsOneWidget);
    await tester.enterText(
      find.byKey(UserDirectoryPicker.searchKey),
      'unmatched',
    );
    await tester.pump();
    expect(find.text('没有匹配的用户'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    testWidgets(
      'member identity opens chat using $platform gesture; removal is separate',
      (tester) async {
        int opens = 0;
        int removals = 0;
        await pump(
          tester,
          Align(
            alignment: Alignment.topCenter,
            child: UserIdentityRow(
              user: _bob,
              profile: profile,
              onOpenChat: () => opens++,
              trailing: IconButton(
                tooltip: '移除成员',
                icon: const Icon(Icons.person_remove_outlined),
                onPressed: () => removals++,
              ),
            ),
          ),
        );
        await tester.tap(find.text('bob'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(opens, platform == TargetPlatform.linux ? 0 : 1);
        if (platform == TargetPlatform.linux) {
          await tester.tap(find.text('bob'));
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(find.text('bob'));
          await tester.pump();
          expect(opens, 1);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        }
        await tester.tap(find.byTooltip('移除成员'));
        await tester.pumpAndSettle();
        expect(removals, 1);
        expect(opens, 1);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant(<TargetPlatform>{platform}),
    );
  }

  testWidgets(
    'pending includes read actions, excludes informational and invalidated entries; supports three actions',
    (tester) async {
      int calls = 0;
      final entries = [
        NotificationEntry(
          id: 'pending',
          title: '已读未处理',
          body: 'body',
          timeLabel: '今天',
          read: true,
          actions: [
            for (final id in ['accept', 'reject', 'another'])
              NotificationEntryAction(
                id: id,
                label: id,
                onPressed: () => calls++,
              ),
          ],
        ),
        const NotificationEntry(
          id: 'info',
          title: '告知',
          body: 'body',
          timeLabel: '今天',
        ),
        NotificationEntry(
          id: 'expired',
          title: '失效',
          body: 'body',
          timeLabel: '今天',
          invalidated: true,
          actions: [
            NotificationEntryAction(
              id: 'old',
              label: 'old',
              onPressed: () => calls++,
            ),
          ],
        ),
      ];
      await pump(
        tester,
        NotificationCenter(entries: entries),
        size: const Size(375, 812),
        textScale: 2,
      );
      expect(
        find.byKey(NotificationCenter.actionKey('expired', 'old')),
        findsNothing,
      );
      await tester.tap(find.byKey(NotificationCenter.pendingKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(NotificationCenter.entryKey('pending')),
        findsOneWidget,
      );
      expect(find.byKey(NotificationCenter.entryKey('info')), findsNothing);
      expect(find.byKey(NotificationCenter.entryKey('expired')), findsNothing);
      await tester.ensureVisible(
        find.byKey(NotificationCenter.actionKey('pending', 'another')),
      );
      await tester.tap(
        find.byKey(NotificationCenter.actionKey('pending', 'another')),
      );
      await tester.pump();
      expect(calls, 1); // Displaying and filtering never executes an action.
      expect(find.text('已读未处理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final role in GroupProfileRole.values) {
    testWidgets('group profile exposes $role controls at 200% text', (
      tester,
    ) async {
      await pump(
        tester,
        GroupProfilePanel(
          number: '10000002',
          name: '长群名 ' * 8,
          description: '简介 ' * 40,
          role: role,
          onApply: () {},
          onEdit: () {},
          onInvite: () {},
          onMembers: () {},
          onLeave: () {},
          onDisband: () {},
        ),
        textScale: 2,
      );
      final bool owner = role == GroupProfileRole.owner;
      final bool visitor = role == GroupProfileRole.visitor;
      // Scroll all controls into the sliver cache before inspecting visibility.
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('编辑群资料'), owner ? findsOneWidget : findsNothing);
      expect(find.text('解散群聊'), owner ? findsOneWidget : findsNothing);
      expect(
        find.text('退出群聊'),
        role == GroupProfileRole.member ? findsOneWidget : findsNothing,
      );
      if (visitor) expect(find.text('查看成员'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('dissolved profile keeps basics and removes actions', (
    tester,
  ) async {
    await pump(
      tester,
      const GroupProfilePanel(
        number: '10000002',
        name: 'group',
        description: 'intro',
        role: GroupProfileRole.owner,
        dissolved: true,
      ),
    );
    expect(find.text('群号 10000002'), findsOneWidget);
    expect(find.text('该群已解散'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets(
    'group name rejects whitespace; empty optional description stays optional',
    (tester) async {
      String? name;
      String? description;
      await pump(
        tester,
        GroupDetailsForm(
          onSubmit: (n, d) {
            name = n;
            description = d;
          },
        ),
      );
      await tester.enterText(find.byType(TextFormField).first, '   ');
      await tester.tap(find.text('保存群资料'));
      await tester.pumpAndSettle();
      expect(find.text('请输入群名称'), findsOneWidget);
      expect(name, isNull);
      await tester.enterText(find.byType(TextFormField).first, '  group  ');
      await tester.tap(find.text('保存群资料'));
      await tester.pumpAndSettle();
      expect(name, 'group');
      expect(description, isNull);
    },
  );

  testWidgets(
    'chat header opens requested peer profile and returns to the same chat',
    (tester) async {
      final gateway = _PeerProfile();
      await pump(tester, ChatPage(peer: _bob, chat: chat, profile: gateway));
      final state = tester.state(find.byType(ChatPage));
      await tester.tap(find.byKey(ChatPage.headerProfileKey));
      await tester.pumpAndSettle();
      expect(gateway.requested, _bob.account);
      expect(find.text('BB号 ${_bob.account}'), findsOneWidget);
      expect(find.byType(PersonProfilePanel), findsOneWidget);
      expect(find.byKey(ProfilePanel.editProfileKey), findsNothing);
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ChatPage)), same(state));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reusing a person panel reloads the requested identity', (
    tester,
  ) async {
    final gateway = _PeerProfile();
    final account = ValueNotifier<String>(_bob.account);
    addTearDown(account.dispose);
    await pump(
      tester,
      ValueListenableBuilder<String>(
        valueListenable: account,
        builder: (_, value, _) =>
            PersonProfilePanel(account: value, gateway: gateway),
      ),
    );
    final state = tester.state(find.byType(PersonProfilePanel));
    expect(find.text('BB号 ${_bob.account}'), findsOneWidget);
    account.value = _carol.account;
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(PersonProfilePanel)), same(state));
    expect(find.text('BB号 ${_carol.account}'), findsOneWidget);
    expect(find.text('BB号 ${_bob.account}'), findsNothing);
    expect(gateway.requested, _carol.account);
  });

  testWidgets('system entry has no avatar or timestamp semantics', (
    tester,
  ) async {
    await pump(tester, const ChatSystemEntry(text: 'bob 加入了群聊'));
    expect(find.text('bob 加入了群聊'), findsOneWidget);
    expect(find.byKey(ChatPage.groupTimeKey), findsNothing);
    expect(find.byType(UserIdentityAvatar), findsNothing);
  });

  testWidgets('notification controls stay left of a flat hinge', (
    tester,
  ) async {
    await pump(
      tester,
      const NotificationCenter(
        entries: [
          NotificationEntry(
            id: 'one',
            title: '通知内容',
            body:
                '很长的通知 '
                '需要换行',
            timeLabel: '今天',
          ),
        ],
      ),
      size: const Size(900, 768),
      features: const [
        DisplayFeature(
          bounds: Rect.fromLTWH(450, 0, 8, 768),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ],
    );
    expect(
      tester.getRect(find.byKey(NotificationCenter.entryKey('one'))).right,
      lessThanOrEqualTo(450),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop identity supports keyboard chat activation', (
    tester,
  ) async {
    int opens = 0;
    await pump(
      tester,
      UserIdentityRow(user: _bob, profile: profile, onOpenChat: () => opens++),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opens, 1);
  }, variant: TargetPlatformVariant(<TargetPlatform>{TargetPlatform.linux}));
}
