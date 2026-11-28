import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/group_models.dart';
import 'package:bb_client/models/mention_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_mention_controller.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:bb_client/ui/chat/chat_drafts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final String _groupA = 'group:${'a1b2c3d4' * 4}';
final String _groupB = 'group:${'b2c3d4e5' * 4}';
const AuthUser _alice = AuthUser(account: '10000001', username: 'Alice');
const AuthUser _carol = AuthUser(account: '10000009', username: 'Carol');

GroupMember _member(String account, String username) => GroupMember(
  account: account,
  username: username,
  avatarUrl: '',
  avatarVersion: 'v0',
  presence: Presence.online,
  role: GroupRole.member,
);

ChatMessage _groupMsg({
  required String id,
  required int position,
  required String senderAccount,
  required String text,
  String? conversationId,
}) {
  return ChatMessage(
    id: id,
    position: position,
    senderAccount: senderAccount,
    senderUsername: 'Member',
    conversation: ConversationRef.group(conversationId ?? _groupA),
    createdAt: DateTime.utc(2026, 11, 28, 15, position),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[TextPart(text)],
  );
}

class _FakeAlertServer {
  _FakeAlertServer._(this._server);

  final HttpServer _server;
  final List<List<String>> markSeenCalls = <List<String>>[];
  final List<Map<String, dynamic>> listCalls = <Map<String, dynamic>>[];
  final List<String> contextCalls = <String>[];

  /// Ordered newest -> oldest for [_groupA].
  final List<Map<String, dynamic>> unreadInGroupA = <Map<String, dynamic>>[
    <String, dynamic>{
      'message_id': 'msg-30',
      'position': 30,
      'mention': true,
      'reply': true,
    },
    <String, dynamic>{
      'message_id': 'msg-20',
      'position': 20,
      'mention': true,
      'reply': false,
    },
    <String, dynamic>{
      'message_id': 'msg-10',
      'position': 10,
      'mention': true,
      'reply': false,
    },
  ];

  bool failContextForOld = false;
  bool groupBHasAlert = true;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_FakeAlertServer> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeAlertServer instance = _FakeAlertServer._(server);
    server.listen(instance._handle);
    return instance;
  }

  Future<void> close() => _server.close(force: true);

  int get _mentionCountA => unreadInGroupA
      .where((Map<String, dynamic> item) => item['mention'] == true)
      .length;

  int get _replyCountA => unreadInGroupA
      .where((Map<String, dynamic> item) => item['reply'] == true)
      .length;

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    final String bodyText = await utf8.decodeStream(request);
    final Map<String, dynamic> body = bodyText.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(bodyText) as Map<String, dynamic>;

    if (request.method == 'POST' && path == '/chat/alerts/summary') {
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
        if (unreadInGroupA.isNotEmpty)
          <String, dynamic>{
            'conversation_id': _groupA,
            'display_name': 'A群',
            'unread_mention_count': _mentionCountA,
            'unread_reply_count': _replyCountA,
            'latest_alert': unreadInGroupA.first,
          },
        if (groupBHasAlert)
          <String, dynamic>{
            'conversation_id': _groupB,
            'display_name': 'B群',
            'unread_mention_count': 1,
            'unread_reply_count': 0,
            'latest_alert': <String, dynamic>{
              'message_id': 'msg-b1',
              'position': 5,
              'mention': true,
              'reply': false,
            },
          },
      ];
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{'items': items, 'next_cursor': null}),
        );
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && path == '/chat/alerts/list') {
      listCalls.add(body);
      final int? before = body['before_position'] as int?;
      final int limit = (body['limit'] as int?) ?? 50;
      final List<Map<String, dynamic>> filtered = unreadInGroupA
          .where(
            (Map<String, dynamic> item) =>
                before == null || (item['position'] as int) < before,
          )
          .toList();
      final List<Map<String, dynamic>> page = filtered.take(limit).toList();
      final int? nextCursor = filtered.length > limit
          ? page.last['position'] as int
          : null;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'items': page,
            'next_cursor': nextCursor,
          }),
        );
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && path == '/chat/alerts/mark_seen') {
      final List<String> ids = List<String>.from(body['message_ids'] as List);
      markSeenCalls.add(ids);
      unreadInGroupA.removeWhere(
        (Map<String, dynamic> item) => ids.contains(item['message_id']),
      );
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'unread_mention_count': _mentionCountA,
            'unread_reply_count': _replyCountA,
          }),
        );
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && path == '/messages/msg-10/context') {
      contextCalls.add('msg-10');
      if (failContextForOld) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'msg-10',
                'position': 10,
                'sender_account': '10000002',
                'sender_username': 'Bob',
                'conversation': <String, dynamic>{
                  'type': 'group',
                  'id': _groupA,
                },
                'created_at': '2026-11-28T15:10:00Z',
                'kind': 'body',
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{'type': 'text', 'text': '@Alice old'},
                ],
              },
            ],
            'anchor_message_id': 'msg-10',
            'conversation': <String, dynamic>{'type': 'group', 'id': _groupA},
            'range': <String, dynamic>{
              'start_position': 10,
              'end_position': 10,
            },
            'before_has_more': true,
            'after_has_more': true,
            'missing_positions': <int>[],
            'missing_truncated': false,
            'reply_relations': 'none',
          }),
        );
      await request.response.close();
      return;
    }

    request.response.statusCode = 404;
    await request.response.close();
  }
}

