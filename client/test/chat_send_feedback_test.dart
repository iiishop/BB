import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/clipboard_paste.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:bb_client/ui/chat/message_bubble.dart';
import 'package:bb_client/ui/chat/pending_send.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/chat_keyboard.dart';
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
  Future<ClipboardPaste> read() async {
    final PickedMedia? single = media;
    return ClipboardPaste(
      files: single == null ? const <PickedMedia>[] : <PickedMedia>[single],
    );
  }
}

class _CommitThenFailService extends FakeChatService {
  _CommitThenFailService({this.lookupGate, this.failLookup = false})
    : super(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[_message(1)],
        },
      );

  final Completer<void>? lookupGate;
  bool failLookup;
  ComposedSendResult? committed;
  bool retryReturnsCommitted = false;

  @override
  Future<ComposedSendResult> sendComposed({
    required String targetAccount,
    required List<OutgoingPart> body,
    required List<OutgoingAttachment> attachments,
    String? operationSeed,
  }) async {
    committed = await super.sendComposed(
      targetAccount: targetAccount,
      body: body,
      attachments: attachments,
      operationSeed: operationSeed,
    );
    throw const AuthFailure(
      status: 502,
      code: 'gateway_failed',
      message: 'response lost',
    );
  }

  @override
  Future<OperationResult?> getOperation(String operationId) async {
    operationQueries.add(operationId);
    final Completer<void>? gate = lookupGate;
    if (gate != null) {
      await gate.future;
    }
    if (failLookup) {
      throw const AuthFailure(
        status: 502,
        code: 'gateway_failed',
        message: 'lookup unavailable',
      );
    }
    final ChatMessage? message = committed?.body?.message;
    if (message == null) {
      return null;
    }
    return OperationResult(
      operationId: operationId,
      kind: 'message',
      status: OperationStatus.succeeded,
      message: message,
    );
  }

  @override
  Future<SendOutcome> sendBody({
    required String targetAccount,
    required List<OutgoingPart> content,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final ChatMessage? message = committed?.body?.message;
    if (retryReturnsCommitted && message != null) {
      return SendOutcome(
        operationId: operationId ?? 'retry',
        message: message,
        part: content,
      );
    }
    return super.sendBody(
      targetAccount: targetAccount,
      content: content,
      operationId: operationId,
      expectedIdentity: expectedIdentity,
    );
  }
}

class _HistoryScopeService extends FakeChatService {
  _HistoryScopeService()
    : super(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[_message(1, text: 'BOB PRIVATE')],
          '10000003': <ChatMessage>[],
        },
      );

  Completer<void>? historyGate;
  bool reject = false;

  @override
  Future<MessagePage> loadConversation({
    required String peerAccount,
    int afterPosition = 0,
    int limit = 50,
  }) async {
    final MessagePage snapshot = await super.loadConversation(
      peerAccount: peerAccount,
      afterPosition: afterPosition,
      limit: limit,
    );
    final Completer<void>? pending = historyGate;
    if (peerAccount == _bob.account && pending != null) {
      await pending.future;
      if (reject) {
        throw const AuthFailure(
          status: 502,
          code: 'gateway_failed',
          message: 'OLD BOB LOAD ERROR',
        );
      }
    }
    return snapshot;
  }
}

class _UnresolvedLookupService extends FakeChatService {
  _UnresolvedLookupService(this.answer)
    : super(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[_message(1)],
        },
      ) {
    failBody = true;
  }

  final String answer;

  @override
  Future<OperationResult?> getOperation(String operationId) async {
    operationQueries.add(operationId);
    switch (answer) {
      case 'error':
        throw const AuthFailure(
          status: 502,
          code: 'gateway_failed',
          message: 'lookup unavailable',
        );
      case 'absent':
        return null;
      default:
        return OperationResult(
          operationId: operationId,
          kind: 'message',
          status: OperationStatus.values.byName(answer),
        );
    }
  }
}

