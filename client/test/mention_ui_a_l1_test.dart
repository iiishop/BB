import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/models/mention_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_api_client.dart';
import 'package:bb_client/services/group_mention_controller.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_drafts.dart';
import 'package:bb_client/ui/chat/chat_page.dart';
import 'package:bb_client/ui/chat/clipboard_paste.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:bb_client/ui/chat/mention_widgets.dart';
import 'package:bb_client/ui/chat/users_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_profile_gateway.dart';

const AuthUser _alice = AuthUser(account: '10000001', username: 'Alice');
final String _groupA = 'group:${'a1b2c3d4' * 4}';
const String _directCarol = 'dm:10000001:10000009';

final GroupConversationItem _groupItem = GroupConversationItem(
  conversation: ConversationRef.group(_groupA),
  groupNumber: '882301',
  displayName: '星海夜航',
  lastMessage: null,
  avatarUrl: '',
  avatarVersion: 'v1',
  latestPosition: 40,
  historyThrough: 0,
  membershipRevision: 1,
  lastActivityAt: DateTime.utc(2026, 11, 28, 16, 0),
);

final List<GroupMember> _groupMembers = <GroupMember>[
  const GroupMember(
    account: '10000001',
    username: 'Alice',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.owner,
  ),
  const GroupMember(
    account: '10000002',
    username: '星与星依',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.member,
  ),
  const GroupMember(
    account: '10000003',
    username: '张三',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.online,
    role: GroupRole.member,
  ),
  const GroupMember(
    account: '10000004',
    username: '张三',
    avatarUrl: '',
    avatarVersion: 'v1',
    presence: Presence.offline,
    role: GroupRole.member,
  ),
];

class _ImageClipboard implements ClipboardMediaReader {
  @override
  Future<ClipboardPaste> read() async => ClipboardPaste(
    files: <PickedMedia>[
      PickedMedia(
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWGsAAAAASUVORK5CYII=',
        ),
        filename: 'test.png',
        mimeType: 'image/png',
      ),
    ],
  );
}

class _MentionUiBackendState {
  final List<Map<String, dynamic>> sentMessages = <Map<String, dynamic>>[];
  final List<List<String>> markSeenCalls = <List<String>>[];
  bool failOldContext = false;
  bool directReplyUnread = true;

  late final List<ChatMessage> allGroupMessages = List<ChatMessage>.generate(
    40,
    (int i) {
      final int pos = i + 1;
      return ChatMessage(
        id: 'msg-$pos',
        position: pos,
        senderAccount: '10000002',
        senderUsername: '星与星依',
        conversation: ConversationRef.group(_groupA),
        createdAt: DateTime.utc(2026, 11, 28, 15, pos),
        kind: ChatMessageKind.body,
        parts: <MessagePart>[
          TextPart(
            pos == 2
                ? '@Alice 最早一条提及消息'
                : pos == 12
                ? '@Alice 中间一条仅提及消息'
                : pos == 22
                ? '@Alice 最新一条既回复又提及\n多行内容用于确保单独定位到可视区\n第三行高度撑开'
                : '第 $pos 条普通消息内容用于撑开列表高度\n补充行以确保不在同一屏幕',
          ),
        ],
      );
    },
  );

  final List<Map<String, dynamic>> unreadGroupA = <Map<String, dynamic>>[
    <String, dynamic>{
      'message_id': 'msg-22',
      'position': 22,
      'mention': true,
      'reply': true,
    },
    <String, dynamic>{
      'message_id': 'msg-12',
      'position': 12,
      'mention': true,
      'reply': false,
    },
    <String, dynamic>{
      'message_id': 'msg-2',
      'position': 2,
      'mention': true,
      'reply': false,
    },
  ];

  int get groupMentionCount => unreadGroupA
      .where((Map<String, dynamic> e) => e['mention'] == true)
      .length;

