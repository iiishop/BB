import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/chat_workspace.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

ChatMessage _message({
  required int position,
  required String sender,
  required String target,
  required DateTime at,
  String? text,
}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: target,
    createdAt: at,
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text ?? 'message $position')],
  );
}

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;
  late HeartbeatController heartbeat;

  final DateTime now = DateTime.now().toUtc();

  final ChatUser bob = ChatUser(
    account: '10000002',
    username: 'bob',
    avatarUrl: '/avatars/10000002.png',
    avatarVersion: 'v1',
    presence: Presence.online,
    lastContactAt: now.subtract(const Duration(minutes: 5)),
    lastMessage: const UserPreview(
      id: 'm30',
      senderAccount: '10000001',
      senderUsername: 'alice',
      previewBody: 'message 30',
    ),
  );
  final ChatUser carol = ChatUser(
    account: '10000003',
    username: 'carol',
    avatarUrl: '/avatars/10000003.png',
    avatarVersion: 'v1',
    presence: Presence.offline,
  );

  setUp(() {
    final List<ChatMessage> longThread = <ChatMessage>[
      for (int position = 1; position <= 30; position += 1)
        _message(
          position: position,
          sender: position.isEven ? _self.account : bob.account,
          target: position.isEven ? bob.account : _self.account,
          at: now.subtract(Duration(minutes: 40 - position)),
        ),
    ];
    chat = FakeChatService(
      self: _self,
      users: <ChatUser>[bob, carol],
      conversations: <String, List<ChatMessage>>{
        bob.account: longThread,
        carol.account: <ChatMessage>[
          _message(
            position: 1,
            sender: carol.account,
            target: _self.account,
            at: now.subtract(const Duration(minutes: 2)),
            text: 'carol 的历史消息',
          ),
        ],
      },
    );
    profile = FakeProfileGateway();
    heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);
  });

  Widget app({List<DisplayFeature> features = const <DisplayFeature>[]}) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(displayFeatures: features),
        child: child!,
      ),
      home: HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        onSignedOut: (LogoutResult? _) {},
        onSessionExpired: () {},
      ),
    );
  }

  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    List<DisplayFeature> features = const <DisplayFeature>[],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(features: features));
    await tester.pumpAndSettle();
  }

  // IndexedStack keeps unselected conversations mounted but offstage; the
  // per-account state must still be readable to prove what was preserved.
  Finder composerOf(String account) => find.descendant(
    of: find.byKey(
      ValueKey<String>('chat-workspace-page-$account'),
      skipOffstage: false,
    ),
    matching: find.byKey(ChatComposer.inputKey, skipOffstage: false),
    skipOffstage: false,
  );

  Finder listOf(String account) => find.descendant(
    of: find.byKey(
      ValueKey<String>('chat-workspace-page-$account'),
      skipOffstage: false,
    ),
    matching: find.byKey(ChatPage.listKey, skipOffstage: false),
    skipOffstage: false,
  );

  double offsetOf(WidgetTester tester, String account) {
    return tester.widget<ListView>(listOf(account)).controller!.offset;
  }

  testWidgets('wide layout keeps the same list and chat widgets side by side', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(1280, 900));

    // One implementation, two panes: the split surface reuses the same list
    // and the same chat page the phone route pushes, not a lookalike.
    expect(find.byType(ChatWorkspace), findsOneWidget);
    expect(find.byType(UsersListView), findsOneWidget);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(bob.account)), findsOneWidget);
    expect(find.byKey(UsersListView.rowKey(carol.account)), findsOneWidget);

    // The first directory read selects a conversation; selection is by
    // account and is visible in the list.
    expect(find.byKey(UsersListView.selectedKey(bob.account)), findsOneWidget);
    expect(find.byKey(UsersListView.selectedKey(carol.account)), findsNothing);

    // Tapping another row switches only the right pane; the list stays put.
    await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(UsersListView.selectedKey(carol.account)),
      findsOneWidget,
    );
    expect(find.byKey(UsersListView.selectedKey(bob.account)), findsNothing);
    expect(
      tester
          .widget<ChatPage>(
            find.byKey(
              ValueKey<String>('chat-workspace-page-${carol.account}'),
            ),
          )
          .peer
          .account,
      carol.account,
    );
    expect(find.byKey(UsersListView.listKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'switching conversations restores scroll, draft text and caret per account',
    (WidgetTester tester) async {
      await pumpAt(tester, const Size(1280, 900));
      expect(
        find.byKey(ValueKey<String>('chat-workspace-page-${bob.account}')),
        findsOneWidget,
      );

      // Park in history (away from the end) and put the caret inside a draft.
      await tester.drag(
        find.byKey(ChatPage.listKey).first,
        const Offset(0, 360),
      );
      await tester.pumpAndSettle();
      final double bobOffset = offsetOf(tester, bob.account);
      expect(bobOffset, greaterThan(0));

      await tester.enterText(composerOf(bob.account), '半句给 bob 的草稿');
      final TextEditingController bobController = tester
          .widget<TextField>(composerOf(bob.account))
          .controller!;
      bobController.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      // Write a different draft in Carol.
      await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
      await tester.pumpAndSettle();
      await tester.enterText(composerOf(carol.account), 'carol 的草稿');

      // A new message reaches Bob while Carol is on screen. Coming back must
      // not jump his reading position to the end.
      chat.conversations[bob.account]!.add(
        _message(
          position: 31,
          sender: bob.account,
          target: _self.account,
          at: DateTime.now().toUtc(),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // Back to Bob: same conversation, same reading position, same caret,
      // and Carol's draft never leaks into his composer.
      await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
      await tester.pumpAndSettle();
      expect(offsetOf(tester, bob.account), closeTo(bobOffset, 0.5));
      expect(
        tester.widget<TextField>(composerOf(bob.account)).controller!.text,
        '半句给 bob 的草稿',
      );
      expect(
        tester
            .widget<TextField>(composerOf(bob.account))
            .controller!
            .selection
            .baseOffset,
        2,
      );
      expect(
        tester.widget<TextField>(composerOf(carol.account)).controller!.text,
        'carol 的草稿',
      );
      expect(
        find.byKey(UsersListView.selectedKey(bob.account)),
        findsOneWidget,
      );
      expect(
        find.byKey(UsersListView.selectedKey(carol.account)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'foldable dual pane, jelly expansion and restore keep the same scene',
    (WidgetTester tester) async {
      final DisplayFeature hinge = DisplayFeature(
        bounds: const Rect.fromLTWH(492, 0, 40, 768),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      );
      await pumpAt(
        tester,
        const Size(1024, 768),
        features: <DisplayFeature>[hinge],
      );

      expect(find.byKey(ChatWorkspace.listPaneKey), findsOneWidget);
      final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
      expect(toggle, findsOneWidget);
      final Rect dualChat = tester.getRect(
        find.byKey(ChatWorkspace.chatPaneKey),
      );
      expect(dualChat.left, greaterThanOrEqualTo(hinge.bounds.right));
      // The switch never intersects the non-touchable hinge.
      expect(tester.getRect(toggle).overlaps(hinge.bounds), isFalse);

      // Build a scene: history position + partial draft with a mid-text caret.
      await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 340));
      await tester.pumpAndSettle();
      final double readingOffset = offsetOf(tester, bob.account);
      await tester.enterText(composerOf(bob.account), '折叠屏草稿');
      tester.widget<TextField>(composerOf(bob.account)).controller!.selection =
          const TextSelection.collapsed(offset: 3);
      await tester.pump();

      // Expand: the left edge starts at the pane boundary, travels left and
      // briefly overshoots past the screen edge before settling at zero.
      await tester.tap(toggle);
      double minLeft = dualChat.left;
      for (int frame = 0; frame < 26; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        minLeft = math.min(
          minLeft,
          tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
        );
      }
      await tester.pumpAndSettle();
      expect(minLeft, lessThan(0), reason: 'jelly overshoot at the left edge');
      expect(
        tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
        closeTo(0, 0.1),
      );
      expect(toggle, findsOneWidget, reason: 'the switch stays operable');
      expect(
        tester.getRect(toggle).overlaps(hinge.bounds),
        isFalse,
        reason: 'the full-screen switch still avoids the hinge',
      );
      expect(offsetOf(tester, bob.account), closeTo(readingOffset, 0.5));
      expect(
        tester.widget<TextField>(composerOf(bob.account)).controller!.text,
        '折叠屏草稿',
      );

      // Restore the two panes; the account, reading position and caret survive.
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
        closeTo(dualChat.left, 0.1),
      );
      expect(offsetOf(tester, bob.account), closeTo(readingOffset, 0.5));
      expect(
        tester
            .widget<TextField>(composerOf(bob.account))
            .controller!
            .selection
            .baseOffset,
        3,
      );
      expect(
        find.byKey(UsersListView.selectedKey(bob.account)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a flat zero-width fold still exposes the split switch', (
    WidgetTester tester,
  ) async {
    final DisplayFeature fold = DisplayFeature(
      bounds: const Rect.fromLTWH(512, 0, 0, 768),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
    );
    await pumpAt(
      tester,
      const Size(1024, 768),
      features: <DisplayFeature>[fold],
    );

    // QA counterexample: this used to render the panes without any toggle
    // because only a hinge was recognised.
    final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
    expect(toggle, findsOneWidget);
    final double dualLeft = tester
        .getRect(find.byKey(ChatWorkspace.chatPaneKey))
        .left;
    expect(dualLeft, greaterThan(fold.bounds.right));

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(0, 0.1),
    );
    expect(toggle, findsOneWidget);
    // The conversation content is still there in the full-screen state.
    expect(find.text('message 30'), findsWidgets);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(dualLeft, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout still uses the pushed conversation route', (
    WidgetTester tester,
  ) async {
    await pumpAt(tester, const Size(390, 844));
    expect(find.byType(ChatWorkspace), findsNothing);
    expect(find.byType(ChatPage), findsNothing);

    await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsNothing);
    expect(find.byKey(UsersListView.listKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