class _TwoLookupService extends FakeChatService {
  _TwoLookupService()
    : super(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[_message(1)],
        },
      );

  final Completer<void> firstLookup = Completer<void>();
  final Completer<void> secondLookup = Completer<void>();

  @override
  Future<ComposedSendResult> sendComposed({
    required String targetAccount,
    required List<OutgoingPart> body,
    required List<OutgoingAttachment> attachments,
    String? operationSeed,
  }) async {
    throw const AuthFailure(
      status: 502,
      code: 'gateway_failed',
      message: 'response lost',
    );
  }

  @override
  Future<SendOutcome> sendBody({
    required String targetAccount,
    required List<OutgoingPart> content,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) async {
    throw const AuthFailure(
      status: 502,
      code: 'gateway_failed',
      message: 'retry failed again',
    );
  }

  @override
  Future<OperationResult?> getOperation(String operationId) async {
    operationQueries.add(operationId);
    final bool first = operationQueries.length == 1;
    await (first ? firstLookup : secondLookup).future;
    if (first) {
      throw const AuthFailure(
        status: 502,
        code: 'gateway_failed',
        message: 'old lookup error',
      );
    }
    return OperationResult(
      operationId: operationId,
      kind: 'message',
      status: OperationStatus.succeeded,
      message: ChatMessage(
        id: 'second-lookup-message',
        position: 2,
        senderAccount: _self.account,
        targetAccount: _bob.account,
        createdAt: DateTime.now().toUtc(),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[TextPart('retry again')],
        operationId: operationId,
      ),
    );
  }
}

