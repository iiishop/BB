import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/mention_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_mention_controller.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_drafts.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/message_bubble.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_profile_gateway.dart';

const AuthUser _alice = AuthUser(account: '10000001', username: 'alice');
const ChatUser _bob = ChatUser(
  account: '10000002',
  username: 'bob',
  avatarUrl: '',
  avatarVersion: 'v1',
  presence: Presence.online,
);
final String _groupId = 'group:${'a1b2c3d4' * 4}';

ChatMessage _dmMsg(
  int position, {
  required String sender,
  required String text,
  String? id,
  String? senderUsername,
  ReplyQuote? replyTo,
}) {
  return ChatMessage(
    id: id ?? 'm-$position',
    position: position,
    senderAccount: sender,
    senderUsername: senderUsername,
    targetAccount: sender == _alice.account ? _bob.account : _alice.account,
    createdAt: DateTime.utc(2026, 11, 28, 12, position % 60),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text)],
    replyTo: replyTo,
  );
}

ChatMessage _groupMsg(
  int position, {
  required String sender,
  required String senderUsername,
  required String text,
  String? id,
  ReplyQuote? replyTo,
}) {
  return ChatMessage(
    id: id ?? 'g-$position',
    position: position,
    senderAccount: sender,
    senderUsername: senderUsername,
    conversation: ConversationRef.group(_groupId),
    createdAt: DateTime.utc(2026, 11, 28, 12, position % 60),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text)],
    replyTo: replyTo,
  );
}

class _InMemoryAlertApiClient extends ChatApiClient {
  _InMemoryAlertApiClient({
    required this.selfAccount,
    required this.dmMessages,
    required this.groupMessages,
  }) : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final String selfAccount;
  final List<ChatMessage> dmMessages;
  final List<ChatMessage> groupMessages;

  final Map<String, List<UnreadAlert>> alertsByConversation =
      <String, List<UnreadAlert>>{};
  final List<String> contextCalls = <String>[];
  final List<({String conversationId, List<String> messageIds})> markSeenCalls =
      <({String conversationId, List<String> messageIds})>[];
  final List<String> listAlertsCalls = <String>[];

  bool failListAlerts = false;
  final Set<String> failContextIds = <String>{};

  void addAlert(String conversationId, UnreadAlert alert) {
    final List<UnreadAlert> list = alertsByConversation.putIfAbsent(
      conversationId,
      () => <UnreadAlert>[],
    );
    list.add(alert);
    list.sort(
      (UnreadAlert a, UnreadAlert b) => b.position.compareTo(a.position),
    );
  }

  @override
  Future<ClientAlertSummaryPage> alertSummary({
    required String token,
    String? afterConversationId,
    int limit = mentionDefaultPageLimit,
  }) async {
    final List<ClientAlertSummary> items = <ClientAlertSummary>[];
    for (final MapEntry<String, List<UnreadAlert>> entry
        in alertsByConversation.entries) {
      final List<UnreadAlert> list = entry.value;
      if (list.isEmpty) {
        continue;
      }
      final int mentions = list.where((UnreadAlert a) => a.mention).length;
      final int replies = list.where((UnreadAlert a) => a.reply).length;
      final UnreadAlert latest = list.first;
      items.add(
        ClientAlertSummary(
          conversationId: entry.key,
          displayName: entry.key == _groupId ? '产品测试群' : _bob.username,
          unreadMentionCount: mentions,
          unreadReplyCount: replies,
          latestAlert: latest,
        ),
      );
    }
    return ClientAlertSummaryPage(items: items);
  }

  @override
  Future<AlertPage> listAlerts({
    required String token,
    required ConversationRef conversation,
    int? beforePosition,
    int limit = mentionDefaultPageLimit,
  }) async {
    listAlertsCalls.add(conversation.id);
    if (failListAlerts) {
      throw const AuthFailure(
        status: 503,
        code: 'unavailable',
        message: '提醒查询失败，请稍后重试',
      );
    }
    final List<UnreadAlert> all =
        alertsByConversation[conversation.id] ?? const <UnreadAlert>[];
    final List<UnreadAlert> filtered = all
        .where(
          (UnreadAlert a) =>
              beforePosition == null || a.position < beforePosition,
        )
        .take(limit)
        .toList(growable: false);
    return AlertPage(
      items: filtered,
      nextCursor: filtered.length < limit ? null : filtered.last.position,
    );
  }