  int get groupReplyCount =>
      unreadGroupA.where((Map<String, dynamic> e) => e['reply'] == true).length;
}

class _FakeChatApiClient extends ChatApiClient {
  _FakeChatApiClient(this.state)
    : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final _MentionUiBackendState state;

  @override
  Future<UserPage> listUsers({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    return UserPage(
      items: <ChatUser>[
        ChatUser(
          account: '10000009',
          username: '林小满',
          avatarUrl: '',
          avatarVersion: 'v1',
          presence: Presence.online,
          lastContactAt: DateTime.utc(2026, 11, 28, 15, 58),
          lastMessage: UserPreview(
            id: 'dm-last-1',
            senderAccount: '10000009',
            senderUsername: '林小满',
            previewBody: '晚安。',
          ),
        ),
      ],
      nextCursor: null,
    );
  }

  @override
  Future<SharedConversationPage> sharedConversations({
    required String token,
    String afterId = '',
    int limit = 50,
  }) async {
    return SharedConversationPage(
      items: <SharedConversation>[_groupItem],
      nextCursor: null,
    );
  }

  @override
  Future<MessagePage> conversationHistory({
    required String token,
    required ConversationRef conversation,
    int? beforePosition,
    int? afterPosition,
    int limit = 100,
  }) async {
    if (afterPosition != null) {
      return MessagePage(
        items: const <ChatMessage>[],
        hasMore: false,
        nextPosition: afterPosition,
      );
    }
    return MessagePage(
      items: state.allGroupMessages.sublist(11),
      hasMore: true,
      nextPosition: 40,
    );
  }

  @override
  Future<MessageContextRecord?> messageContext({
    required String token,
    required String messageId,
    int beforeLimit = 10,
    int afterLimit = 10,
  }) async {
    if (messageId == 'msg-2' && state.failOldContext) {
      throw const AuthFailure(
        status: 404,
        code: 'not_found',
        message: '无法定位该历史消息',
      );
    }
    return MessageContextRecord(
      items: state.allGroupMessages.sublist(0, 4),
      anchorMessageId: 'msg-2',
      peerAccount: '',
      conversation: ConversationRef.group(_groupA),
      startPosition: 1,
      endPosition: 4,
      beforeHasMore: false,
      afterHasMore: true,
      missingPositions: const <int>[],
      missingTruncated: false,
      replyRelations: 'none',
    );
  }

  @override
  Future<Attachment> uploadConversationMedia({
    required String token,
    required ConversationRef conversation,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
    String? coverMediaId,
  }) async => Attachment(
    mediaId: 'img-1',
    kind: AttachmentKind.image,
    filename: filename,
    mimeType: mimeType,
    byteSize: bytes.length,
  );

  @override
  Future<ChatMessage> sendConversationMessage({
    required String token,
    required ConversationRef conversation,
    required String clientNonce,
    required List<MessagePart> content,
    List<String> mentionedAccounts = const <String>[],
  }) async {
    state.sentMessages.add(<String, dynamic>{
      'conversation_id': conversation.id,
      'client_nonce': clientNonce,
      'mentioned_accounts': mentionedAccounts,
      'content': content.map((MessagePart p) => p.toJson()).toList(),
    });
    final int pos = 40 + state.sentMessages.length;
    return ChatMessage(
      id: 'sent-$pos',
      position: pos,
      senderAccount: _alice.account,
      senderUsername: _alice.username,
      conversation: conversation,
      createdAt: DateTime.utc(2026, 11, 28, 16, 10),
      kind: ChatMessageKind.body,
      parts: content,
      operationId: clientNonce,
    );
  }

  @override
  Future<ClientAlertSummaryPage> alertSummary({
    required String token,
    String? afterConversationId,
    int limit = 50,
  }) async {
    return ClientAlertSummaryPage.fromJson(<String, dynamic>{
      'items': <Map<String, dynamic>>[
        if (state.directReplyUnread)
          <String, dynamic>{
            'conversation_id': _directCarol,
            'display_name': '林小满',
            'unread_mention_count': 0,
            'unread_reply_count': 1,
            'latest_alert': <String, dynamic>{
              'message_id': 'msg-dm-1',
              'position': 4,
              'mention': false,
              'reply': true,
            },
          },
        if (state.unreadGroupA.isNotEmpty)
          <String, dynamic>{
            'conversation_id': _groupA,
            'display_name': '星海夜航',
            'unread_mention_count': state.groupMentionCount,
            'unread_reply_count': state.groupReplyCount,
            'latest_alert': state.unreadGroupA.first,
          },
      ],
      'next_cursor': null,
    });
  }

  @override
  Future<AlertPage> listAlerts({
    required String token,
    required ConversationRef conversation,
    int? beforePosition,
    int limit = 50,
  }) async {
    final List<Map<String, dynamic>> filtered = state.unreadGroupA
        .where(
          (Map<String, dynamic> e) =>
              beforePosition == null || (e['position'] as int) < beforePosition,
        )
        .toList(growable: false);
    final List<Map<String, dynamic>> page = filtered.take(limit).toList();
    final int? nextCursor = filtered.length > limit
        ? page.last['position'] as int
        : null;
    return AlertPage.fromJson(<String, dynamic>{
      'items': page,
      'next_cursor': nextCursor,
    });
  }

  @override
  Future<AlertCounts> markAlertsSeen({
    required String token,
    required ConversationRef conversation,
    required List<String> messageIds,
  }) async {
    state.markSeenCalls.add(messageIds);
    state.unreadGroupA.removeWhere(
      (Map<String, dynamic> item) => messageIds.contains(item['message_id']),
    );
    return AlertCounts(
      unreadMentionCount: state.groupMentionCount,
      unreadReplyCount: state.groupReplyCount,
    );
  }

  @override
  Future<ConversationRecordPage> conversations({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    return const ConversationRecordPage(
      items: <ConversationRecord>[],
      nextCursor: null,
    );
  }
}

class _FakeGroupApiClient extends GroupApiClient {
  _FakeGroupApiClient() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  @override
  Future<GroupMemberPage> listGroupMembers({
    required String token,
    required ConversationRef conversation,
    String afterAccount = '',
    int limit = 50,
    bool includeCounts = false,
  }) async {
    return GroupMemberPage(
      items: _groupMembers,
      counts: includeCounts
          ? const GroupMemberCounts(online: 3, total: 4)
          : null,
    );
  }

  @override
  Future<GroupProfile> findGroup({
    required String token,
    required String groupNumber,
  }) async {
    return GroupProfile(
      groupNumber: '882301',
      conversation: ConversationRef.group(_groupA),
      name: '星海夜航',
      description: '',
      avatarUrl: '',
      avatarVersion: 'v1',
      status: GroupStatus.active,
      role: GroupRole.owner,
    );
  }
}

({
  _MentionUiBackendState backend,
  SharedConversationService shared,
  ChatService chat,
  GroupService groups,
  MentionRecipientController alerts,
})
_buildServices() {
  final _MentionUiBackendState backend = _MentionUiBackendState();
  final AuthSession session = AuthSession()
    ..establish(token: 'tok-alice', user: _alice);
  final _FakeChatApiClient api = _FakeChatApiClient(backend);
  final ConversationAccessController access = ConversationAccessController();
  final Directory cacheDir = Directory.systemTemp.createTempSync(
    'bb_mention_ui_',
  );
  addTearDown(() => cacheDir.deleteSync(recursive: true));
  final SharedConversationService shared = SharedConversationService(
    api: api,
    session: session,
    access: access,
  );
  final ChatService chat = ChatService(
    api: api,
    session: session,
    ledger: ChatLedger.inMemory(),
    cacheRoot: cacheDir,
    webSocketHints: false,
  );
  final GroupService groups = GroupService(
    api: _FakeGroupApiClient(),
    session: session,
    access: access,
  );
  final MentionRecipientController alerts = MentionRecipientController(
    shared: shared,
  );
  addTearDown(alerts.dispose);
  addTearDown(shared.dispose);
  addTearDown(chat.dispose);
  return (
    backend: backend,
    shared: shared,
    chat: chat,
    groups: groups,
    alerts: alerts,
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  final String? directory = Platform.environment['QA_MENTION_SCREENSHOT_DIR'];
  if (directory == null) {
    return;
  }
  final RenderView view = tester.binding.renderViews.single;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final ui.Image image = await layer.toImage(Offset.zero & view.size);
    try {
      final ByteData png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      File('$directory/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (Platform.environment['QA_MENTION_SCREENSHOT_DIR'] == null) {
      return;
    }
    final String? fontPath = Platform.environment['QA_CJK_FONT'];
    final String? iconPath = Platform.environment['QA_ICON_FONT'];
    if (fontPath != null) {
      final Uint8List bytes = File(fontPath).readAsBytesSync();
      for (final String family in <String>['Roboto', 'Ahem']) {
        await (FontLoader(
          family,
        )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();
      }
    }
    if (iconPath != null) {
      final Uint8List bytes = File(iconPath).readAsBytesSync();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();
    }
  });
  setUp(() {
    ChatDrafts.instance.resetForTest();
  });

  tearDown(() {
    ChatDrafts.instance.resetForTest();
  });

  group('DEA-518 A + L1 UI', () {
    testWidgets(
      'desktop Option A keyboard ↑/↓/Enter/Esc, cursor insertion, duplicate-name binding, and Esc plain @ rejection',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1440, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final svc = _buildServices();

        Widget composer() => MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const Spacer(),
                ChatComposer(
                  chat: svc.chat,
                  peerAccount: '',
                  conversation: _groupItem.conversation,
                  shared: svc.shared,
                  groups: svc.groups,
                  profile: FakeProfileGateway(),
                  clipboard: _ImageClipboard(),
                  onSent: (_, _) {},
                ),
              ],
            ),
          ),
        );
        await tester.pumpWidget(composer());
        await tester.pumpAndSettle();

        final Finder inputFinder = find.byKey(ChatComposer.inputKey);
        await tester.tap(inputFinder);
        await tester.pump();

        // 1. Insert `@星依` in the middle of an existing draft -> fuzzy matches `星与星依`.
        final EditableTextState editable = tester.state<EditableTextState>(
          find.descendant(of: inputFinder, matching: find.byType(EditableText)),
        );
        editable.userUpdateTextEditingValue(
          const TextEditingValue(
            text: '今晚@星依 一起看',
            selection: TextSelection.collapsed(offset: 5),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(MentionMemberPickerOverlay.panelKey), findsOneWidget);
        expect(
          find.byKey(MentionMemberPickerOverlay.rowKey('10000002')),
          findsOneWidget,
        );
        expect(find.textContaining('BB号 10000002'), findsOneWidget);
        await _capture(tester, 'dea517-desktop-A-picker');

        // Enter inserts bound token at original cursor WITHOUT sending.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(svc.backend.sentMessages, isEmpty);
        expect(find.byKey(MentionMemberPickerOverlay.panelKey), findsNothing);
        expect(editable.textEditingValue.text, '今晚@星与星依  一起看');

        // Committing an IME edit before the existing token must rebase it.
        final TextEditingValue composing = TextEditingValue(
          text: '明${editable.textEditingValue.text}',
          selection: const TextSelection.collapsed(offset: 1),
          composing: const TextRange(start: 0, end: 1),
        );
        editable.userUpdateTextEditingValue(
          composing,
          SelectionChangedCause.keyboard,
        );
        editable.userUpdateTextEditingValue(
          composing.copyWith(composing: TextRange.empty),
          SelectionChangedCause.keyboard,
        );
        await tester.pumpAndSettle();

        // 2. Duplicate-name selection via ↓ chooses the second 张三 (10000004).
        final String withSecondTrigger = '${editable.textEditingValue.text}@张三';
        editable.userUpdateTextEditingValue(
          TextEditingValue(
            text: withSecondTrigger,
            selection: TextSelection.collapsed(
              offset: withSecondTrigger.length,
            ),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(MentionMemberPickerOverlay.rowKey('10000003')),
          findsOneWidget,
        );
        expect(
          find.byKey(MentionMemberPickerOverlay.rowKey('10000004')),
          findsOneWidget,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(svc.backend.sentMessages, isEmpty);

        // 3. Esc dismissal keeps typed plain text `@星依` without binding its account.
        final String withPlainAt = '${editable.textEditingValue.text}@星依';
        editable.userUpdateTextEditingValue(
          TextEditingValue(
            text: withPlainAt,
            selection: TextSelection.collapsed(offset: withPlainAt.length),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(MentionMemberPickerOverlay.panelKey), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(MentionMemberPickerOverlay.panelKey), findsNothing);

        // Paste an image to stage the text, then leave and resume the draft.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(editable.textEditingValue.text, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(composer());
        await tester.pumpAndSettle();

        // The resumed text and image retain both bound accounts.
        await tester.tap(find.byKey(ChatComposer.sendKey));
        await tester.pumpAndSettle();
        expect(svc.backend.sentMessages, hasLength(1));
        expect(svc.backend.sentMessages.single['mentioned_accounts'], <String>[
          '10000002',
          '10000004',
        ]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'phone half-sheet search filters candidates and inserts selected member into composer',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(390, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final svc = _buildServices();

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  const Spacer(),
                  ChatComposer(
                    chat: svc.chat,
                    peerAccount: '',
                    conversation: _groupItem.conversation,
                    shared: svc.shared,
                    groups: svc.groups,
                    profile: FakeProfileGateway(),
                    onSent: (_, _) {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final Finder inputFinder = find.byKey(ChatComposer.inputKey);
        await tester.tap(inputFinder);
        await tester.pump();
        final EditableTextState editable = tester.state<EditableTextState>(
          find.descendant(of: inputFinder, matching: find.byType(EditableText)),
        );
        editable.userUpdateTextEditingValue(
          const TextEditingValue(
            text: '请 @',
            selection: TextSelection.collapsed(offset: 3),
          ),
          SelectionChangedCause.keyboard,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('mention-mobile-sheet')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('mention-mobile-sheet-search')),
          '10000004',
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('mention-sheet-candidate-10000004')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('mention-sheet-candidate-10000003')),
          findsNothing,
        );

        await _capture(tester, 'dea517-phone-member-sheet');
        await tester.tap(
          find.byKey(const Key('mention-sheet-candidate-10000004')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('mention-mobile-sheet')), findsNothing);
        expect(editable.textEditingValue.text, '请 @张三 ');
        await tester.tap(find.byKey(ChatComposer.sendKey));
        await tester.pumpAndSettle();
        expect(svc.backend.sentMessages.single['mentioned_accounts'], <String>[
          '10000004',
        ]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'L1 conversation list keeps single-line combined pill on narrow phone without wrapping or overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final svc = _buildServices();

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
              child: Scaffold(
                body: UsersListView(
                  chat: svc.chat,
                  profile: FakeProfileGateway(),
                  shared: svc.shared,
                  groups: svc.groups,
                  alerts: svc.alerts,
                  onOpenChat: (_) async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final Finder groupMixed = find.byKey(
          ConversationAlertNote.mixedKey(_groupA),
        );
        final Finder directReply = find.byKey(
          ConversationAlertNote.replyKey(_directCarol),
        );
        expect(groupMixed, findsOneWidget);
        expect(directReply, findsOneWidget);
        expect(tester.getSize(groupMixed).height, lessThan(36));
        expect(find.textContaining('回复你'), findsWidgets);
        await _capture(tester, 'dea517-phone-L1-conversations');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'floating jump button reflects latest alert type, honors foreground viewport only, fetches context on jump, and preserves errors',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1440, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final svc = _buildServices();
        await svc.alerts.refreshSummary();

        // Mount initially inactive -> off-screen / hidden tab must NOT clear alerts.
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ChatPage(
              group: _groupItem,
              chat: svc.chat,
              profile: FakeProfileGateway(),
              shared: svc.shared,
              groups: svc.groups,
              alerts: svc.alerts,
              active: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(svc.backend.markSeenCalls, isEmpty);

        // Activate foreground -> bottom window has no alerts, so msg-22/12/2 stay unread.
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ChatPage(
              group: _groupItem,
              chat: svc.chat,
              profile: FakeProfileGateway(),
              shared: svc.shared,
              groups: svc.groups,
              alerts: svc.alerts,
              active: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Bottom messages entered foreground viewport, but off-screen msg-22/12/2 were never marked seen!
        for (final List<String> batch in svc.backend.markSeenCalls) {
          expect(
            batch,
            everyElement(isNot(anyOf('msg-22', 'msg-12', 'msg-2'))),
          );
        }
        expect(svc.alerts.unreadMentionCountFor(_groupA), 3);
        expect(svc.alerts.unreadReplyCountFor(_groupA), 1);
        expect(find.byKey(FloatingAlertJumpButton.buttonKey), findsOneWidget);
        expect(find.text('跳到回复 + @'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(FloatingAlertJumpButton.countKey),
            matching: find.text('3'),
          ),
          findsOneWidget,
        );

        await _capture(tester, 'dea517-desktop-mixed-jump');

        // Jump 1 -> scrolls to msg-22 -> visible in foreground -> clears BOTH mention+reply on msg-22.
        await tester.tap(find.byKey(FloatingAlertJumpButton.buttonKey));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(svc.alerts.unreadMentionCountFor(_groupA), 2);
        expect(svc.alerts.unreadReplyCountFor(_groupA), 0);
        expect(find.text('跳到 @'), findsOneWidget);

        // Jump 2 -> scrolls to msg-12 -> visible -> 1 remaining (msg-2).
        await tester.tap(find.byKey(FloatingAlertJumpButton.buttonKey));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(svc.alerts.unreadMentionCountFor(_groupA), 1);

        // Jump 3 with 404 context failure -> preserves remaining alert.
        svc.backend.failOldContext = true;
        await tester.tap(find.byKey(FloatingAlertJumpButton.buttonKey));
        await tester.pumpAndSettle();
        expect(svc.alerts.unreadMentionCountFor(_groupA), 1);

        // Retry Jump 3 -> fetches /messages/msg-2/context, scrolls into view, clears last alert.
        svc.backend.failOldContext = false;
        await tester.tap(find.byKey(FloatingAlertJumpButton.buttonKey));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('@Alice 最早一条提及消息'), findsOneWidget);
        expect(svc.alerts.hasUnreadAlerts(_groupA), isFalse);
        expect(find.byKey(FloatingAlertJumpButton.buttonKey), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'phone floating jump button shows compact glyph and distinct corner badge',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(390, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final svc = _buildServices();
        await svc.alerts.refreshSummary();

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ChatPage(
              group: _groupItem,
              chat: svc.chat,
              profile: FakeProfileGateway(),
              shared: svc.shared,
              groups: svc.groups,
              alerts: svc.alerts,
              active: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(FloatingAlertJumpButton.buttonKey), findsOneWidget);
        final Finder jump = find.byKey(FloatingAlertJumpButton.buttonKey);
        expect(
          find.descendant(of: jump, matching: find.text('@')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: jump, matching: find.byIcon(Icons.reply_rounded)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(FloatingAlertJumpButton.countKey),
            matching: find.text('3'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