class _PendingThenCommittedService extends FakeChatService {
  _PendingThenCommittedService({this.pendingStatus = OperationStatus.pending})
    : super(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[_message(1)],
        },
      );

  final OperationStatus pendingStatus;
  String? seed;
  List<OutgoingPart>? body;
  ChatMessage? accepted;

  @override
  Future<ComposedSendResult> sendComposed({
    required String targetAccount,
    required List<OutgoingPart> body,
    required List<OutgoingAttachment> attachments,
    String? operationSeed,
  }) async {
    seed = operationSeed;
    this.body = body;
    throw const AuthFailure(
      status: 502,
      code: 'gateway_failed',
      message: 'request still processing',
    );
  }

  Future<void> acceptLater() async {
    final ComposedSendResult result = await super.sendComposed(
      targetAccount: _bob.account,
      body: body!,
      attachments: const <OutgoingAttachment>[],
      operationSeed: seed,
    );
    accepted = result.body!.message;
  }

  @override
  Future<OperationResult?> getOperation(String operationId) async {
    operationQueries.add(operationId);
    return OperationResult(
      operationId: operationId,
      kind: 'message',
      status: accepted == null ? pendingStatus : OperationStatus.succeeded,
      message: accepted,
    );
  }
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
    ChatUser peer = _bob,
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
            peer: peer,
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
      findsNothing,
      reason: 'the association proves the message is committed',
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
    await pasteFromClipboard(tester);
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
      findsOneWidget,
      reason: 'the accepted body is committed; only the attachment is pending',
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

  for (final bool refresh in <bool>[false, true]) {
    testWidgets(
      'another operation with identical text cannot hide a local failure '
      '(${refresh ? 'refresh' : 'poll'})',
      (WidgetTester tester) async {
        final _Harness harness = _Harness(thread: <ChatMessage>[_message(1)]);
        harness.chat.sendGate = Completer<void>();
        harness.chat.failBody = true;
        await harness.pump(tester);

        await harness.send(tester, 'same text');
        // Another client/session successfully sent the same text. The local
        // request has not been accepted and will fail.
        harness.chat.conversations[_bob.account]!.add(
          _message(
            2,
            sender: _self.account,
            text: 'same text',
            at: DateTime.now().toUtc(),
          ),
        );
        if (refresh) {
          await tester.tap(find.byKey(ChatPage.refreshKey));
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 3));
        }
        await tester.pump();

        harness.chat.sendGate!.complete();
        await tester.pumpAndSettle();

        final List<MessageBubble> bubbles = tester
            .widgetList<MessageBubble>(find.byType(MessageBubble))
            .toList();
        expect(
          bubbles.where(
            (MessageBubble bubble) =>
                bubble.sendState == SendFeedbackState.failed,
          ),
          hasLength(1),
          reason: 'another operation cannot erase the local failure',
        );
        expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
        expect(
          harness.chat.operationQueries,
          hasLength(1),
          reason: 'the failed operation is verified by its own id',
        );

        harness.chat.failBody = false;
        await tester.tap(find.byKey(MessageBubble.failedKey));
        await tester.pumpAndSettle();
        expect(find.byKey(MessageBubble.failedKey), findsNothing);
        expect(
          harness.chat.conversations[_bob.account]!.length,
          3,
          reason: 'other message + retried local message both exist',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('another operation with identical image cannot hide a local '
      'failure', (WidgetTester tester) async {
    final _Harness harness = _Harness(
      service: FakeChatService(
        self: _self,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[_message(1)],
        },
      ),
      clipboard: _FakeClipboard(
        PickedMedia(
          bytes: base64Decode(_tinyPng),
          filename: 'same.png',
          mimeType: 'image/png',
        ),
      ),
    );
    harness.chat.sendGate = Completer<void>();
    harness.chat.failBody = true;
    await harness.pump(tester);

    await pasteFromClipboard(tester);
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pump();
    harness.chat.conversations[_bob.account]!.add(
      ChatMessage(
        id: 'other-image',
        position: 2,
        senderAccount: _self.account,
        targetAccount: _bob.account,
        createdAt: DateTime.now().toUtc(),
        kind: ChatMessageKind.body,
        parts: const <MessagePart>[ImagePart('other-media-id')],
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    harness.chat.sendGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(
      tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .where(
            (MessageBubble bubble) =>
                bubble.sendState == SendFeedbackState.failed,
          ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('two sends may return out of order without duplicates or lost '
      'operations', (WidgetTester tester) async {
    final FakeChatService service = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[_message(1)],
      },
    )..holdResponses = true;
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'first in flight');
    await tester.pump();
    final String firstSeed = service.sendSeeds.single;
    await harness.send(tester, 'second in flight');
    await tester.pump();
    final String secondSeed = service.sendSeeds.last;
    expect(secondSeed, isNot(firstSeed));

    // The later request settles first.
    service.responseGateFor(secondSeed).complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    service.responseGateFor(firstSeed).complete();
    await tester.pumpAndSettle();

    expect(find.text('first in flight'), findsOneWidget);
    expect(find.text('second in flight'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(3));
    expect(find.byKey(MessageBubble.sendingKey), findsNothing);
    expect(find.byKey(MessageBubble.failedKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed response is reconciled by the operation record, not '
      'by message content', (WidgetTester tester) async {
    final FakeChatService service = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[_message(1)],
      },
    );
    final ChatMessage committed = _message(
      2,
      sender: _self.account,
      text: 'server committed',
      at: DateTime.now().toUtc(),
    );
    service.operationResult = OperationResult(
      operationId: 'seed-b',
      kind: 'message',
      status: OperationStatus.succeeded,
      message: committed,
    );
    service.sendGate = Completer<void>();
    service.failBody = true;
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'local failure');
    await tester.pump();
    service.sendGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(MessageBubble.failedKey), findsNothing);
    expect(find.text('server committed'), findsOneWidget);
    expect(
      service.operationQueries,
      hasLength(1),
      reason: 'the operation id, not similar content, proves the message',
    );
    expect(tester.takeException(), isNull);
  });

  for (final bool refresh in <bool>[false, true]) {
    testWidgets(
      'an accepted send stays one bubble while its failed-operation lookup is '
      'in flight (${refresh ? 'refresh' : 'poll'})',
      (WidgetTester tester) async {
        final _CommitThenFailService service = _CommitThenFailService(
          lookupGate: Completer<void>(),
        );
        final _Harness harness = _Harness(service: service);
        await harness.pump(tester);

        await harness.send(tester, 'committed response lost');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        if (refresh) {
          await tester.tap(find.byKey(ChatPage.refreshKey));
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 3));
          await tester.pump();
          await tester.pump(const Duration(seconds: 3));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.descendant(
            of: find.byType(MessageBubble),
            matching: find.text('committed response lost'),
          ),
          findsOneWidget,
          reason: 'the lookup window must not render accepted + failure twice',
        );
        expect(
          find.byKey(MessageBubble.failedKey),
          findsNothing,
          reason: 'history association proves the commit before the lookup',
        );

        service.lookupGate!.complete();
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(MessageBubble),
            matching: find.text('committed response lost'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(MessageBubble.failedKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a failed operation lookup keeps the failure retryable and '
      'releases the held message', (WidgetTester tester) async {
    final _CommitThenFailService service = _CommitThenFailService(
      failLookup: true,
    );
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'lookup unavailable');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(
      find.text('lookup unavailable'),
      findsOneWidget,
      reason: 'an unknown operation keeps the accepted message held',
    );
    service.retryReturnsCommitted = true;
    await tester.tap(find.byKey(MessageBubble.failedKey));
    await tester.pumpAndSettle();
    expect(find.byKey(MessageBubble.failedKey), findsNothing);
    expect(find.text('lookup unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry can settle while the operation lookup is still in flight '
      'without a duplicate', (WidgetTester tester) async {
    final _CommitThenFailService service = _CommitThenFailService(
      lookupGate: Completer<void>(),
    )..retryReturnsCommitted = true;
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'retry during lookup');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);

    await tester.tap(find.byKey(MessageBubble.failedKey));
    await tester.pumpAndSettle();
    expect(find.byKey(MessageBubble.failedKey), findsNothing);
    expect(find.text('retry during lookup'), findsOneWidget);

    service.lookupGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('retry during lookup'), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  for (final bool refresh in <bool>[false, true]) {
    testWidgets(
      'a pending operation stays one failure bubble until later acceptance '
      '(${refresh ? 'refresh' : 'poll'})',
      (WidgetTester tester) async {
        final _PendingThenCommittedService service =
            _PendingThenCommittedService();
        final _Harness harness = _Harness(service: service);
        await harness.pump(tester);

        await harness.send(tester, 'late commit');
        await tester.pumpAndSettle();
        expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
        expect(find.text('late commit'), findsOneWidget);
        expect(service.operationQueries, hasLength(1));

        await service.acceptLater();
        if (refresh) {
          await tester.tap(find.byKey(ChatPage.refreshKey));
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 3));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(MessageBubble),
            matching: find.text('late commit'),
          ),
          findsOneWidget,
          reason: 'pending is not not-found; later acceptance must reconcile',
        );
        expect(find.byKey(MessageBubble.failedKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('uncertain operation status is held and retried like pending', (
    WidgetTester tester,
  ) async {
    final _PendingThenCommittedService service = _PendingThenCommittedService(
      pendingStatus: OperationStatus.uncertain,
    );
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'uncertain commit');
    await tester.pumpAndSettle();
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(find.text('uncertain commit'), findsOneWidget);

    await service.acceptLater();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('uncertain commit'), findsOneWidget);
    expect(find.byKey(MessageBubble.failedKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status rows scale with text and are not vertically clipped', (
    WidgetTester tester,
  ) async {
    void expectFullyLaidOut(String text) {
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.text(text),
      );
      final TextPainter painter = TextPainter(
        text: paragraph.text,
        textDirection: TextDirection.ltr,
        textScaler: paragraph.textScaler,
      )..layout(maxWidth: paragraph.size.width);
      expect(
        paragraph.size.height,
        greaterThanOrEqualTo(painter.height - 0.01),
        reason: '$text must not be taller than its allocated box',
      );
      painter.dispose();
    }

    final _Harness harness = _Harness(
      thread: <ChatMessage>[_message(1)],
      textScale: 1.6,
    );
    harness.chat.sendGate = Completer<void>();
    harness.chat.failBody = true;
    await harness.pump(tester);
    expectFullyLaidOut('12:01');

    await harness.send(tester, 'scaled status');
    await tester.pump();
    expectFullyLaidOut('发送中…');

    harness.chat.sendGate!.complete();
    await tester.pumpAndSettle();
    expectFullyLaidOut('未发送 · 点按重试');
    expect(tester.takeException(), isNull);
  });

  for (final bool lateError in <bool>[false, true]) {
    testWidgets(
      'a late lookup ${lateError ? 'error' : 'success'} after a definitive '
      'retry cannot hide another operation',
      (WidgetTester tester) async {
        final _CommitThenFailService service = _CommitThenFailService(
          lookupGate: Completer<void>(),
          failLookup: lateError,
        )..retryReturnsCommitted = true;
        final _Harness harness = _Harness(service: service);
        await harness.pump(tester);

        await harness.send(tester, 'retry during lookup');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(MessageBubble.failedKey), findsOneWidget);

        await tester.tap(find.byKey(MessageBubble.failedKey));
        await tester.pumpAndSettle();
        expect(find.byKey(MessageBubble.failedKey), findsNothing);
        expect(find.text('retry during lookup'), findsOneWidget);

        service.lookupGate!.complete();
        await tester.pumpAndSettle();

        service.conversations[_bob.account]!.add(
          _message(1000, sender: _self.account, text: 'different writer'),
        );
        await tester.tap(find.byKey(ChatPage.refreshKey));
        await tester.pumpAndSettle();

        expect(
          find.text('different writer'),
          findsOneWidget,
          reason: 'a stale lookup cannot hold an unrelated committed message',
        );
        expect(find.text('retry during lookup'), findsOneWidget);
        expect(find.byKey(MessageBubble.failedKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a lookup completing after the conversation is disposed does '
      'not mutate or throw', (WidgetTester tester) async {
    final _CommitThenFailService service = _CommitThenFailService(
      lookupGate: Completer<void>(),
    );
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);
    await harness.send(tester, 'closed conversation');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    service.lookupGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('another writer is visible while a local send is still running', (
    WidgetTester tester,
  ) async {
    final FakeChatService service = FakeChatService(
      self: _self,
      users: const <ChatUser>[_bob],
      conversations: <String, List<ChatMessage>>{
        _bob.account: <ChatMessage>[_message(1)],
      },
    )..sendGate = Completer<void>();
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'local ongoing');
    service.conversations[_bob.account]!.add(
      _message(2, sender: _self.account, text: 'other writer committed'),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('other writer committed'), findsOneWidget);
    expect(find.text('local ongoing'), findsOneWidget);
    expect(find.byKey(MessageBubble.sendingKey), findsOneWidget);
    service.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final String answer in <String>['error', 'pending', 'uncertain']) {
    for (final bool refresh in <bool>[false, true]) {
      for (final bool media in <bool>[false, true]) {
        testWidgets(
          'unrelated ${media ? 'same-media' : 'same-text'} is visible while '
          'another operation is $answer via ${refresh ? 'refresh' : 'poll'}',
          (WidgetTester tester) async {
            final _UnresolvedLookupService service = _UnresolvedLookupService(
              answer,
            );
            final _Harness harness = _Harness(
              service: service,
              clipboard: _FakeClipboard(
                PickedMedia(
                  bytes: base64Decode(_tinyPng),
                  filename: 'same.png',
                  mimeType: 'image/png',
                ),
              ),
            );
            await harness.pump(tester);
            if (media) {
              await pasteFromClipboard(tester);
              await tester.tap(find.byKey(ChatComposer.sendKey));
              await tester.pump();
            } else {
              await harness.send(tester, 'same text');
            }
            await tester.pumpAndSettle();

            expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
            expect(find.text('状态待确认 · 点按重试'), findsOneWidget);
            expect(find.text('未发送 · 点按重试'), findsNothing);

            final ChatMessage other = ChatMessage(
              id: 'other-operation-message',
              position: 2,
              senderAccount: _self.account,
              targetAccount: _bob.account,
              createdAt: DateTime.now().toUtc(),
              kind: ChatMessageKind.body,
              parts: media
                  ? const <MessagePart>[ImagePart('other-media-id')]
                  : const <MessagePart>[TextPart('same text')],
            );
            service.conversations[_bob.account]!.add(other);
            for (int cycle = 0; cycle < 3; cycle += 1) {
              if (refresh) {
                await tester.tap(find.byKey(ChatPage.refreshKey));
                await tester.pump();
              } else {
                await tester.pump(const Duration(seconds: 3));
              }
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
            }

            expect(
              tester
                  .widgetList<MessageBubble>(find.byType(MessageBubble))
                  .where(
                    (MessageBubble bubble) => bubble.message.id == other.id,
                  ),
              hasLength(1),
              reason: 'unrelated committed message must not be hidden',
            );
            expect(
              tester
                  .widgetList<MessageBubble>(find.byType(MessageBubble))
                  .where(
                    (MessageBubble bubble) =>
                        bubble.sendState == SendFeedbackState.failed,
                  ),
              hasLength(1),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('authoritative not-found labels the failure as unsent', (
    WidgetTester tester,
  ) async {
    final _UnresolvedLookupService service = _UnresolvedLookupService('absent');
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);
    await harness.send(tester, 'definitely not sent');
    await tester.pumpAndSettle();
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(find.text('未发送 · 点按重试'), findsOneWidget);
    expect(find.text('状态待确认 · 点按重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry failing again starts a new lookup; the old completion '
      'cannot cancel it', (WidgetTester tester) async {
    final _TwoLookupService service = _TwoLookupService();
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);

    await harness.send(tester, 'retry again');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(service.operationQueries, hasLength(1));

    await tester.tap(find.byKey(MessageBubble.failedKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
    expect(service.operationQueries, hasLength(2));

    service.firstLookup.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(MessageBubble.failedKey), findsOneWidget);

    service.secondLookup.complete();
    await tester.pumpAndSettle();
    expect(find.text('retry again'), findsOneWidget);
    expect(find.byKey(MessageBubble.failedKey), findsNothing);

    service.conversations[_bob.account]!.add(
      _message(3, sender: _self.account, text: 'unrelated writer'),
    );
    await tester.tap(find.byKey(ChatPage.refreshKey));
    await tester.pumpAndSettle();
    expect(find.text('unrelated writer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lookup completing after the peer changes cannot add its '
      'message to the mounted page', (WidgetTester tester) async {
    final _CommitThenFailService service = _CommitThenFailService(
      lookupGate: Completer<void>(),
    );
    final _Harness harness = _Harness(service: service);
    await harness.pump(tester);
    await harness.send(tester, 'old peer message');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await harness.pump(
      tester,
      peer: const ChatUser(
        account: '10000003',
        username: 'carol',
        avatarUrl: '/avatars/10000003.png',
        avatarVersion: 'v-carol',
        presence: Presence.offline,
      ),
    );
    service.lookupGate!.complete();
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.text('old peer message'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final bool poll in <bool>[false, true]) {
    for (final bool reject in <bool>[false, true]) {
      testWidgets(
        'old history ${poll ? 'poll' : 'refresh'} ${reject ? 'error' : 'success'} '
        'cannot change the new peer page',
        (WidgetTester tester) async {
          final _HistoryScopeService service = _HistoryScopeService();
          final _Harness harness = _Harness(service: service);
          await harness.pump(tester);

          service.conversations[_bob.account]!.add(
            _message(2, text: 'BOB LATE PRIVATE'),
          );
          service.historyGate = Completer<void>();
          service.reject = reject;
          if (poll) {
            await tester.pump(const Duration(seconds: 3));
            await tester.pump();
          } else {
            await tester.tap(find.byKey(ChatPage.refreshKey));
            await tester.pump();
          }

          await harness.pump(
            tester,
            peer: const ChatUser(
              account: '10000003',
              username: 'carol',
              avatarUrl: '/avatars/10000003.png',
              avatarVersion: 'v-carol',
              presence: Presence.offline,
            ),
          );
          service.historyGate!.complete();
          await tester.pumpAndSettle();

          expect(find.text('BOB LATE PRIVATE'), findsNothing);
          expect(find.text('OLD BOB LOAD ERROR'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