  @override
  Future<AlertCounts> markAlertsSeen({
    required String token,
    required ConversationRef conversation,
    required List<String> messageIds,
  }) async {
    markSeenCalls.add((
      conversationId: conversation.id,
      messageIds: List<String>.of(messageIds),
    ));
    final List<UnreadAlert> list =
        alertsByConversation[conversation.id] ?? <UnreadAlert>[];
    final Set<String> seen = messageIds.toSet();
    list.removeWhere((UnreadAlert a) => seen.contains(a.messageId));
    return AlertCounts(
      unreadMentionCount: list.where((UnreadAlert a) => a.mention).length,
      unreadReplyCount: list.where((UnreadAlert a) => a.reply).length,
    );
  }

  @override
  Future<MessageContextRecord?> messageContext({
    required String token,
    required String messageId,
    int beforeLimit = 10,
    int afterLimit = 10,
  }) async {
    contextCalls.add(messageId);
    if (failContextIds.contains(messageId)) {
      return null;
    }
    int idx = dmMessages.indexWhere((ChatMessage m) => m.id == messageId);
    List<ChatMessage> source = dmMessages;
    String peerAccount = _bob.account;
    ConversationRef? conversation = ConversationRef.direct(
      selfAccount,
      _bob.account,
    );
    if (idx < 0) {
      idx = groupMessages.indexWhere((ChatMessage m) => m.id == messageId);
      source = groupMessages;
      peerAccount = '';
      conversation = ConversationRef.group(_groupId);
    }
    if (idx < 0) {
      return null;
    }
    final int start = (idx - beforeLimit).clamp(0, source.length);
    final int end = (idx + afterLimit + 1).clamp(0, source.length);
    final List<ChatMessage> slice = source.sublist(start, end);
    return MessageContextRecord(
      items: slice,
      anchorMessageId: messageId,
      peerAccount: peerAccount,
      conversation: conversation,
      startPosition: slice.first.position,
      endPosition: slice.last.position,
      beforeHasMore: start > 0,
      afterHasMore: end < source.length,
      missingPositions: const <int>[],
      missingTruncated: false,
      replyRelations: 'inline',
    );
  }
}

class _InMemorySharedService extends SharedConversationService {
  _InMemorySharedService({
    required _InMemoryAlertApiClient api,
    required FakeChatService chat,
    required this.groups,
    required this.groupMessages,
  }) : super(
         api: api,
         session: chat.session,
         access: ConversationAccessController(),
         durableChat: chat,
       );

  final List<GroupConversationItem> groups;
  final List<ChatMessage> groupMessages;

