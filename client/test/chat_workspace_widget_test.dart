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
import 'package:bb_client/ui/login_page.dart';
import 'package:bb_client/ui/profile/profile_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';

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

  Widget app({
    List<DisplayFeature> features = const <DisplayFeature>[],
    bool withSpace = false,
    EdgeInsets padding = EdgeInsets.zero,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(displayFeatures: features, padding: padding),
        child: child!,
      ),
      home: HomeView(
        user: _self,
        profile: profile,
        auth: FakeAuthGateway(),
        heartbeat: heartbeat,
        chat: chat,
        space: withSpace ? FakeSpaceGateway() : null,
        onSignedOut: (LogoutResult? _) {},
        onSessionExpired: () {},
      ),
    );
  }

  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    List<DisplayFeature> features = const <DisplayFeature>[],
    bool withSpace = false,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(features: features, withSpace: withSpace, padding: padding),
    );
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
    // The chat starts on the crease itself; the grip floats above it.
    expect(dualLeft, closeTo(fold.bounds.center.dx, 0.5));

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

  testWidgets(
    'expanding a flat fold keeps the history anchor and draft visible',
    (WidgetTester tester) async {
      final List<String> bodies = <String>[
        for (int position = 1; position <= 30; position += 1)
          'message $position ${'read this conversation message ' * 12}',
      ];
      chat.conversations[bob.account] = <ChatMessage>[
        for (int index = 0; index < bodies.length; index += 1)
          _message(
            position: index + 1,
            sender: bob.account,
            target: _self.account,
            at: now,
            text: bodies[index],
          ),
      ];
      final DisplayFeature fold = DisplayFeature(
        bounds: const Rect.fromLTWH(492, 0, 0, 768),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureFlat,
      );
      await pumpAt(
        tester,
        const Size(1024, 768),
        features: <DisplayFeature>[fold],
      );

      final Finder list = find.byKey(ChatPage.listKey);
      final ScrollController controller = tester
          .widget<ListView>(list)
          .controller!;
      controller.jumpTo(controller.position.maxScrollExtent * 0.45);
      await tester.pumpAndSettle();

      final Rect viewport = tester.getRect(list);
      final List<String> visible = <String>[
        for (final String body in bodies)
          if (find.text(body).evaluate().isNotEmpty &&
              tester.getRect(find.text(body)).overlaps(viewport))
            body,
      ];
      expect(visible, isNotEmpty);
      final String anchor = visible.first;

      await tester.enterText(composerOf(bob.account), '半句草稿');
      tester.widget<TextField>(composerOf(bob.account)).controller!.selection =
          const TextSelection.collapsed(offset: 2);
      await tester.pump();
      await tester.tap(find.byKey(ChatWorkspace.toggleKey));
      await tester.pumpAndSettle();

      final Rect expanded = tester.getRect(find.byKey(ChatPage.listKey));
      expect(
        find.text(anchor),
        findsWidgets,
        reason: 'the same history message stays in the expanded tree',
      );
      expect(
        tester.getRect(find.text(anchor)).overlaps(expanded),
        isTrue,
        reason: 'the reading anchor must stay in view after expanding',
      );
      expect(
        tester.widget<TextField>(composerOf(bob.account)).controller!.text,
        '半句草稿',
      );
      expect(
        tester
            .widget<TextField>(composerOf(bob.account))
            .controller!
            .selection
            .baseOffset,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('signed-in fold divider accounts for rail and safe-area origin', (
    WidgetTester tester,
  ) async {
    final DisplayFeature fold = DisplayFeature(
      bounds: const Rect.fromLTWH(400, 0, 0, 840),
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      BbClientApp(
        authGateway: FakeAuthGateway()..loginResult = _self,
        profile: profile,
        heartbeat: heartbeat,
        chat: chat,
        space: FakeSpaceGateway(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(LoginPage.accountFieldKey),
        matching: find.byType(EditableText),
      ),
      _self.account,
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(LoginPage.passwordFieldKey),
        matching: find.byType(EditableText),
      ),
      'Synthetic42',
    );
    await tester.tap(find.byKey(LoginPage.submitButtonKey));
    await tester.pumpAndSettle();
    expect(find.byType(HomeView), findsOneWidget);
    expect(find.byType(ChatWorkspace), findsNothing);
    tester.view.physicalSize = const Size(800, 840);
    tester.view.displayFeatures = <DisplayFeature>[fold];
    tester.view.padding = const FakeViewPadding(
      left: 24,
      top: 20,
      right: 12,
      bottom: 16,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatWorkspace), findsOneWidget);
    final BuildContext workspace = tester.element(find.byType(ChatWorkspace));
    expect(MediaQuery.displayFeaturesOf(workspace).single.bounds.left, 284);
    expect(tester.getSize(find.byType(ChatWorkspace)).width, 672);
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(400, 0.5),
    );
    expect(
      tester.getRect(find.byKey(ChatWorkspace.toggleKey)).center.dx,
      closeTo(400, 0.5),
    );
    expect(
      tester.getRect(find.byKey(ChatWorkspace.listPaneKey)).right,
      closeTo(400, 0.5),
    );
    await tester.tap(find.byKey(HomeView.railAvatarKey));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
      ProfilePanelMode.folded,
    );
    await tester.tap(find.byKey(ProfilePanel.closeButtonKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChatWorkspace.toggleKey));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(24, 0.5),
    );
    await tester.tap(find.byKey(ChatWorkspace.toggleKey));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
      closeTo(400, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (
      width: 719.0,
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
      horizontal: false,
      split: false,
      mode: ProfilePanelMode.folded,
    ),
    (
      width: 720.0,
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
      horizontal: false,
      split: true,
      mode: ProfilePanelMode.folded,
    ),
    (
      width: 800.0,
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureHalfOpened,
      horizontal: false,
      split: true,
      mode: ProfilePanelMode.desktop,
    ),
    (
      width: 800.0,
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureFlat,
      horizontal: true,
      split: false,
      mode: ProfilePanelMode.folded,
    ),
    (
      width: 800.0,
      type: DisplayFeatureType.cutout,
      state: DisplayFeatureState.unknown,
      horizontal: false,
      split: false,
      mode: ProfilePanelMode.desktop,
    ),
    (
      width: 991.0,
      type: null,
      state: DisplayFeatureState.unknown,
      horizontal: false,
      split: false,
      mode: ProfilePanelMode.desktop,
    ),
    (
      width: 992.0,
      type: null,
      state: DisplayFeatureState.unknown,
      horizontal: false,
      split: true,
      mode: ProfilePanelMode.desktop,
    ),
  ]) {
    testWidgets(
      'home policy: ${scenario.width}/${scenario.type}/${scenario.state}/horizontal=${scenario.horizontal}',
      (WidgetTester tester) async {
        final List<DisplayFeature> features = scenario.type == null
            ? <DisplayFeature>[]
            : <DisplayFeature>[
                DisplayFeature(
                  bounds: scenario.horizontal
                      ? Rect.fromLTWH(0, 420, scenario.width, 0)
                      : Rect.fromLTWH(scenario.width / 2, 0, 0, 840),
                  type: scenario.type!,
                  state: scenario.state,
                ),
              ];
        await pumpAt(
          tester,
          Size(scenario.width, 840),
          features: features,
          withSpace: true,
        );
        expect(
          find.byType(ChatWorkspace),
          scenario.split ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(ChatWorkspace.toggleKey),
          scenario.split && scenario.type != null
              ? findsOneWidget
              : findsNothing,
        );
        final Finder entry = find.byKey(
          scenario.width < 720
              ? HomeView.avatarEntryKey
              : HomeView.railAvatarKey,
        );
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(
          tester.widget<ProfilePanel>(find.byType(ProfilePanel)).mode,
          scenario.mode,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets(
    'the signed-in shell expands the chat to physical screen left, over the '
    'navigation rail',
    (WidgetTester tester) async {
      // QA counterexample: mounting only the workspace hid the 92 px rail the
      // real signed-in shell reserves, so the expanded chat settled at x=92.
      const Rect hingeBounds = Rect.fromLTWH(492, 0, 40, 768);
      final DisplayFeature hinge = DisplayFeature(
        bounds: hingeBounds,
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      );
      await pumpAt(
        tester,
        const Size(1024, 768),
        features: <DisplayFeature>[hinge],
        withSpace: true,
      );

      // The rail is real in this shell and owns the left 92 px.
      expect(find.byKey(HomeView.navSpaceKey).hitTestable(), findsOneWidget);
      final Rect dualChat = tester.getRect(
        find.byKey(ChatWorkspace.chatPaneKey),
      );
      expect(
        dualChat.left,
        closeTo(hingeBounds.right, 0.5),
        reason: 'the chat pane starts on the hinge edge; the grip floats above',
      );

      // A reading scene to prove the transition keeps it.
      final Finder list = find.byKey(ChatPage.listKey);
      await tester.drag(list, const Offset(0, 340));
      await tester.pumpAndSettle();
      final double readingOffset = offsetOf(tester, bob.account);
      await tester.enterText(composerOf(bob.account), '全屏草稿');
      await tester.pump();

      await tester.tap(find.byKey(ChatWorkspace.toggleKey));
      await tester.pumpAndSettle();
      final Rect full = tester.getRect(find.byKey(ChatWorkspace.chatPaneKey));
      expect(full.left, closeTo(0, 0.5), reason: 'screen x = 0, not x = 92');
      expect(full.right, closeTo(1024, 0.5), reason: 'right edge stays fixed');
      // The rail is painted beneath the pages, so at full screen the chat
      // covers it instead of leaving a strip of it on screen.
      expect(find.byKey(HomeView.navSpaceKey).hitTestable(), findsNothing);
      expect(find.byKey(ChatWorkspace.toggleKey), findsOneWidget);
      expect(offsetOf(tester, bob.account), closeTo(readingOffset, 0.5));
      expect(
        tester.widget<TextField>(composerOf(bob.account)).controller!.text,
        '全屏草稿',
      );

      // Back to two panes: the rail returns and the same scene is restored.
      await tester.tap(find.byKey(ChatWorkspace.toggleKey));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
        closeTo(dualChat.left, 0.5),
      );
      expect(find.byKey(HomeView.navSpaceKey).hitTestable(), findsOneWidget);
      expect(offsetOf(tester, bob.account), closeTo(readingOffset, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a narrow unfolded shell still splits: the rail must not eat the 720 px '
    'breakpoint',
    (WidgetTester tester) async {
      // QA counterexample: an 800 px unfolded screen keeps 92 px for the rail,
      // so only 708 px reached the workspace and the right pane disappeared.
      const double foldX = 400;
      final DisplayFeature fold = DisplayFeature(
        bounds: const Rect.fromLTWH(foldX, 0, 0, 840),
        type: DisplayFeatureType.fold,
        state: DisplayFeatureState.postureFlat,
      );
      await pumpAt(
        tester,
        const Size(800, 840),
        features: <DisplayFeature>[fold],
        withSpace: true,
      );

      // The contacts pane stays the shared list, and the right pane exists.
      expect(find.byType(UsersListView), findsOneWidget);
      expect(find.byKey(UsersListView.rowKey(bob.account)), findsOneWidget);
      final Finder chatPane = find.byKey(ChatWorkspace.chatPaneKey);
      expect(
        chatPane,
        findsOneWidget,
        reason: 'unfolded defaults to two panes',
      );
      final Rect dualChat = tester.getRect(chatPane);
      expect(
        dualChat.left,
        closeTo(foldX, 0.5),
        reason: 'the right pane starts on the crease; the band floats above',
      );

      final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
      expect(toggle, findsOneWidget);
      final Rect foldGrip = tester.getRect(toggle);
      expect(
        foldGrip.left,
        lessThan(foldX),
        reason: 'the grip straddles a zero-width crease',
      );
      expect(foldGrip.right, greaterThan(foldX));

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final Rect full = tester.getRect(chatPane);
      expect(full.left, closeTo(0, 0.5));
      expect(full.right, closeTo(800, 0.5));
      expect(find.byKey(HomeView.navSpaceKey).hitTestable(), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(chatPane).left,
        closeTo(dualChat.left, 0.5),
        reason: 'collapsing restores the same two panes',
      );
      expect(find.byKey(HomeView.navSpaceKey).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the fold grip fits the 20 lp divider band and points the right way',
    (WidgetTester tester) async {
      // Owner cap: handle + padding + horizontal hit area at most 20 lp, while
      // keeping a 56 lp tall target. Zero-width fold first.
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

      expect(ChatWorkspace.foldGap, lessThanOrEqualTo(20));
      final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
      final Finder listPane = find.byKey(ChatWorkspace.listPaneKey);
      final Finder chatPane = find.byKey(ChatWorkspace.chatPaneKey);
      final Rect grip = tester.getRect(toggle);
      final Rect list = tester.getRect(listPane);
      final Rect chat = tester.getRect(chatPane);

      expect(grip.width, lessThanOrEqualTo(ChatWorkspace.foldGap));
      expect(grip.height, closeTo(ChatWorkspace.foldHandleHeight, 0.1));
      expect(ChatWorkspace.foldHandleHeight, closeTo(56, 0.1));
      // The panes meet on the crease: neither gives up width to the grip,
      // which floats above both of them.
      expect(list.right, closeTo(512, 0.5));
      expect(chat.left, closeTo(512, 0.5));
      expect(chat.left - list.right, 0);
      // The 20 lp band is centred on the crease, 10 lp over each pane; the
      // 16 lp pill sits inside it.
      expect(grip.width, lessThanOrEqualTo(ChatWorkspace.foldGap));
      expect(grip.left, closeTo(512 - ChatWorkspace.foldHandleWidth / 2, 0.5));
      expect(grip.right, closeTo(512 + ChatWorkspace.foldHandleWidth / 2, 0.5));
      // Split: the arrow points at the direction the pane will grow.
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: toggle, matching: find.byType(Icon)),
            )
            .icon,
        Icons.keyboard_double_arrow_left_rounded,
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final Rect fullGrip = tester.getRect(toggle);
      final Rect fullChat = tester.getRect(chatPane);
      expect(fullChat.left, closeTo(0, 0.5));
      expect(fullChat.right, closeTo(1024, 0.5));
      // Full screen: the grip hugs the left edge (the 16 lp pill sits inside
      // the 20 lp band) and points back.
      expect(fullGrip.left, lessThanOrEqualTo(2));
      expect(fullGrip.left + fullGrip.width, lessThanOrEqualTo(20));
      expect(fullGrip.width, lessThanOrEqualTo(ChatWorkspace.foldGap));
      expect(fullGrip.height, closeTo(ChatWorkspace.foldHandleHeight, 0.1));
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: toggle, matching: find.byType(Icon)),
            )
            .icon,
        Icons.keyboard_double_arrow_right_rounded,
      );

      // It stays reachable and returns to the same two panes.
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getRect(chatPane).left, closeTo(chat.left, 0.5));
      expect(tester.getRect(toggle).left, closeTo(grip.left, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the grip keeps clear of a real hinge and of both panes', (
    WidgetTester tester,
  ) async {
    const Rect hingeBounds = Rect.fromLTWH(492, 0, 40, 768);
    final DisplayFeature hinge = DisplayFeature(
      bounds: hingeBounds,
      type: DisplayFeatureType.hinge,
      state: DisplayFeatureState.postureFlat,
    );
    await pumpAt(
      tester,
      const Size(1024, 768),
      features: <DisplayFeature>[hinge],
    );

    final Rect list = tester.getRect(find.byKey(ChatWorkspace.listPaneKey));
    final Rect chat = tester.getRect(find.byKey(ChatWorkspace.chatPaneKey));
    final Rect grip = tester.getRect(find.byKey(ChatWorkspace.toggleKey));
    // The list stops at the hinge, the chat starts past the hinge, and the
    // grip sits on the touchable side instead of inside the non-touchable
    // hinge.
    expect(list.right, closeTo(hingeBounds.left, 0.5));
    expect(chat.left, closeTo(hingeBounds.right, 0.5));
    // The grip floats above the chat's left edge; the only thing it must never
    // touch is the non-touchable hinge itself.
    expect(grip.left, greaterThanOrEqualTo(hingeBounds.right));
    expect(grip.overlaps(hingeBounds), isFalse);
    expect(grip.right, greaterThan(chat.left));

    // Rows on the left stay clickable at the grip's own height…
    await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(UsersListView.selectedKey(carol.account)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(UsersListView.rowKey(bob.account)));
    await tester.pumpAndSettle();
    expect(find.byKey(UsersListView.selectedKey(bob.account)), findsOneWidget);

    // …and the transcript next to the band still scrolls vertically.
    final Finder list2 = find.byKey(ChatPage.listKey);
    final ScrollController controller = tester
        .widget<ListView>(list2)
        .controller!;
    final double before = controller.offset;
    await tester.dragFrom(
      Offset(chat.left + 24, grip.center.dy),
      const Offset(0, 240),
    );
    await tester.pumpAndSettle();
    expect(
      controller.offset,
      lessThan(before - 40),
      reason: 'a vertical drag beside the grip scrolls into history',
    );
    expect(tester.takeException(), isNull);
  });

  // Flutter reports the physical, non-touchable strip as DisplayFeatureType
  // .hinge whatever its logical size. A 4 lp hinge is as untouchable as a
  // 40 lp one; judging by width alone put the grip (and the arrow) on the
  // hinge at 4 and 7 lp.
  for (final double hingeWidth in <double>[4, 7, 8, 40]) {
    testWidgets('a $hingeWidth lp hinge keeps the grip and its hit band on the '
        'touchable side', (WidgetTester tester) async {
      const double mid = 512;
      final Rect hingeBounds = Rect.fromLTWH(
        mid - hingeWidth / 2,
        0,
        hingeWidth,
        768,
      );
      final DisplayFeature hinge = DisplayFeature(
        bounds: hingeBounds,
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.postureFlat,
      );
      await pumpAt(
        tester,
        const Size(1024, 768),
        features: <DisplayFeature>[hinge],
      );

      final Finder toggle = find.byKey(ChatWorkspace.toggleKey);
      final Rect list = tester.getRect(find.byKey(ChatWorkspace.listPaneKey));
      final Rect grip = tester.getRect(toggle);
      final Rect chat = tester.getRect(find.byKey(ChatWorkspace.chatPaneKey));
      expect(
        list.right,
        closeTo(hingeBounds.left, 0.5),
        reason: 'the list stops before the hinge',
      );
      expect(
        grip.overlaps(hingeBounds),
        isFalse,
        reason: 'no part of the grip may sit on the non-touchable hinge',
      );
      expect(grip.left, greaterThanOrEqualTo(hingeBounds.right));
      // Nothing is reserved: the chat starts on the hinge edge and the grip
      // floats above its left edge.
      expect(chat.left, closeTo(hingeBounds.right, 0.5));
      expect(chat.left - list.right - hingeWidth, 0);
      expect(grip.right, greaterThan(chat.left));

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
        closeTo(0, 0.5),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(ChatWorkspace.chatPaneKey)).left,
        closeTo(chat.left, 0.5),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    "the split list keeps main's conversation note and the split selection in "
    'sync',
    (WidgetTester tester) async {
      // Integration contract after merging DEA-494 into this branch: the
      // conversation note (main) and the split pane selection (this branch)
      // are one fact, keyed by account, in the two-pane left column.
      await pumpAt(tester, const Size(1280, 900));

      expect(
        find.byKey(UsersListView.noteKey(bob.account)),
        findsOneWidget,
        reason: 'the auto-selected conversation sits in the note',
      );
      expect(
        find.byKey(UsersListView.selectedKey(bob.account)),
        findsOneWidget,
      );
      expect(find.byKey(UsersListView.noteKey(carol.account)), findsNothing);

      await tester.tap(find.byKey(UsersListView.rowKey(carol.account)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(UsersListView.noteKey(carol.account)),
        findsOneWidget,
        reason: 'the note follows the conversation shown on the right',
      );
      expect(
        find.byKey(UsersListView.selectedKey(carol.account)),
        findsOneWidget,
      );
      expect(find.byKey(UsersListView.noteKey(bob.account)), findsNothing);
      expect(find.byKey(UsersListView.selectedKey(bob.account)), findsNothing);
      // The right pane really switched; the note is the list's half of that.
      expect(
        find.byKey(
          ValueKey<String>('chat-workspace-page-${carol.account}'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
