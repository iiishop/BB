import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/message_bubble.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

ChatMessage _text(
  int position, {
  required String sender,
  required String text,
  DateTime? at,
}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: sender == _self.account ? '10000002' : _self.account,
    createdAt: at ?? DateTime.now().toUtc(),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text)],
  );
}

void main() {
  late FakeChatService chat;
  late FakeProfileGateway profile;

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[
        ChatUser(
          account: '10000002',
          username: 'bob',
          avatarUrl: '/avatars/10000002.png',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
      ],
      conversations: <String, List<ChatMessage>>{
        '10000002': <ChatMessage>[
          _text(1, sender: '10000002', text: '刚从海边回来。'),
          _text(2, sender: '10000002', text: '给你看今天的月亮。'),
          _text(3, sender: _self.account, text: '这个蓝色好漂亮。'),
        ],
      },
    );
    profile = FakeProfileGateway();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: ChatPage(
          peer: const ChatUser(
            account: '10000002',
            username: 'bob',
            avatarUrl: '/avatars/10000002.png',
            avatarVersion: 'v1',
            presence: Presence.online,
          ),
          chat: chat,
          profile: profile,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Color? fillOf(WidgetTester tester, String text) {
    final Finder container = find
        .ancestor(of: find.text(text), matching: find.byType(Container))
        .first;
    final BoxDecoration decoration =
        tester.widget<Container>(container).decoration! as BoxDecoration;
    return decoration.color;
  }

  testWidgets('the peer bubble separates from the transcript paper', (
    WidgetTester tester,
  ) async {
    // Owner feedback: the first beige was too close to the warm paper.
    expect(
      (AppColors.chatPaper.computeLuminance() -
              AppColors.bubblePeer.computeLuminance())
          .abs(),
      greaterThan(0.06),
    );
    await pumpChat(tester);
    expect(fillOf(tester, '刚从海边回来。'), AppColors.bubblePeer);
    expect(AppColors.bubblePeer, isNot(AppColors.chatPaper));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short bubbles hug their text and the group head carries a tail',
    (WidgetTester tester) async {
      await pumpChat(tester);

      final double shortWidth = tester.getSize(find.text('刚从海边回来。')).width;
      final double otherWidth = tester.getSize(find.text('给你看今天的月亮。')).width;
      expect(shortWidth, lessThan(otherWidth));
      // Both render on the beige peer surface with dark regular text, and only
      // the group head has the little tail.
      expect(fillOf(tester, '刚从海边回来。'), AppColors.bubblePeer);
      expect(fillOf(tester, '给你看今天的月亮。'), AppColors.bubblePeer);
      expect(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .style
            ?.fontWeight,
        FontWeight.w400,
      );
      // Two runs => two tails: the peer's group head and the own reply's head.
      // The second peer message in the same run adds none.
      expect(find.byKey(MessageBubble.tailKey), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('own replies sit right without an avatar slot', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    expect(fillOf(tester, '这个蓝色好漂亮。'), AppColors.bubbleMine);
    final Rect mine = tester.getRect(
      find
          .ancestor(of: find.text('这个蓝色好漂亮。'), matching: find.byType(Container))
          .first,
    );
    final Rect peer = tester.getRect(
      find
          .ancestor(of: find.text('刚从海边回来。'), matching: find.byType(Container))
          .first,
    );
    expect(mine.right, greaterThan(peer.right + 100));
    // The peer's own avatar column stays on the left; nothing mirrors it on
    // the right, so the own bubble can reach the transcript's right edge.
    expect(mine.right, greaterThan(390 - 30));
    // Two tails: one at each run head (peer group + own group).
    expect(find.byKey(MessageBubble.tailKey), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one centred timestamp per group, never per bubble', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    // Two runs (peer + own) => two centred group labels.
    expect(find.byKey(ChatPage.groupTimeKey), findsNWidgets(2));
    final Rect first = tester.getRect(find.byKey(ChatPage.groupTimeKey).first);
    final Rect list = tester.getRect(find.byKey(ChatPage.listKey));
    expect(first.center.dx, closeTo(list.center.dx, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a picture-only message is a standalone rounded photo', (
    WidgetTester tester,
  ) async {
    final Uint8List photo = File('test/fixtures/media/horizon.png')
        .readAsBytesSync();
    chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[
        ChatUser(
          account: '10000002',
          username: 'bob',
          avatarUrl: '/avatars/10000002.png',
          avatarVersion: 'v1',
          presence: Presence.online,
        ),
      ],
      conversations: <String, List<ChatMessage>>{
        '10000002': <ChatMessage>[
          _text(1, sender: '10000002', text: '给你看今天的月亮。'),
          ChatMessage(
            id: 'photo',
            position: 2,
            senderAccount: '10000002',
            targetAccount: _self.account,
            createdAt: DateTime.now().toUtc(),
            kind: ChatMessageKind.body,
            parts: const <MessagePart>[ImagePart('photo-1')],
          ),
        ],
      },
      png: photo,
    );
    await pumpChat(tester);

    final Finder tile = find.byKey(
      const ValueKey<String>('chat-media-photo-1'),
    );
    expect(tile, findsOneWidget);
    final Size size = tester.getSize(tile);
    // Original 3:2 photo, about two thirds of the message area (390 - 2*16).
    expect(size.width / size.height, closeTo(1.5, 0.02));
    expect(size.width, closeTo((390 - 32) * 0.66, 6));
    // No bubble fill around it: the nearest bubble-shaped Container is absent,
    // and the picture is its own rounded block in the transcript.
    expect(
      find.ancestor(of: tile, matching: find.byType(IntrinsicWidth)).evaluate(),
      isEmpty,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewer), findsOneWidget);
    await tester.tap(find.byKey(MediaViewer.closeKey));
    await tester.pumpAndSettle();
    expect(tile, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the composer is a round plus, a pill and a round send arrow', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    expect(find.byKey(ChatComposer.attachMenuKey), findsOneWidget);
    expect(find.byKey(ChatComposer.imageKey), findsNothing);
    expect(find.byKey(ChatComposer.fileKey), findsNothing);
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(ChatComposer.sendKey),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      Icons.arrow_forward_rounded,
    );

    await tester.tap(find.byKey(ChatComposer.attachMenuKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ChatComposer.imageKey), findsOneWidget);
    expect(find.byKey(ChatComposer.fileKey), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Empty: quiet surface. Draft: deep teal, same round shape.
    Color sendColor() => tester
        .widget<Material>(
          find.descendant(
            of: find.byKey(ChatComposer.sendKey),
            matching: find.byType(Material),
          ),
        )
        .color!;
    expect(sendColor(), AppColors.surface);
    await tester.enterText(find.byKey(ChatComposer.inputKey), '好啊，等一个晴天。');
    await tester.pump();
    expect(sendColor(), AppColors.accentDeep);

    // The pill is exactly as tall as the round buttons and centred with them.
    final Rect pill = tester.getRect(
      find
          .ancestor(
            of: find.byKey(ChatComposer.inputKey),
            matching: find.byType(Container),
          )
          .first,
    );
    final Rect send = tester.getRect(find.byKey(ChatComposer.sendKey));
    final Rect plus = tester.getRect(find.byKey(ChatComposer.attachMenuKey));
    expect(pill.height, closeTo(send.height, 0.5));
    expect(pill.height, closeTo(44, 0.5));
    expect(pill.center.dy, closeTo(send.center.dy, 0.5));
    expect(pill.center.dy, closeTo(plus.center.dy, 0.5));
    // The "+" is a soft teal chip, not a nearly invisible outline.
    expect(
      tester
          .widget<Material>(
            find.descendant(
              of: find.byKey(ChatComposer.attachMenuKey),
              matching: find.byType(Material),
            ),
          )
          .color,
      AppColors.accentSoft,
    );
    expect(tester.takeException(), isNull);
  });
}