  @override
  Future<SharedConversationPage> listSharedConversations({
    String afterId = '',
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    return SharedConversationPage(items: groups, nextCursor: null);
  }

  @override
  Future<MessagePage> loadConversationHistory({
    required ConversationRef conversation,
    int? afterPosition = 0,
    int? beforePosition,
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    final List<ChatMessage> all = List<ChatMessage>.of(
      groupMessages,
    )..sort((ChatMessage a, ChatMessage b) => a.position.compareTo(b.position));
    final bool backward = beforePosition != null;
    final List<ChatMessage> candidates = backward
        ? all.where((ChatMessage m) => m.position < beforePosition).toList()
        : all
              .where((ChatMessage m) => m.position > (afterPosition ?? 0))
              .toList();
    final int start = candidates.length > limit ? candidates.length - limit : 0;
    final List<ChatMessage> page = backward
        ? candidates.sublist(start)
        : candidates.take(limit).toList();
    return MessagePage(
      items: page,
      nextPosition: page.isEmpty
          ? (beforePosition ?? afterPosition ?? 0)
          : (backward ? page.first.position : page.last.position),
      hasMore: candidates.length > page.length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ChatDrafts.instance.resetForTest();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'desktop right-click menu offers 回复 & 复制整条, Esc closes and restores bubble focus, copy excludes quote header',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? copiedClipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              copiedClipboard =
                  (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
            }
            return null;
          });

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[
            _dmMsg(1, sender: _bob.account, text: '原消息正文 A'),
            _dmMsg(
              2,
              sender: _alice.account,
              text: '我发的回复正文 B',
              replyTo: const ReplyQuote(
                messageId: 'm-1',
                senderAccount: '10000002',
                senderUsername: 'bob',
                preview: '原消息正文 A',
              ),
            ),
          ],
        },
      );
      final FakeProfileGateway profile = FakeProfileGateway();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profile),
        ),
      );
      await tester.pumpAndSettle();

      // Right-click directly over the reply bubble text.
      await tester.tapAt(
        tester.getCenter(find.text('我发的回复正文 B')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(MessageBubble.replyActionKey), findsOneWidget);
      expect(find.byKey(MessageBubble.copyActionKey), findsOneWidget);

      // Press Escape to dismiss menu cleanly and restore focus to the bubble.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(MessageBubble.replyActionKey), findsNothing);
      final FocusNode? restoredFocus = FocusManager.instance.primaryFocus;
      expect(restoredFocus?.debugLabel, contains('chat-bubble-'));

      // Right-click again and choose "复制整条": copies ONLY body text (not quote!).
      await tester.tapAt(
        tester.getCenter(find.text('我发的回复正文 B')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MessageBubble.copyActionKey));
      await tester.pumpAndSettle();

      expect(copiedClipboard, '我发的回复正文 B');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Option A quote bar spans above composer, cancel & Esc preserve draft, send & retry carry replyToMessageId',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[
            _dmMsg(1, sender: _bob.account, text: '明天几点集合？'),
            _dmMsg(2, sender: _alice.account, text: '我先发一条自己的消息'),
          ],
        },
      );
      final FakeProfileGateway profile = FakeProfileGateway();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profile),
        ),
      );
      await tester.pumpAndSettle();

      // Right-click peer message -> enter reply mode.
      await tester.tapAt(
        tester.getCenter(find.text('明天几点集合？')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MessageBubble.replyActionKey));
      await tester.pumpAndSettle();

      expect(find.byKey(ChatComposer.replyBarKey), findsOneWidget);
      expect(find.text('回复 bob'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ChatComposer.replyBarKey),
          matching: find.text('明天几点集合？'),
        ),
        findsOneWidget,
      );

      // Verify Option A spans ABOVE the input row.
      final Rect barRect = tester.getRect(find.byKey(ChatComposer.replyBarKey));
      final Rect inputRect = tester.getRect(find.byKey(ChatComposer.inputKey));
      expect(barRect.bottom, lessThanOrEqualTo(inputRect.top));

      // Type draft text, cancel quote via × -> draft MUST stay intact.
      await tester.enterText(find.byKey(ChatComposer.inputKey), '早上九点半');
      await tester.pump();
      await tester.tap(find.byKey(ChatComposer.replyCancelKey));
      await tester.pumpAndSettle();

      expect(find.byKey(ChatComposer.replyBarKey), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(ChatComposer.inputKey))
            .controller!
            .text,
        '早上九点半',
      );

      // Enter reply on own message -> Esc cancels quote while preserving draft.
      await tester.tapAt(
        tester.getCenter(find.text('我先发一条自己的消息')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MessageBubble.replyActionKey));
      await tester.pumpAndSettle();
      expect(find.text('回复 我'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.replyBarKey), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(ChatComposer.inputKey))
            .controller!
            .text,
        '早上九点半',
      );

      // Fail initial send once, then retry failed bubble -> preserves replyToMessageId!
      await tester.tapAt(
        tester.getCenter(find.text('明天几点集合？')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MessageBubble.replyActionKey));
      await tester.pumpAndSettle();

      chat.failBody = true;
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();
      expect(find.byKey(MessageBubble.failedKey), findsOneWidget);
      expect(find.byKey(ChatComposer.replyBarKey), findsNothing);

      chat.failBody = false;
      await tester.tap(find.byKey(MessageBubble.failedKey));
      await tester.pumpAndSettle();

      expect(chat.lastReplyToMessageId, 'm-1');
      expect(find.byKey(MessageBubble.failedKey), findsNothing);
      expect(
        find.descendant(
          of: find.byType(MessageBubble).last,
          matching: find.text('明天几点集合？'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile phone long-press action sheet & left-swipe threshold work on own and peer messages without narrow overflow',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[
            _dmMsg(
              1,
              sender: _bob.account,
              text: '这是一条非常非常长用于验证窄屏不溢出的消息内容示例ABCDEFGHIJKLMNOPQRSTUVWXYZ',
            ),
            _dmMsg(2, sender: _alice.account, text: '我自己的消息也能左滑引用'),
          ],
        },
      );
      final FakeProfileGateway profile = FakeProfileGateway();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profile),
        ),
      );
      await tester.pumpAndSettle();

      // Long-press peer message -> compact bottom sheet with 回复, 复制整条, 取消.
      final Finder peerBubble = find.byKey(
        const ValueKey<String>('chat-bubble-m-1@1'),
      );
      final Finder selfBubble = find.byKey(
        const ValueKey<String>('chat-bubble-m-2@2'),
      );
      await tester.longPress(peerBubble);
      await tester.pumpAndSettle();
      expect(find.byKey(MessageBubble.replyActionKey), findsOneWidget);
      expect(find.byKey(MessageBubble.copyActionKey), findsOneWidget);
      expect(find.byKey(MessageBubble.sheetCancelKey), findsOneWidget);

      await tester.tap(find.byKey(MessageBubble.sheetCancelKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.replyBarKey), findsNothing);

      // Left-swipe -30px on own message -> springs back without entering reply.
      await tester.timedDrag(
        selfBubble,
        const Offset(-30, 0),
        const Duration(milliseconds: 120),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.replyBarKey), findsNothing);

      // Left-swipe -80px on own message -> enters reply mode targeting own message.
      await tester.timedDrag(
        selfBubble,
        const Offset(-80, 0),
        const Duration(milliseconds: 140),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.replyBarKey), findsOneWidget);
      expect(find.text('回复 我'), findsOneWidget);

      // Long preview quote bar at 360px also triggers via long-press -> 回复 without overflow.
      await tester.tap(find.byKey(ChatComposer.replyCancelKey));
      await tester.pumpAndSettle();
      await tester.longPress(peerBubble);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MessageBubble.replyActionKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.replyBarKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clicking quote block loads context outside initial 100-message window, highlights original, never marks alerts seen, and handles lookup failure cleanly',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Build 120 messages so positions 1..20 are outside the initial 100-msg window.
      final List<ChatMessage> dmMessages = <ChatMessage>[
        for (int pos = 1; pos <= 120; pos += 1)
          if (pos == 118)
            _dmMsg(
              118,
              sender: _bob.account,
              senderUsername: 'bob',
              text: '回复很早以前第5条的那句',
              replyTo: const ReplyQuote(
                messageId: 'm-5',
                senderAccount: '10000001',
                senderUsername: 'alice',
                preview: '历史原消息第5条',
              ),
            )
          else if (pos == 119)
            _dmMsg(
              119,
              sender: _bob.account,
              senderUsername: 'bob',
              text: '缺失原文引用',
              replyTo: const ReplyQuote(
                messageId: 'm-missing',
                senderAccount: '10000001',
                senderUsername: 'alice',
                preview: '不存在的原消息',
              ),
            )
          else
            _dmMsg(
              pos,
              sender: pos.isEven ? _alice.account : _bob.account,
              senderUsername: pos.isEven ? 'alice' : 'bob',
              text: pos == 5 ? '历史原消息第5条' : '第 $pos 条对话记录',
            ),
      ];

      final _InMemoryAlertApiClient api = _InMemoryAlertApiClient(
        selfAccount: _alice.account,
        dmMessages: dmMessages,
        groupMessages: const <ChatMessage>[],
      );
      final ConversationRef dmConv = ConversationRef.direct(
        _alice.account,
        _bob.account,
      );
      api.addAlert(
        dmConv.id,
        const UnreadAlert(
          messageId: 'm-12',
          position: 12,
          mention: false,
          reply: true,
        ),
      );

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{_bob.account: dmMessages},
        api: api,
      );
      final _InMemorySharedService shared = _InMemorySharedService(
        api: api,
        chat: chat,
        groups: const <GroupConversationItem>[],
        groupMessages: const <ChatMessage>[],
      );
      final MentionRecipientController alerts = MentionRecipientController(
        shared: shared,
      );
      addTearDown(alerts.dispose);
      await alerts.refreshSummary();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(
            peer: _bob,
            chat: chat,
            profile: FakeProfileGateway(),
            shared: shared,
            alerts: alerts,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially m-5 bubble is NOT loaded, unread alert m-12 is preserved.
      expect(
        find.byKey(const ValueKey<String>('chat-bubble-m-5@5')),
        findsNothing,
      );
      expect(alerts.unreadReplyCountFor(dmConv.id), 1);
      expect(
        api.markSeenCalls.expand((c) => c.messageIds),
        isNot(contains('m-12')),
      );

      // Tap broken quote first -> explicit error SnackBar, no alert consumed.
      await tester.tap(find.byKey(MessageBubble.quoteKeyFor('m-119@119')));
      await tester.pumpAndSettle();
      expect(find.textContaining('原消息定位失败'), findsOneWidget);
      expect(
        api.markSeenCalls.expand((c) => c.messageIds),
        isNot(contains('m-12')),
      );
      expect(alerts.unreadReplyCountFor(dmConv.id), 1);

      // Tap valid quote targeting m-5 -> loads /messages/m-5/context & jumps!
      await tester.tap(find.byKey(MessageBubble.quoteKeyFor('m-118@118')));
      for (int i = 0; i < 10; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(api.contextCalls, contains('m-5'));
      expect(
        find.byKey(const ValueKey<String>('chat-bubble-m-5@5')),
        findsOneWidget,
      );
      expect(
        find.byKey(MessageBubble.highlightKeyFor('m-5@5')),
        findsOneWidget,
      );
      // Settle past highlight timer & post-jump timer: quote jump MUST NOT mark m-12 seen.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(
        api.markSeenCalls.expand((c) => c.messageIds),
        isNot(contains('m-12')),
      );
      expect(alerts.unreadReplyCountFor(dmConv.id), 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'session list shows 有人回复你, single right alert pill jumps newest-to-oldest, handles failed jumps, confirms foreground viewport selectively for sibling replies, and respects reduced motion',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 80 group messages so early unread replies (pos 12 and pos 30) are off-screen when opened at bottom.
      // Reply at pos 12 and reply at pos 30 BOTH reply to the SAME original pos 5!
      final List<ChatMessage> groupMessages = <ChatMessage>[
        for (int pos = 1; pos <= 80; pos += 1)
          _groupMsg(
            pos,
            sender: pos == 5 || pos == 75 ? _alice.account : _bob.account,
            senderUsername: pos == 5 || pos == 75 ? 'alice' : 'bob',
            text: switch (pos) {
              5 => '被两人共同回复的原消息',
              12 => '较早的一条回复 R1',
              30 => '较新的一条回复并@你 R2',
              75 => '我自己发的回复（不产生提醒）',
              80 => '末尾普通寒暄消息',
              _ => '群聊消息 $pos',
            },
            replyTo: (pos == 12 || pos == 30)
                ? const ReplyQuote(
                    messageId: 'g-5',
                    senderAccount: '10000001',
                    senderUsername: 'alice',
                    preview: '被两人共同回复的原消息',
                  )
                : (pos == 75
                      ? const ReplyQuote(
                          messageId: 'g-10',
                          senderAccount: '10000002',
                          senderUsername: 'bob',
                          preview: '群聊消息 10',
                        )
                      : null),
          ),
      ];

      final GroupConversationItem groupItem = GroupConversationItem(
        conversation: ConversationRef.group(_groupId),
        groupNumber: '88880001',
        displayName: '产品测试群',
        avatarUrl: '',
        avatarVersion: 'v0',
        membershipRevision: 1,
        historyThrough: 0,
        latestPosition: 80,
        lastActivityAt: DateTime.utc(2026, 11, 28, 13, 0),
        lastMessage: groupMessages.last,
      );

      final _InMemoryAlertApiClient api = _InMemoryAlertApiClient(
        selfAccount: _alice.account,
        dmMessages: const <ChatMessage>[],
        groupMessages: groupMessages,
      );
      api.addAlert(
        _groupId,
        const UnreadAlert(
          messageId: 'g-12',
          position: 12,
          mention: false,
          reply: true,
        ),
      );
      api.addAlert(
        _groupId,
        const UnreadAlert(
          messageId: 'g-30',
          position: 30,
          mention: true,
          reply: true,
        ),
      );

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        api: api,
      );
      final _InMemorySharedService shared = _InMemorySharedService(
        api: api,
        chat: chat,
        groups: <GroupConversationItem>[groupItem],
        groupMessages: groupMessages,
      );
      final MentionRecipientController alerts = MentionRecipientController(
        shared: shared,
      );
      addTearDown(alerts.dispose);
      final ConversationRef dmConv = ConversationRef.direct(
        _alice.account,
        _bob.account,
      );
      api.addAlert(
        dmConv.id,
        const UnreadAlert(
          messageId: 'm-99',
          position: 99,
          mention: false,
          reply: true,
        ),
      );
      await alerts.refreshSummary();

      // 1) Session list shows "有人回复你" and "有人 @ 你" on both group and DM rows even with plain latest msg 80.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: UsersListView(
              chat: chat,
              profile: FakeProfileGateway(),
              shared: shared,
              alerts: alerts,
              onOpenChat: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(UsersListView.replyAlertKey(_groupId)), findsOneWidget);
      expect(
        find.byKey(UsersListView.replyAlertKey(dmConv.id)),
        findsOneWidget,
      );
      expect(find.text('有人回复你'), findsNWidgets(2));
      expect(find.text('有人 @ 你'), findsOneWidget);

      // 2) Open group ChatPage with reduced motion -> lands at bottom, does NOT mark g-12 or g-30 seen!
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(1000, 760),
            disableAnimations: true,
          ),
          child: MaterialApp(
            theme: buildAppTheme(),
            home: ChatPage(
              group: groupItem,
              chat: chat,
              profile: FakeProfileGateway(),
              shared: shared,
              alerts: alerts,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ChatPage.alertJumpKey), findsOneWidget);
      expect(find.text('跳到回复 + @'), findsOneWidget);
      expect(
        api.markSeenCalls.expand((c) => c.messageIds),
        isNot(anyOf(contains('g-12'), contains('g-30'))),
      );
      expect(alerts.unreadReplyCountFor(_groupId), 2);
      expect(alerts.unreadMentionCountFor(_groupId), 1);

      // 3) Simulate jump failure: alert list fails -> explicit failure feedback, button & alerts preserved!
      api.failListAlerts = true;
      final int seenCallsBeforeFail = api.markSeenCalls.length;
      await tester.tap(find.byKey(ChatPage.alertJumpKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('提醒查询失败'), findsOneWidget);
      expect(alerts.unreadReplyCountFor(_groupId), 2);
      expect(api.markSeenCalls.length, seenCallsBeforeFail);
      api.failListAlerts = false;

      // 4) Tap shared alert button -> jumps newest-to-oldest to g-30 first, clearing g-30 (both @ and reply) while keeping g-12!
      await tester.tap(find.byKey(ChatPage.alertJumpKey));
      await tester.pumpAndSettle();

      expect(find.text('较新的一条回复并@你 R2'), findsOneWidget);
      expect(
        api.markSeenCalls.any(
          (call) =>
              call.conversationId == _groupId &&
              call.messageIds.contains('g-30') &&
              !call.messageIds.contains('g-12'),
        ),
        isTrue,
      );
      expect(alerts.unreadReplyCountFor(_groupId), 1);
      expect(alerts.unreadMentionCountFor(_groupId), 0);
      expect(find.text('跳到回复'), findsOneWidget);

      // 5) Next tap jumps to g-12 -> clears g-12, button disappears cleanly!
      await tester.tap(find.byKey(ChatPage.alertJumpKey));
      await tester.pumpAndSettle();

      expect(find.text('较早的一条回复 R1'), findsOneWidget);
      expect(alerts.unreadReplyCountFor(_groupId), 0);
      expect(alerts.hasUnreadAlerts(_groupId), isFalse);
      expect(find.byKey(ChatPage.alertJumpKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'out-of-order manual scroll clears only the alert currently visible in foreground viewport',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final List<ChatMessage> dmMessages = <ChatMessage>[
        for (int pos = 1; pos <= 60; pos += 1)
          _dmMsg(
            pos,
            sender: pos == 2 || pos == 50 ? _bob.account : _alice.account,
            senderUsername: pos == 2 || pos == 50 ? 'bob' : 'alice',
            text: pos == 2
                ? '最早未读回复 B'
                : (pos == 50 ? '较新未读回复 C' : '普通消息 #$pos'),
          ),
      ];
      final ConversationRef dmConv = ConversationRef.direct(
        _alice.account,
        _bob.account,
      );
      final _InMemoryAlertApiClient api = _InMemoryAlertApiClient(
        selfAccount: _alice.account,
        dmMessages: dmMessages,
        groupMessages: const <ChatMessage>[],
      );
      api.addAlert(
        dmConv.id,
        const UnreadAlert(
          messageId: 'm-2',
          position: 2,
          mention: false,
          reply: true,
        ),
      );
      api.addAlert(
        dmConv.id,
        const UnreadAlert(
          messageId: 'm-50',
          position: 50,
          mention: false,
          reply: true,
        ),
      );

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{_bob.account: dmMessages},
        api: api,
      );
      final _InMemorySharedService shared = _InMemorySharedService(
        api: api,
        chat: chat,
        groups: const <GroupConversationItem>[],
        groupMessages: const <ChatMessage>[],
      );
      final MentionRecipientController alerts = MentionRecipientController(
        shared: shared,
      );
      addTearDown(alerts.dispose);
      await alerts.refreshSummary();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(
            peer: _bob,
            chat: chat,
            profile: FakeProfileGateway(),
            shared: shared,
            alerts: alerts,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Opened at bottom (around pos 60): neither m-50 nor m-2 is visible yet.
      expect(alerts.unreadReplyCountFor(dmConv.id), 2);

      // Manually drag/scroll up slightly so m-50 enters foreground viewport while m-2 stays far off-screen.
      await tester.dragUntilVisible(
        find.text('较新未读回复 C'),
        find.byKey(ChatPage.listKey),
        const Offset(0, 220),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(
        api.markSeenCalls.any(
          (c) => c.messageIds.contains('m-50') && !c.messageIds.contains('m-2'),
        ),
        isTrue,
      );
      expect(alerts.unreadReplyCountFor(dmConv.id), 1);
      expect(find.byKey(ChatPage.alertJumpKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reply target and draft survive route reopen per conversation, and self reply bubble displays without alert',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final FakeChatService chat = FakeChatService(
        self: _alice,
        users: const <ChatUser>[_bob],
        conversations: <String, List<ChatMessage>>{
          _bob.account: <ChatMessage>[
            _dmMsg(1, sender: _bob.account, text: '方案已发出'),
          ],
        },
      );
      final FakeProfileGateway profile = FakeProfileGateway();

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profile),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tapAt(
        tester.getCenter(find.text('方案已发出')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MessageBubble.replyActionKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ChatComposer.inputKey), '收到马上看');
      await tester.pump();

      // Unmount and remount ChatPage for the same peer -> draft + reply target restore.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: ChatPage(peer: _bob, chat: chat, profile: profile),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ChatComposer.replyBarKey), findsOneWidget);
      expect(find.text('回复 bob'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(ChatComposer.inputKey))
            .controller!
            .text,
        '收到马上看',
      );
      expect(find.byKey(ChatPage.alertJumpKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
