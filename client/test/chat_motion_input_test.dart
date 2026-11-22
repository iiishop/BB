import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:bb_client/ui/chat/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '/avatars/10000002.png',
  avatarVersion: 'v1',
  presence: Presence.online,
);

ChatMessage _text(int position, {required String sender, String? text}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: sender == _self.account ? _bob.account : _self.account,
    createdAt: DateTime.now().toUtc().subtract(
      Duration(minutes: 60 - position),
    ),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text ?? '消息 $position')],
  );
}

void main() {
  late FakeChatService chat;

  setUp(() {
    chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[
          for (int position = 1; position <= 18; position += 1)
            _text(
              position,
              sender: position.isEven ? _self.account : _bob.account,
            ),
        ],
      },
    );
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.view.resetViewInsets());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: ChatPage(peer: _bob, chat: chat, profile: FakeProfileGateway()),
      ),
    );
    await tester.pumpAndSettle();
  }

  double listOffset(WidgetTester tester) {
    return tester
        .widget<ListView>(find.byKey(ChatPage.listKey))
        .controller!
        .offset;
  }

  testWidgets(
    'keyboard raises the transcript together with the input, header fixed',
    (WidgetTester tester) async {
      await pumpChat(tester);
      final Rect header = tester.getRect(find.byType(AppBar));
      final Rect composer = tester.getRect(find.byType(ChatComposer));
      final Rect list = tester.getRect(find.byKey(ChatPage.listKey));
      final Rect lastBubble = tester.getRect(find.byType(MessageBubble).last);
      expect(composer.bottom, closeTo(844, 0.1));
      expect(list.bottom, closeTo(composer.top, 0.1));

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      final Rect keyboardHeader = tester.getRect(find.byType(AppBar));
      final Rect keyboardComposer = tester.getRect(find.byType(ChatComposer));
      final Rect keyboardList = tester.getRect(find.byKey(ChatPage.listKey));
      final Rect keyboardLast = tester.getRect(find.byType(MessageBubble).last);
      expect(keyboardHeader.top, closeTo(header.top, 0.1));
      expect(keyboardHeader.bottom, closeTo(header.bottom, 0.1));
      // The whole column rises: the input sits on the keyboard and the
      // transcript's bottom edge stays exactly on top of it.
      expect(keyboardComposer.bottom, closeTo(844 - 300, 0.1));
      expect(keyboardList.bottom, closeTo(keyboardComposer.top, 0.1));
      expect(
        keyboardLast.bottom,
        closeTo(lastBubble.bottom - 300, 0.5),
        reason: 'the newest message is lifted with the input, not left behind',
      );
      // No second jump once the transition has settled.
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getRect(find.byType(ChatComposer)).bottom,
        closeTo(keyboardComposer.bottom, 0.1),
      );

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.getRect(find.byType(ChatComposer)).bottom,
        closeTo(composer.bottom, 0.1),
      );
      expect(tester.getRect(find.byType(AppBar)).top, closeTo(header.top, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening the keyboard in history keeps the reading position', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 360));
    await tester.pumpAndSettle();
    final double offset = listOffset(tester);
    expect(offset, greaterThan(0));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(listOffset(tester), closeTo(offset, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('new messages in history show a counted pill instead of moving '
      'the list, and the pill returns to the latest', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 420));
    await tester.pumpAndSettle();
    final double reading = listOffset(tester);
    expect(reading, greaterThan(0));
    expect(
      reading,
      lessThan(
        tester
            .widget<ListView>(find.byKey(ChatPage.listKey))
            .controller!
            .position
            .maxScrollExtent,
      ),
    );

    chat.conversations[_bob.account]!.add(
      _text(19, sender: _bob.account, text: '刚来的新消息'),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.byKey(ChatPage.newMessagesKey), findsOneWidget);
    expect(find.text('1 条新消息'), findsOneWidget);
    expect(listOffset(tester), closeTo(reading, 0.5));

    await tester.tap(find.byKey(ChatPage.newMessagesKey));
    await tester.pumpAndSettle();
    final ListView list = tester.widget<ListView>(find.byKey(ChatPage.listKey));
    expect(
      list.controller!.offset,
      closeTo(list.controller!.position.maxScrollExtent, 1),
    );
    expect(find.byKey(ChatPage.newMessagesKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new message while the keyboard is open in history does not '
      'pin the list back to the end', (WidgetTester tester) async {
    await pumpChat(tester);
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 420));
    await tester.pumpAndSettle();
    final double reading = listOffset(tester);
    expect(reading, greaterThan(0));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(listOffset(tester), closeTo(reading, 0.5));

    chat.conversations[_bob.account]!.add(
      _text(19, sender: _bob.account, text: '键盘打开时到达'),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(listOffset(tester), closeTo(reading, 0.5));
    expect(find.byKey(ChatPage.newMessagesKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the first bubble of a same-sender run shows the avatar', (
    WidgetTester tester,
  ) async {
    final DateTime base = DateTime.now().toUtc();
    chat.conversations[_bob.account] = <ChatMessage>[
      ChatMessage(
        id: 'm1',
        position: 1,
        senderAccount: _bob.account,
        targetAccount: _self.account,
        createdAt: base.subtract(const Duration(minutes: 5)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('bob 第一条')],
      ),
      ChatMessage(
        id: 'm2',
        position: 2,
        senderAccount: _bob.account,
        targetAccount: _self.account,
        createdAt: base.subtract(const Duration(minutes: 4)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('bob 第二条')],
      ),
      ChatMessage(
        id: 'm3',
        position: 3,
        senderAccount: _self.account,
        targetAccount: _bob.account,
        createdAt: base.subtract(const Duration(minutes: 3)),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('alice 回复')],
      ),
    ];
    await pumpChat(tester);
    final List<MessageBubble> bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(bubbles.length, 3);
    expect(bubbles[0].showAvatar, isTrue, reason: 'run head shows the avatar');
    expect(bubbles[1].showAvatar, isFalse, reason: 'same sender stays grouped');
    expect(
      bubbles[2].showAvatar,
      isTrue,
      reason: 'a different sender is a new group',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('new-message entrance is the 160ms starting point', (
    WidgetTester tester,
  ) async {
    const MessageEntrance entrance = MessageEntrance(
      animate: true,
      child: SizedBox(),
    );
    expect(entrance.duration, const Duration(milliseconds: 160));
  });

  testWidgets('typing plain text does not grow the composer', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);
    final double before = tester.getRect(find.byType(ChatComposer)).height;
    await tester.enterText(find.byKey(ChatComposer.inputKey), '半句草稿');
    await tester.pump();
    expect(
      tester.getRect(find.byType(ChatComposer)).height,
      closeTo(before, 0.1),
      reason: 'the staged strip is for parts/attachments, not the text field',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('send button is emphasised only when something is sendable', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);
    FilledButton button = tester.widget<FilledButton>(
      find.byKey(ChatComposer.sendKey),
    );
    expect(
      button.style!.backgroundColor!.resolve(<WidgetState>{}),
      AppColors.border,
    );
    await tester.enterText(find.byKey(ChatComposer.inputKey), '可发送');
    await tester.pump();
    button = tester.widget<FilledButton>(find.byKey(ChatComposer.sendKey));
    expect(
      button.style!.backgroundColor!.resolve(<WidgetState>{}),
      AppColors.accentDeep,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'video tile is picture-first, actions live in the message menu, and the '
    'viewer keeps the original reading position',
    (WidgetTester tester) async {
      chat.conversations[_bob.account] = <ChatMessage>[
        for (int position = 1; position <= 12; position += 1)
          _text(position, sender: _bob.account),
        ChatMessage(
          id: 'video',
          position: 13,
          senderAccount: _bob.account,
          targetAccount: _self.account,
          createdAt: DateTime.now().toUtc(),
          kind: ChatMessageKind.attachment,
          attachment: const Attachment(
            mediaId: 'video1',
            kind: AttachmentKind.video,
            filename: 'clip.mp4',
            mimeType: 'video/mp4',
            byteSize: 4096,
            coverMediaId: 'cover1',
          ),
        ),
      ];
      await pumpChat(tester);
      final Finder tile = find.byKey(
        const ValueKey<String>('chat-media-video1'),
      );
      expect(tile, findsOneWidget);
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.text('下载'), findsNothing);
      expect(find.text('播放'), findsNothing);
      expect(find.text('另存为'), findsNothing);
      expect(find.byType(VideoPlayer), findsNothing, reason: 'no autoplay');

      await tester.longPress(tile);
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('另存为'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      final double reading = listOffset(tester);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsOneWidget);
      // The viewer is the existing one, opened on the tapped video page.
      expect(find.byKey(MediaViewer.keys.pages), findsOneWidget);

      await tester.tap(find.byKey(MediaViewer.closeKey));
      await tester.pumpAndSettle();
      expect(listOffset(tester), closeTo(reading, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('image tap expands from the tile and returns to its message', (
    WidgetTester tester,
  ) async {
    chat.conversations[_bob.account] = <ChatMessage>[
      ChatMessage(
        id: 'img',
        position: 1,
        senderAccount: _bob.account,
        targetAccount: _self.account,
        createdAt: DateTime.now().toUtc(),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('看图'), ImagePart('img-1')],
      ),
    ];
    await pumpChat(tester);
    await tester.tap(find.byKey(const ValueKey<String>('chat-media-img-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // The origin frame is on screen while the viewer is still fading in.
    expect(find.byKey(ChatPage.mediaTransitionKey), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewer), findsOneWidget);
    await tester.tap(find.byKey(MediaViewer.closeKey));
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewer), findsNothing);
    expect(find.text('看图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
