import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:bb_client/ui/chat/message_bubble.dart';
import 'package:bb_client/ui/chat/pending_send.dart';
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

ChatMessage _message(
  int position, {
  String sender = '10000002',
  String text = '消息',
  DateTime? at,
  ChatMessageKind kind = ChatMessageKind.body,
  Attachment? attachment,
}) {
  return ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: sender == _self.account ? '10000002' : _self.account,
    createdAt:
        at ?? DateTime.utc(2026, 1, 1, 12).add(Duration(minutes: position)),
    kind: kind,
    parts: kind == ChatMessageKind.body
        ? <MessagePart>[TextPart(text)]
        : const <MessagePart>[],
    attachment: attachment,
  );
}

class _FakeClipboard implements ClipboardMediaReader {
  _FakeClipboard(this.media);

  final PickedMedia? media;

  @override
  Future<PickedMedia?> read() async => media;
}

class _Harness {
  _Harness({
    List<ChatMessage>? thread,
    FakeChatService? service,
    this.textScale = 1,
    this.reducedMotion = false,
    this.clipboard = const PlatformClipboardMediaReader(),
    this.coverExtractor = defaultVideoCoverExtractor,
  }) : chat =
           service ??
           FakeChatService(
             self: _self,
             users: const <ChatUser>[_bob],
             conversations: <String, List<ChatMessage>>{
               _bob.account: thread ?? <ChatMessage>[],
             },
           ),
       profile = FakeProfileGateway();

  final FakeChatService chat;
  final FakeProfileGateway profile;
  final double textScale;
  final bool reducedMotion;
  final ClipboardMediaReader clipboard;
  final VideoCoverExtractorFn coverExtractor;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reducedMotion,
          ),
          child: ChatPage(
            peer: _bob,
            chat: chat,
            profile: profile,
            clipboard: clipboard,
            coverExtractor: coverExtractor,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(ChatComposer.inputKey), text);
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pump();
  }
}

