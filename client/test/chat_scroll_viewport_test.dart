// Regression for DEA-478: on desktop the chat transcript used to be a
// centred 860px-wide scroll view, so the scrollbar sat in the middle of the
// pane and the wheel over either side gutter did nothing. The transcript must
// scroll as a full-width viewport while its reading column stays centred and
// capped, and one wheel notch must move it exactly once.

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v-bob',
  presence: Presence.online,
);

/// Wide-screen reading column cap carried over from the old scroll viewport
/// (860px) minus its 2x16px horizontal padding.
const double _readingColumnCap = 828;

ChatMessage _message(int position) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: position.isEven ? _self.account : _bob.account,
    targetAccount: position.isEven ? _bob.account : _self.account,
    createdAt: DateTime.utc(2026, 1, 1, 12).add(Duration(minutes: position)),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart('第 $position 条消息，用来撑满聊天记录的滚动视口。')],
  );
}

void main() {
  Future<void> pumpChat(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[
          for (int position = 1; position <= 60; position += 1)
            _message(position),
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme().copyWith(platform: TargetPlatform.windows),
        home: ChatPage(peer: _bob, chat: chat, profile: FakeProfileGateway()),
      ),
    );
    await tester.pumpAndSettle();
  }

  ScrollPosition chatScroll(WidgetTester tester) {
    final ListView list = tester.widget<ListView>(find.byKey(ChatPage.listKey));
    final ScrollController? controller = list.controller;
    expect(controller, isNotNull);
    expect(controller!.hasClients, isTrue);
    return controller.position;
  }

  Future<void> wheelAt(WidgetTester tester, Offset at, double dy) async {
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pumpAndSettle();
  }

  testWidgets('wide desktop: scroll viewport and scrollbar span the chat pane', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester, const Size(1280, 900));

    final double paneWidth = tester.getSize(find.byType(Scaffold)).width;
    expect(paneWidth, 1280);

    final Rect listRect = tester.getRect(find.byKey(ChatPage.listKey));
    expect(
      listRect.width,
      moreOrLessEquals(paneWidth, epsilon: 0.5),
      reason: 'the transcript scroll viewport must cover the chat pane',
    );
    expect(
      listRect.right,
      moreOrLessEquals(paneWidth, epsilon: 0.5),
      reason: 'scrollbar paints on the right edge of the scroll viewport',
    );

    // The desktop scrollbar is inserted by ScrollBehavior around the
    // scrollable's viewport, so its width is the viewport width: the transcript
    // scrollbar must be as wide as the pane, not the reading column.
    final Finder scrollbars = find.descendant(
      of: find.byKey(ChatPage.listKey),
      matching: find.byType(Scrollbar),
    );
    expect(scrollbars, findsWidgets);
    final List<double> scrollbarWidths = <double>[
      for (int i = 0; i < scrollbars.evaluate().length; i += 1)
        tester.getSize(scrollbars.at(i)).width,
    ];
    expect(
      scrollbarWidths,
      contains(moreOrLessEquals(paneWidth, epsilon: 0.5)),
      reason: 'the transcript scrollbar spans the chat pane',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one wheel notch scrolls the same list from content and gutters',
    (WidgetTester tester) async {
      await pumpChat(tester, const Size(1280, 900));
      final ScrollPosition position = chatScroll(tester);
      final double bottom = position.pixels;
      expect(
        bottom,
        greaterThan(0),
        reason: 'opening a chat follows the bottom',
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey<String>('chat-row-m60@60')))
            .width,
        lessThanOrEqualTo(_readingColumnCap + 0.5),
        reason: 'the reading column must keep its capped width',
      );

      // The centred reading column ends around x=1054 at 1280px; these points
      // stood outside the old 860px-wide viewport on both sides.
      final Rect column = tester.getRect(
        find.byKey(const ValueKey<String>('chat-row-m60@60')),
      );
      expect(
        column.center.dx,
        moreOrLessEquals(640, epsilon: 0.5),
        reason: 'the reading column stays centred in the pane',
      );

      await wheelAt(tester, Offset(column.right + 30, 400), -120);
      expect(
        position.pixels,
        moreOrLessEquals(bottom - 120, epsilon: 0.5),
        reason: 'one wheel notch must scroll once, not twice',
      );

      await wheelAt(tester, Offset(column.left - 30, 400), -120);
      expect(
        position.pixels,
        moreOrLessEquals(bottom - 240, epsilon: 0.5),
        reason: 'the left gutter must scroll the same transcript',
      );

      await wheelAt(tester, const Offset(640, 400), -120);
      expect(
        position.pixels,
        moreOrLessEquals(bottom - 360, epsilon: 0.5),
        reason: 'the content itself keeps scrolling',
      );

      final double beforeComposerWheel = position.pixels;
      await wheelAt(tester, tester.getCenter(find.byType(ChatComposer)), -120);
      expect(
        position.pixels,
        moreOrLessEquals(beforeComposerWheel, epsilon: 0.5),
        reason: 'the composer must not be captured into the transcript scroll',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow windows keep the scrollbar edge and a centred column', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester, const Size(1280, 900));

    for (final Size size in <Size>[
      const Size(900, 700),
      const Size(390, 844),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();

      final double paneWidth = tester.getSize(find.byType(Scaffold)).width;
      expect(paneWidth, size.width);
      final Rect listRect = tester.getRect(find.byKey(ChatPage.listKey));
      expect(
        listRect.width,
        moreOrLessEquals(paneWidth, epsilon: 0.5),
        reason: 'scrollbar stays on the pane edge at ${size.width}px',
      );

      // Resizing changes the extent; follow the bottom again so the last row
      // is laid out and can be measured.
      final ScrollPosition position = chatScroll(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();

      final Rect column = tester.getRect(
        find.byKey(const ValueKey<String>('chat-row-m60@60')),
      );
      expect(
        column.width,
        lessThanOrEqualTo(_readingColumnCap + 0.5),
        reason: 'reading column never exceeds its cap at ${size.width}px',
      );
      expect(column.center.dx, moreOrLessEquals(paneWidth / 2, epsilon: 0.5));
      expect(
        column.left,
        greaterThanOrEqualTo(15.5),
        reason: 'normal horizontal margin is preserved',
      );
      expect(tester.takeException(), isNull);
    }
  });
}