void main() {
  group('GroupMentionComposerController', () {
    test('fuzzy subsequence matching, duplicate-name binding, deduplication, and plain text rejection', () {
      final GroupMentionComposerController controller =
          GroupMentionComposerController();
      final GroupMember xingyi = _member('10000002', '星与星依');
      final GroupMember zhangsan1 = _member('10000003', '张三');
      final GroupMember zhangsan2 = _member('10000004', '张三');
      final GroupMember bob = _member('10000005', 'Bob');
      controller.setMembers(<GroupMember>[xingyi, zhangsan1, zhangsan2, bob]);

      // 1. Typing `@星依` matches `星与星依` via fuzzy subsequence.
      const TextEditingValue initial = TextEditingValue.empty;
      const TextEditingValue typedSubseq = TextEditingValue(
        text: 'hello @星依',
        selection: TextSelection.collapsed(offset: 9),
      );
      controller.handleTextValueChanged(initial, typedSubseq);
      expect(controller.pickerOpen, isTrue);
      expect(controller.candidates.map((GroupMember m) => m.account), <String>[
        '10000002',
      ]);

      // Selecting inserts `@星与星依 ` at original cursor and binds `10000002`.
      final TextEditingValue afterFirst = controller.selectMember(
        xingyi,
        typedSubseq,
      );
      expect(afterFirst.text, 'hello @星与星依 ');
      expect(afterFirst.selection.baseOffset, 12);
      expect(controller.pickerOpen, isFalse);
      expect(controller.uniqueMentionedAccounts, <String>['10000002']);

      // 2. Typing duplicate plain text `@张三 ` without selecting does NOT bind any account.
      final TextEditingValue manualPlainText = TextEditingValue(
        text: '${afterFirst.text}@张三 ',
        selection: TextSelection.collapsed(offset: afterFirst.text.length + 4),
      );
      controller.handleTextValueChanged(afterFirst, manualPlainText);
      expect(controller.uniqueMentionedAccounts, <String>['10000002']);

      // 3. Selecting the second duplicate-nickname member via ↑/↓ binds `10000004`, not `10000003`.
      final TextEditingValue queryDup = TextEditingValue(
        text: '${manualPlainText.text}@张三',
        selection: TextSelection.collapsed(
          offset: manualPlainText.text.length + 3,
        ),
      );
      controller.handleTextValueChanged(manualPlainText, queryDup);
      expect(controller.pickerOpen, isTrue);
      expect(controller.candidates.map((GroupMember m) => m.account), <String>[
        '10000003',
        '10000004',
      ]);
      controller.moveHighlightDown();
      expect(controller.highlightedCandidate?.account, '10000004');
      final TextEditingValue afterSecond = controller.selectMember(
        controller.highlightedCandidate!,
        queryDup,
      );
      expect(controller.uniqueMentionedAccounts, <String>[
        '10000002',
        '10000004',
      ]);

      // 4. Selecting the same member again deduplicates `uniqueMentionedAccounts`.
      final TextEditingValue queryAgain = TextEditingValue(
        text: '${afterSecond.text}@星',
        selection: TextSelection.collapsed(offset: afterSecond.text.length + 2),
      );
      controller.handleTextValueChanged(afterSecond, queryAgain);
      final TextEditingValue afterDupSelect = controller.selectMember(
        xingyi,
        queryAgain,
      );
      expect(controller.spans, hasLength(3));
      expect(controller.uniqueMentionedAccounts, <String>[
        '10000002',
        '10000004',
      ]);

      // 5. Esc dismisses picker without losing draft text or bound spans.
      final TextEditingValue queryEsc = TextEditingValue(
        text: '${afterDupSelect.text}@Bob',
        selection: TextSelection.collapsed(
          offset: afterDupSelect.text.length + 4,
        ),
      );
      controller.handleTextValueChanged(afterDupSelect, queryEsc);
      expect(controller.pickerOpen, isTrue);
      controller.dismissPicker();
      expect(controller.pickerOpen, isFalse);
      expect(controller.uniqueMentionedAccounts, <String>[
        '10000002',
        '10000004',
      ]);

      // 6. Editing inside a span invalidates its bound account while shifting trailing spans.
      final TextEditingValue editedFirstSpan = TextEditingValue(
        text: queryEsc.text.replaceFirst('@星与星依 ', '@星与 '),
        selection: const TextSelection.collapsed(offset: 9),
      );
      controller.handleTextValueChanged(queryEsc, editedFirstSpan);
      // Only `10000004` and the second `@星与星依 ` (`10000002`) remain, in order!
      expect(controller.spans, hasLength(2));
      expect(controller.uniqueMentionedAccounts, <String>[
        '10000004',
        '10000002',
      ]);

      // 7. Disambiguation by BB account substring works when nicknames match.
      final TextEditingValue queryByAccount = TextEditingValue(
        text: '${editedFirstSpan.text} @0004',
        selection: TextSelection.collapsed(
          offset: editedFirstSpan.text.length + 6,
        ),
      );
      controller.handleTextValueChanged(editedFirstSpan, queryByAccount);
      expect(controller.candidates.map((GroupMember m) => m.account), <String>[
        '10000004',
      ]);
    });

    test('ChatDraft preserves mentionSpans across draft restore', () {
      final Object sessionKey = Object();
      ChatDrafts.instance.resetForTest();
      const MentionSpan span = MentionSpan(
        start: 0,
        end: 6,
        account: '10000002',
        label: '@星与星依 ',
      );
      ChatDrafts.instance.write(
        sessionKey,
        _groupA,
        const ChatDraft(text: '@星与星依 看这里', mentionSpans: <MentionSpan>[span]),
      );
      final ChatDraft? restored = ChatDrafts.instance.read(sessionKey, _groupA);
      expect(restored?.mentionSpans, const <MentionSpan>[span]);

      final GroupMentionComposerController controller =
          GroupMentionComposerController();
      controller.restore(
        value: TextEditingValue(
          text: restored!.text,
          selection: TextSelection.collapsed(offset: restored.text.length),
        ),
        spans: restored.mentionSpans,
      );
      expect(controller.uniqueMentionedAccounts, const <String>['10000002']);
      ChatDrafts.instance.resetForTest();
    });
  });

  group('MentionRecipientController', () {
    test('out-of-order manual visibility + reverse jump + context fetch + failure safety', () async {
      final _FakeAlertServer server = await _FakeAlertServer.start();
      addTearDown(server.close);

      final AuthSession session = AuthSession()
        ..establish(token: 'tok-1', user: _alice);
      final ConversationAccessController access =
          ConversationAccessController();
      final SharedConversationService shared = SharedConversationService(
        api: ChatApiClient(baseUri: server.baseUri),
        session: session,
        access: access,
      );
      addTearDown(shared.dispose);

      final MentionRecipientController controller = MentionRecipientController(
        shared: shared,
      );
      addTearDown(controller.dispose);

      // 1. Summary shows 3 unread mentions and 1 reply (on msg-30) in group A.
      await controller.refreshSummary();
      expect(controller.unreadMentionCountFor(_groupA), 3);
      expect(controller.unreadReplyCountFor(_groupA), 1);
      expect(controller.unreadMentionCountFor(_groupB), 1);

      // 2. Hidden / background visibility NEVER calls mark_seen.
      final ChatMessage msg30 = _groupMsg(
        id: 'msg-30',
        position: 30,
        senderAccount: '10000002',
        text: '@Alice new',
      );
      final ChatMessage msg20 = _groupMsg(
        id: 'msg-20',
        position: 20,
        senderAccount: '10000002',
        text: '@Alice mid',
      );
      final ChatMessage msg10 = _groupMsg(
        id: 'msg-10',
        position: 10,
        senderAccount: '10000002',
        text: '@Alice old',
      );
      final ChatMessage regularMsg = _groupMsg(
        id: 'msg-31',
        position: 31,
        senderAccount: '10000002',
        text: 'regular message after mention',
      );
      await controller.reportVisibleMessages(
        conversation: ConversationRef.group(_groupA),
        visibleMessages: <ChatMessage>[msg30, msg20, regularMsg],
        isForegroundActive: false,
      );
      expect(server.markSeenCalls, isEmpty);
      expect(controller.unreadMentionCountFor(_groupA), 3);

      // 3. Manually scrolling to middle message (msg-20) in foreground marks ONLY msg-20 seen.
      final AlertCounts? afterMiddle = await controller.reportVisibleMessages(
        conversation: ConversationRef.group(_groupA),
        visibleMessages: <ChatMessage>[msg20, regularMsg],
        isForegroundActive: true,
      );
      expect(afterMiddle?.unreadMentionCount, 2);
      expect(afterMiddle?.unreadReplyCount, 1);
      expect(controller.unreadMentionCountFor(_groupA), 2);
      expect(server.markSeenCalls, <List<String>>[
        <String>['msg-20', 'msg-31'],
      ]);

      // 4. First jump picks newest remaining (msg-30, mention+reply, already loaded -> no context call).
      final AlertJumpResolution? firstJump = await controller
          .resolveNextJumpTarget(
            conversation: ConversationRef.group(_groupA),
            loadedMessageIds: const <String>{'msg-30', 'msg-31'},
          );
      expect(firstJump?.alert.messageId, 'msg-30');
      expect(firstJump?.alert.mention, isTrue);
      expect(firstJump?.alert.reply, isTrue);
      expect(firstJump?.context, isNull);
      expect(server.contextCalls, isEmpty);
      // Jumping alone does NOT mark seen until the message enters viewport.
      expect(controller.unreadMentionCountFor(_groupA), 2);

      // Now msg-30 enters viewport -> marks seen, clears BOTH mention and reply on msg-30!
      final AlertCounts? afterNewest = await controller.reportVisibleMessages(
        conversation: ConversationRef.group(_groupA),
        visibleMessages: <ChatMessage>[msg30],
        isForegroundActive: true,
      );
      expect(afterNewest?.unreadMentionCount, 1);
      expect(afterNewest?.unreadReplyCount, 0);
      expect(controller.unreadMentionCountFor(_groupA), 1);
      expect(controller.unreadReplyCountFor(_groupA), 0);

      // 5. Failed context locate for unloaded msg-10 throws and does NOT mark seen or advance cursor.
      server.failContextForOld = true;
      await expectLater(
        controller.resolveNextJumpTarget(
          conversation: ConversationRef.group(_groupA),
          loadedMessageIds: const <String>{'msg-30', 'msg-31'},
        ),
        throwsA(
          isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 404),
        ),
      );
      expect(controller.unreadMentionCountFor(_groupA), 1);

      // 6. Second jump succeeds via GET /messages/msg-10/context (skips msg-20 completely!).
      server.failContextForOld = false;
      final AlertJumpResolution? secondJump = await controller
          .resolveNextJumpTarget(
            conversation: ConversationRef.group(_groupA),
            loadedMessageIds: const <String>{'msg-30', 'msg-31'},
          );
      expect(secondJump?.alert.messageId, 'msg-10');
      expect(secondJump?.context?.anchorMessageId, 'msg-10');
      expect(server.contextCalls, <String>['msg-10', 'msg-10']);

      // 7. Viewing msg-10 clears the last unread alert in group A.
      await controller.reportVisibleMessages(
        conversation: ConversationRef.group(_groupA),
        visibleMessages: <ChatMessage>[msg10],
        isForegroundActive: true,
      );
      expect(controller.unreadMentionCountFor(_groupA), 0);
      expect(controller.hasUnreadAlerts(_groupA), isFalse);

      // 8. Group access revocation immediately drops group B state, while account switch clears all state.
      expect(controller.unreadMentionCountFor(_groupB), 1);
      await access.revoke(_alice.account, _groupB);
      expect(controller.unreadMentionCountFor(_groupB), 0);

      // Carol has unrevoked access to group B; switching to Carol drops Alice's state cleanly.
      session.establish(token: 'tok-carol', user: _carol);
      expect(controller.summaries, isEmpty);
      expect(controller.summaryLoadedOnce, isFalse);

      await controller.refreshSummary();
      expect(controller.unreadMentionCountFor(_groupB), 1);

      session.clear();
      expect(controller.summaries, isEmpty);
      expect(controller.summaryLoadedOnce, isFalse);
    });
  });
}