void main() {
  testWidgets('a send shows one local bubble before the server commits, then '
      'the same identity settles without a duplicate or re-entry', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(thread: <ChatMessage>[_message(1)]);
    harness.chat.sendGate = Completer<void>();
    await harness.pump(tester);

    await harness.send(tester, '马上到');
    await tester.pump();

    expect(find.text('马上到'), findsOneWidget, reason: 'local echo is immediate');
    expect(find.byKey(MessageBubble.sendingKey), findsOneWidget);
    final MessageBubble sendingBubble = tester.widget<MessageBubble>(
      find.byType(MessageBubble).last,
    );
    expect(sendingBubble.sendState, SendFeedbackState.sending);
    expect(
      tester.widget<MessageEntrance>(find.byType(MessageEntrance).last).animate,
      isTrue,
      reason: 'a new local bubble enters once',
    );

    harness.chat.sendGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(MessageBubble.sendingKey), findsNothing);
    expect(find.text('马上到'), findsOneWidget);
    expect(
      find.byType(MessageBubble),
      findsNWidgets(2),
      reason: 'the pending bubble was replaced, not duplicated',
    );
    expect(
      find.descendant(
        of: find.byType(MessageEntrance).last,
        matching: find.byKey(MessageEntrance.animationKey),
      ),
      findsOneWidget,
      reason: 'the sent bubble kept its one entrance animation',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed send keeps the bubble and retries the same operation '
      'id without a second send', (WidgetTester tester) async {
    final _Harness harness = _Harness(thread: <ChatMessage>[_message(1)]);
    harness.chat.failBody = true;
    await harness.pump(tester);

    await harness.send(tester, '发不出去');
    await tester.pumpAndSettle();

    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(find.text('未发送 · 点按重试'), findsOneWidget);
    expect(find.text('发不出去'), findsOneWidget);
    expect(harness.chat.sendCalls, 1);

    harness.chat.failBody = false;
    await tester.tap(find.byKey(MessageBubble.failedKey));
    await tester.pumpAndSettle();

    expect(find.byKey(MessageBubble.failedKey), findsNothing);
    expect(find.text('发不出去'), findsOneWidget);
    expect(
      harness.chat.sendCalls,
      1,
      reason: 'retry reuses the operation instead of composing a second send',
    );
    expect(harness.chat.bodyOperationIds, <String>[
      '${harness.chat.sendSeeds.single}-b',
    ], reason: 'retry keeps the exact stable operation id');
    expect(tester.takeException(), isNull);
  });

  testWidgets('entrance plays only for messages that were not on screen', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(thread: <ChatMessage>[_message(1)]);
    await harness.pump(tester);

    expect(
      tester
          .widgetList<MessageEntrance>(find.byType(MessageEntrance))
          .where((MessageEntrance entrance) => entrance.animate),
      isEmpty,
      reason: 'history load must not animate',
    );

    harness.chat.conversations[_bob.account]!.add(_message(2, text: '刚到的新消息'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump();

    final Iterable<MessageEntrance> animating = tester
        .widgetList<MessageEntrance>(find.byType(MessageEntrance))
        .where((MessageEntrance entrance) => entrance.animate);
    expect(animating, hasLength(1));
    expect(
      tester.widget<MessageEntrance>(find.byType(MessageEntrance).last).animate,
      isTrue,
    );

    // Refresh rebuilds from history: nothing may replay as new.
    await tester.tap(find.byKey(ChatPage.refreshKey));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<MessageEntrance>(find.byType(MessageEntrance))
          .where((MessageEntrance entrance) => entrance.animate),
      isEmpty,
      reason: 'refresh and history rebuilds are not new messages',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('system reduce-motion keeps the new message without entrance', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(
      thread: <ChatMessage>[_message(1)],
      reducedMotion: true,
    );
    await harness.pump(tester);
    harness.chat.conversations[_bob.account]!.add(_message(2, text: '减少动画'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump();

    expect(find.text('减少动画'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MessageEntrance),
        matching: find.byKey(MessageEntrance.animationKey),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('incoming messages do not pull a history reader down, a send '
      'still reveals its own bubble', (WidgetTester tester) async {
    final List<ChatMessage> thread = <ChatMessage>[
      for (int position = 1; position <= 40; position += 1)
        _message(position, text: '历史 $position'),
    ];
    final _Harness harness = _Harness(thread: thread);
    await harness.pump(tester);

    final ScrollController controller = tester
        .widget<ListView>(find.byKey(ChatPage.listKey))
        .controller!;
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 700));
    await tester.pumpAndSettle();
    final double parked = controller.offset;
    expect(
      controller.position.maxScrollExtent - parked,
      greaterThan(96),
      reason: 'the reader is parked in history',
    );

    harness.chat.conversations[_bob.account]!.add(_message(41, text: '不该拉到底部'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump();
    expect(controller.offset, parked, reason: 'incoming message must not yank');

    await tester.enterText(find.byKey(ChatComposer.inputKey), '我自己发一条');
    await tester.pump();
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(
      controller.position.maxScrollExtent - controller.offset,
      lessThan(1),
      reason: 'an explicit send reveals the local bubble',
    );
    expect(find.text('我自己发一条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two sends in flight stay independent and both commit once', (
    WidgetTester tester,
  ) async {
    final _Harness harness = _Harness(thread: <ChatMessage>[_message(1)]);
    harness.chat.sendGate = Completer<void>();
    await harness.pump(tester);

    await harness.send(tester, '第一条');
    await tester.pump();
    await harness.send(tester, '第二条');
    await tester.pump();

    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.byKey(MessageBubble.sendingKey), findsNWidgets(2));

    harness.chat.sendGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(MessageBubble.sendingKey), findsNothing);
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(harness.chat.sendCalls, 2);
    expect(harness.chat.sendSeeds.toSet(), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a polled acceptance reconciles with the local echo before the '
      'response returns', (WidgetTester tester) async {
    final FakeChatService service = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[_message(1)],
      },
    );
    service.responseGate = Completer<void>();
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'accepted before response');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('accepted before response'), findsOneWidget);
    expect(
      find.byType(MessageBubble),
      findsNWidgets(2),
      reason:
          'the accepted message is one server fact, not pending + committed',
    );
    expect(
      find.byKey(MessageBubble.sendingKey),
      findsOneWidget,
      reason: 'the committed row carries the in-flight state',
    );

    service.responseGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('accepted before response'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(2));
    expect(find.byKey(MessageBubble.sendingKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a refresh while the response is delayed does not duplicate the '
      'accepted message', (WidgetTester tester) async {
    final FakeChatService service = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[_message(1)],
      },
    );
    service.responseGate = Completer<void>();
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'refresh safe');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ChatPage.refreshKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('refresh safe'), findsOneWidget);

    service.responseGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('refresh safe'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial success shows the committed body plus the one still '
      'pending attachment', (WidgetTester tester) async {
    final FakeChatService service = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[_message(1)],
      },
    );
    service.attachmentGate = Completer<void>();
    final _Harness harness = _Harness(
      service: service,
      clipboard: _FakeClipboard(
        PickedMedia(
          bytes: Uint8List.fromList(List<int>.filled(32, 0)),
          filename: 'clip.mp4',
          mimeType: 'video/mp4',
        ),
      ),
      coverExtractor:
          ({
            String? path,
            required Uint8List bytes,
            required String filename,
          }) async => ResolvedMedia(
            bytes: base64Decode(_tinyPng),
            filename: 'cover.png',
            mimeType: 'image/png',
          ),
    );
    await harness.pump(tester);

    await tester.enterText(find.byKey(ChatComposer.inputKey), '混排正文');
    await tester.tap(find.byKey(ChatComposer.pasteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('混排正文'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(
      find.byType(MessageBubble),
      findsNWidgets(3),
      reason: 'history + committed body + pending attachment',
    );
    expect(
      find.byKey(MessageBubble.sendingKey),
      findsNWidgets(2),
      reason:
          'the accepted body and the still-pending attachment both await '
          'the same composed response',
    );

    service.attachmentGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('混排正文'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(
      find.byType(MessageBubble),
      findsNWidgets(3),
      reason: 'both items committed once, pending rows replaced',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delayed failure does not pull a history reader to the end', (
    WidgetTester tester,
  ) async {
    final List<ChatMessage> thread = <ChatMessage>[
      for (int position = 1; position <= 40; position += 1)
        _message(position, text: '历史 $position'),
    ];
    final _Harness harness = _Harness(thread: thread);
    harness.chat.sendGate = Completer<void>();
    harness.chat.failBody = true;
    await harness.pump(tester);

    await harness.send(tester, 'delayed failure');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final ScrollController controller = tester
        .widget<ListView>(find.byKey(ChatPage.listKey))
        .controller!;
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 900));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    final double parked = controller.offset;
    expect(controller.position.maxScrollExtent - parked, greaterThan(96));

    harness.chat.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(
      controller.offset,
      closeTo(parked, 1),
      reason: 'an async failure is not a new explicit send',
    );
    // Inspect the failed row at the bottom without using a user gesture that
    // would itself be allowed to move the list.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delayed success does not yank a reader who scrolled away', (
    WidgetTester tester,
  ) async {
    final List<ChatMessage> thread = <ChatMessage>[
      for (int position = 1; position <= 40; position += 1)
        _message(position, text: '历史 $position'),
    ];
    final _Harness harness = _Harness(thread: thread);
    harness.chat.sendGate = Completer<void>();
    await harness.pump(tester);

    await harness.send(tester, 'delayed success');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.drag(find.byKey(ChatPage.listKey), const Offset(0, 900));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    final ScrollController controller = tester
        .widget<ListView>(find.byKey(ChatPage.listKey))
        .controller!;
    final double parked = controller.offset;
    expect(controller.position.maxScrollExtent - parked, greaterThan(96));

    harness.chat.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(parked, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending to committed preserves the entrance element when a day '
      'separator is inserted', (WidgetTester tester) async {
    final _Harness harness = _Harness(
      thread: <ChatMessage>[
        _message(
          1,
          at: DateTime.now().toUtc().subtract(const Duration(days: 1)),
        ),
      ],
    );
    harness.chat.sendGate = Completer<void>();
    await harness.pump(tester);

    await harness.send(tester, 'stable element');
    await tester.pump(const Duration(milliseconds: 300));
    final State<StatefulWidget> before = tester.state(
      find.byType(MessageEntrance).last,
    );

    harness.chat.sendGate!.complete();
    await tester.pump();
    final State<StatefulWidget> after = tester.state(
      find.byType(MessageEntrance).last,
    );
    await tester.pumpAndSettle();

    expect(
      identical(before, after),
      isTrue,
      reason: 'the same operation must keep the actual entrance State',
    );
    expect(find.text('昨天'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone/desktop and large text keep long bubbles without overflow',
    (WidgetTester tester) async {
      final String longText = '很长的一条消息 ' * 40;
      final List<ChatMessage> thread = <ChatMessage>[
        _message(1, text: longText),
        _message(2, sender: _self.account, text: '好的，收到。'),
      ];
      final _Harness harness = _Harness(thread: thread, textScale: 1.6);
      await harness.pump(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);

      await harness.pump(tester, size: const Size(1440, 900));
      expect(tester.takeException(), isNull);
    },
  );
}

const String _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=';
