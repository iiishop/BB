import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/ui/home_navigation.dart';
import 'package:bb_client/ui/home_view.dart';
import 'package:bb_client/ui/notifications/notification_center.dart';
import 'package:bb_client/ui/space/space_local_store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_gateway.dart';
import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';
import 'support/fake_space_gateway.dart';
import 'support/space_fixtures.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

void main() {
  setUp(SpaceLocalStore.resetForTest);

  Future<void> pumpShell(
    WidgetTester tester, {
    required Size size,
    EdgeInsets padding = EdgeInsets.zero,
    bool disableAnimations = false,
    double textScale = 1.0,
  }) async {
    final HeartbeatController heartbeat = HeartbeatController(
      auth: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: AuthSession(),
      ),
    );
    addTearDown(heartbeat.dispose);

    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[
        ChatUser(
          account: '10000002',
          username: '林柚咲',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
      ],
    );
    final FakeSpaceGateway space = FakeSpaceGateway();
    final SpacePost post = spacePost(postId: 'post-1', text: '空间里的说说');
    space.posts['post-1'] = post;
    space.postPages[''] = spacePagePost(<SpacePost>[post]);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: padding,
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: HomeView(
          user: _self,
          profile: FakeProfileGateway(),
          auth: FakeAuthGateway(),
          heartbeat: heartbeat,
          chat: chat,
          space: space,
          notificationBuilder: (BuildContext _, bool _) =>
              const NotificationCenter(entries: <NotificationEntry>[]),
          onSignedOut: (_) {},
          onSessionExpired: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AnimatedContainer? findPillFill(WidgetTester tester, Key itemKey) {
    final Finder containers = find.descendant(
      of: find.byKey(itemKey),
      matching: find.byType(AnimatedContainer),
    );
    if (containers.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<AnimatedContainer>(containers.first);
  }

  Color? fillColorOf(AnimatedContainer? container) {
    final BoxDecoration? dec = container?.decoration as BoxDecoration?;
    return dec?.color;
  }

  bool hasFocusRing(WidgetTester tester, Key itemKey) {
    final Iterable<DecoratedBox> boxes = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byKey(itemKey),
        matching: find.byType(DecoratedBox),
      ),
    );
    return boxes.any((DecoratedBox box) {
      final Decoration dec = box.decoration;
      if (dec is! BoxDecoration) {
        return false;
      }
      final BoxBorder? border = dec.border;
      return border is Border &&
          border.top.color == AppColors.ink &&
          border.top.width == 3;
    });
  }

  testWidgets(
    'mobile edgebar matches v4 height, safe-area padding, shelf color, and entry order',
    (WidgetTester tester) async {
      await pumpShell(
        tester,
        size: const Size(390, 844),
        padding: const EdgeInsets.only(bottom: 34),
      );

      final Rect barRect = tester.getRect(find.byKey(HomeView.bottomNavKey));
      expect(barRect.height, closeTo(89, 0.5));
      expect(barRect.bottom, closeTo(844, 0.5));

      final DecoratedBox shelfBox = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(HomeView.bottomNavKey),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final BoxDecoration shelfDec = shelfBox.decoration as BoxDecoration;
      expect(shelfDec.color, AppColors.navShelf);
      expect((shelfDec.border! as Border).top.color, AppColors.navShelfBorder);

      final Rect chatRect = tester.getRect(find.byKey(HomeView.navChatKey));
      final Rect spaceRect = tester.getRect(find.byKey(HomeView.navSpaceKey));
      final Rect notifRect = tester.getRect(
        find.byKey(HomeView.navNotificationsKey),
      );
      expect(chatRect.right, lessThan(spaceRect.left));
      expect(spaceRect.right, lessThan(notifRect.left));

      await pumpShell(
        tester,
        size: const Size(390, 844),
        padding: EdgeInsets.zero,
      );
      expect(
        tester.getRect(find.byKey(HomeView.bottomNavKey)).height,
        closeTo(55, 0.5),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile bar fits 320px width and 200% text scale without overflow',
    (WidgetTester tester) async {
      await pumpShell(
        tester,
        size: const Size(320, 568),
        padding: const EdgeInsets.only(bottom: 34),
        textScale: 2.0,
      );

      expect(find.byKey(HomeView.bottomNavKey), findsOneWidget);
      expect(find.byKey(HomeView.navChatKey), findsOneWidget);
      expect(find.byKey(HomeView.navSpaceKey), findsOneWidget);
      expect(find.byKey(HomeView.navNotificationsKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile thumb slides over 200ms and respects disableAnimations', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      size: const Size(390, 844),
      padding: const EdgeInsets.only(bottom: 34),
      disableAnimations: false,
    );

    final Rect startThumb = tester.getRect(
      find.byKey(HomeBottomNavBar.thumbKey),
    );
    final Rect chatRect = tester.getRect(find.byKey(HomeView.navChatKey));
    expect(startThumb.left, closeTo(chatRect.left + 3, 1.0));
    expect(startThumb.height, closeTo(44, 0.5));

    await tester.tap(find.byKey(HomeView.navNotificationsKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final Rect midThumb = tester.getRect(find.byKey(HomeBottomNavBar.thumbKey));
    final Rect notifRect = tester.getRect(
      find.byKey(HomeView.navNotificationsKey),
    );
    expect(midThumb.left, greaterThan(startThumb.left + 10));
    expect(midThumb.left, lessThan(notifRect.left));

    await tester.pumpAndSettle();
    final Rect endThumb = tester.getRect(find.byKey(HomeBottomNavBar.thumbKey));
    expect(endThumb.left, closeTo(notifRect.left + 3, 1.0));

    // Now with reduced motion: thumb jumps immediately without intermediate slide.
    await pumpShell(
      tester,
      size: const Size(390, 844),
      padding: const EdgeInsets.only(bottom: 34),
      disableAnimations: true,
    );
    final Rect reducedStart = tester.getRect(
      find.byKey(HomeBottomNavBar.thumbKey),
    );
    await tester.tap(find.byKey(HomeView.navNotificationsKey));
    await tester.pump();
    final Rect reducedAfterPump = tester.getRect(
      find.byKey(HomeBottomNavBar.thumbKey),
    );
    final Rect reducedNotifRect = tester.getRect(
      find.byKey(HomeView.navNotificationsKey),
    );
    expect(reducedAfterPump.left, greaterThan(reducedStart.left + 50));
    expect(reducedAfterPump.left, closeTo(reducedNotifRect.left + 3, 1.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile hover, press, and keyboard focus + arrow navigation work',
    (WidgetTester tester) async {
      await pumpShell(
        tester,
        size: const Size(390, 844),
        padding: const EdgeInsets.only(bottom: 34),
      );

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      // Hovering selected tab keeps background transparent.
      await mouse.moveTo(tester.getCenter(find.byKey(HomeView.navChatKey)));
      await tester.pumpAndSettle();
      expect(
        fillColorOf(findPillFill(tester, HomeView.navChatKey)),
        Colors.transparent,
      );

      // Hovering unselected tab paints 0.035 ink tint.
      await mouse.moveTo(tester.getCenter(find.byKey(HomeView.navSpaceKey)));
      await tester.pumpAndSettle();
      expect(
        fillColorOf(findPillFill(tester, HomeView.navSpaceKey)),
        const Color(0x09161D1E),
      );

      // Pressing unselected tab paints 0.06 ink tint.
      final TestGesture touch = await tester.startGesture(
        tester.getCenter(find.byKey(HomeView.navNotificationsKey)),
      );
      await tester.pumpAndSettle();
      expect(
        fillColorOf(findPillFill(tester, HomeView.navNotificationsKey)),
        const Color(0x0F161D1E),
      );
      await touch.up();
      await tester.pumpAndSettle();

      // Now Notifications (index 2) is selected. Focus chat tab via traditional
      // highlight mode, then navigate with ArrowRight / Home / End.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });
      await tester.tap(find.byKey(HomeView.navChatKey));
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navChatKey), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navSpaceKey), isTrue);
      expect(find.text('空间里的说说'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navNotificationsKey), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navChatKey), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navNotificationsKey), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop rail matches v4 paper spine, sliding 160ms mark, hover/press, and keyboard',
    (WidgetTester tester) async {
      await pumpShell(
        tester,
        size: const Size(1280, 800),
        disableAnimations: false,
      );

      expect(find.byKey(HomeView.bottomNavKey), findsNothing);
      expect(find.byKey(HomeView.railAvatarKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HomeDesktopNavRail),
          matching: find.text('BB'),
        ),
        findsOneWidget,
      );

      final Rect chatRect = tester.getRect(find.byKey(HomeView.navChatKey));
      final Rect spaceRect = tester.getRect(find.byKey(HomeView.navSpaceKey));
      final Rect notifRect = tester.getRect(
        find.byKey(HomeView.navNotificationsKey),
      );
      expect(chatRect.height, closeTo(60, 0.5));
      expect(chatRect.bottom, lessThan(spaceRect.top));
      expect(spaceRect.bottom, lessThan(notifRect.top));

      // Ink spine mark straddles the 92px rail divider and aligns with item 0.
      final Rect mark0 = tester.getRect(find.byKey(HomeRailSpineMark.markKey));
      expect(mark0.width, closeTo(15, 0.5));
      expect(mark0.height, closeTo(3, 0.5));
      expect(mark0.left, closeTo(84, 0.5));
      expect(mark0.right, closeTo(99, 0.5));
      expect(mark0.center.dy, closeTo(chatRect.center.dy, 1.0));

      // Slides over 160ms when switching to Notifications.
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final Rect markMid = tester.getRect(
        find.byKey(HomeRailSpineMark.markKey),
      );
      expect(markMid.center.dy, greaterThan(mark0.center.dy + 20));
      expect(markMid.center.dy, lessThan(notifRect.center.dy));

      await tester.pumpAndSettle();
      final Rect mark2 = tester.getRect(find.byKey(HomeRailSpineMark.markKey));
      expect(mark2.center.dy, closeTo(notifRect.center.dy, 1.0));

      // Hover & press on unselected rail item.
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(HomeView.navSpaceKey)));
      await tester.pumpAndSettle();
      expect(
        fillColorOf(findPillFill(tester, HomeView.navSpaceKey)),
        const Color(0x0A161D1E),
      );

      // Reduced motion jumps immediately.
      await pumpShell(
        tester,
        size: const Size(1280, 800),
        disableAnimations: true,
      );
      final Rect reducedStart = tester.getRect(
        find.byKey(HomeRailSpineMark.markKey),
      );
      await tester.tap(find.byKey(HomeView.navNotificationsKey));
      await tester.pump();
      final Rect reducedEnd = tester.getRect(
        find.byKey(HomeRailSpineMark.markKey),
      );
      expect(reducedEnd.center.dy, greaterThan(reducedStart.center.dy + 80));

      // Vertical arrow keys move focus & selection on rail.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navChatKey), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navSpaceKey), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(hasFocusRing(tester, HomeView.navChatKey), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  FocusNode navFocusNode(WidgetTester tester, Key itemKey) {
    return tester
        .widget<FocusableActionDetector>(
          find
              .descendant(
                of: find.byKey(itemKey),
                matching: find.byType(FocusableActionDetector),
              )
              .first,
        )
        .focusNode!;
  }

  Future<void> sendShiftTab(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  for (final Size size in <Size>[const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'roving Tab/Shift+Tab enters/exits active nav item and arrows update traversal at ${size.width.toInt()}',
      (WidgetTester tester) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(() {
          FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic;
        });

        await pumpShell(tester, size: size);

        // Select Space (index 1); only Space participates in Tab traversal.
        await tester.tap(find.byKey(HomeView.navSpaceKey));
        await tester.pumpAndSettle();
        expect(navFocusNode(tester, HomeView.navSpaceKey).hasFocus, isTrue);
        expect(navFocusNode(tester, HomeView.navChatKey).skipTraversal, isTrue);
        expect(
          navFocusNode(tester, HomeView.navSpaceKey).skipTraversal,
          isFalse,
        );
        expect(
          navFocusNode(tester, HomeView.navNotificationsKey).skipTraversal,
          isTrue,
        );

        // Pressing Tab leaves navigation without landing on Notifications.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        for (final Key key in <Key>[
          HomeView.navChatKey,
          HomeView.navSpaceKey,
          HomeView.navNotificationsKey,
        ]) {
          expect(
            navFocusNode(tester, key).hasFocus,
            isFalse,
            reason: 'Tab should leave navigation from $key',
          );
        }

        // Shift+Tab returns directly to the active tab (Space).
        await sendShiftTab(tester);
        expect(navFocusNode(tester, HomeView.navSpaceKey).hasFocus, isTrue);
        expect(hasFocusRing(tester, HomeView.navSpaceKey), isTrue);

        // Arrow moves selection + focus to Notifications, and Tab leaves again.
        await tester.sendKeyEvent(
          size.width < 720
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowDown,
        );
        await tester.pumpAndSettle();
        expect(
          navFocusNode(tester, HomeView.navNotificationsKey).hasFocus,
          isTrue,
        );
        expect(
          navFocusNode(tester, HomeView.navNotificationsKey).skipTraversal,
          isFalse,
        );
        expect(
          navFocusNode(tester, HomeView.navSpaceKey).skipTraversal,
          isTrue,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        for (final Key key in <Key>[
          HomeView.navChatKey,
          HomeView.navSpaceKey,
          HomeView.navNotificationsKey,
        ]) {
          expect(navFocusNode(tester, key).hasFocus, isFalse);
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'all three nav icons switch cleanly between outline and solid at ${size.width.toInt()}',
      (WidgetTester tester) async {
        await pumpShell(tester, size: size);

        void expectIcons({required int selected}) {
          final Icon chatIcon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(HomeView.navChatKey),
              matching: find.byType(Icon),
            ),
          );
          final HomeSpaceNavIcon spaceIcon = tester.widget<HomeSpaceNavIcon>(
            find.descendant(
              of: find.byKey(HomeView.navSpaceKey),
              matching: find.byType(HomeSpaceNavIcon),
            ),
          );
          final Icon notifyIcon = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(HomeView.navNotificationsKey),
              matching: find.byType(Icon),
            ),
          );

          expect(
            chatIcon.icon,
            selected == 0
                ? Icons.chat_bubble_rounded
                : Icons.chat_bubble_outline_rounded,
          );
          expect(spaceIcon.selected, selected == 1);
          expect(
            notifyIcon.icon,
            selected == 2
                ? Icons.notifications_rounded
                : Icons.notifications_none_rounded,
          );
        }

        expectIcons(selected: 0);

        await tester.tap(find.byKey(HomeView.navSpaceKey));
        await tester.pumpAndSettle();
        expectIcons(selected: 1);

        await tester.tap(find.byKey(HomeView.navNotificationsKey));
        await tester.pumpAndSettle();
        expectIcons(selected: 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
