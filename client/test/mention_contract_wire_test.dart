import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/mention_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/conversation_access.dart';
import 'package:bb_client/services/group_service.dart';
import 'package:flutter_test/flutter_test.dart';

final String _groupA = 'group:${'a1b2c3d4' * 4}';
final String _groupB = 'group:${'b2c3d4e5' * 4}';
const String _directAB = 'dm:10000001:10000002';
const AuthUser _alice = AuthUser(account: '10000001', username: 'Alice');

void main() {
  test('DEA-517 Rev 1 alert & mention models enforce wire schema strictly', () {
    final ClientAlertSummaryPage summaryPage = ClientAlertSummaryPage.fromJson(
      <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'conversation_id': _directAB,
            'display_name': 'Bob',
            'unread_mention_count': 0,
            'unread_reply_count': 1,
            'latest_alert': <String, dynamic>{
              'message_id': 'msg-dm-1',
              'position': 5,
              'mention': false,
              'reply': true,
            },
          },
          <String, dynamic>{
            'conversation_id': _groupA,
            'display_name': '测试群',
            'unread_mention_count': 2,
            'unread_reply_count': 1,
            'latest_alert': <String, dynamic>{
              'message_id': 'msg-grp-3',
              'position': 12,
              'mention': true,
              'reply': true,
            },
          },
        ],
        'next_cursor': _groupB,
      },
    );
    expect(summaryPage.items, hasLength(2));
    expect(summaryPage.items.first.conversation.isDirect, isTrue);
    expect(summaryPage.items.last.conversation, ConversationRef.group(_groupA));
    expect(summaryPage.items.last.latestAlert.mention, isTrue);
    expect(summaryPage.items.last.latestAlert.reply, isTrue);
    expect(summaryPage.nextCursor, _groupB);

    final AlertPage alertPage = AlertPage.fromJson(<String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'message_id': 'msg-30',
          'position': 30,
          'mention': true,
          'reply': true,
        },
      ],
      'next_cursor': 30,
    });
    expect(alertPage.items.single.messageId, 'msg-30');
    expect(alertPage.nextCursor, 30);

    final MentionPage mentionPage = MentionPage.fromJson(<String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'message_id': 'msg-30',
          'position': 30,
          'sender_account': '10000002',
          'sender_username': '星与星依',
          'created_at': '2026-11-28T15:00:00Z',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': '@Alice 你好'},
            <String, dynamic>{'type': 'image', 'media_id': 'media-1'},
          ],
        },
      ],
      'next_cursor': 30,
    });
    expect(mentionPage.items.single.content, hasLength(2));
    expect(mentionPage.items.single.content.first, isA<TextPart>());
    expect(mentionPage.items.single.content.last, isA<ImagePart>());
    expect(mentionPage.nextCursor, 30);

    expect(
      () => ClientAlertSummary.fromJson(<String, dynamic>{
        'conversation_id': 'bad-conv',
        'display_name': 'bad',
        'unread_mention_count': 1,
        'unread_reply_count': 0,
        'latest_alert': <String, dynamic>{
          'message_id': 'msg-1',
          'position': 1,
          'mention': true,
          'reply': false,
        },
      }),
      throwsFormatException,
    );
    expect(
      () => UnreadAlert.fromJson(<String, dynamic>{
        'message_id': 'msg-1',
        'position': 0,
        'mention': true,
        'reply': false,
      }),
      throwsFormatException,
    );
    expect(
      () => MentionMessage.fromJson(<String, dynamic>{
        'message_id': 'msg-1',
        'position': 1,
        'sender_account': '10000002',
        'sender_username': 'Bob',
        'created_at': '2026-11-28T15:00:00Z',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': ''},
        ],
      }),
      throwsFormatException,
    );
    final AlertCounts zeroCounts = AlertCounts.fromJson(<String, dynamic>{
      'unread_mention_count': 0,
      'unread_reply_count': 0,
    });
    expect(zeroCounts.hasAny, isFalse);
  });

  test(
    'client enforces SendMessage mentioned_accounts validation locally',
    () async {
      final ChatApiClient api = ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:1'),
      );
      await expectLater(
        api.sendConversationMessage(
          token: 'tok',
          conversation: ConversationRef.direct('10000001', '10000002'),
          clientNonce: 'nonce-1',
          content: const <MessagePart>[TextPart('hi')],
          mentionedAccounts: const <String>['10000002'],
        ),
        throwsA(
          isA<AuthFailure>().having(
            (AuthFailure f) => f.code,
            'code',
            'validation_error',
          ),
        ),
      );
      await expectLater(
        api.sendConversationMessage(
          token: 'tok',
          conversation: ConversationRef.group(_groupA),
          clientNonce: 'nonce-2',
          content: const <MessagePart>[TextPart('hi')],
          mentionedAccounts: const <String>['10000002', '10000002'],
        ),
        throwsA(
          isA<AuthFailure>().having(
            (AuthFailure f) => f.code,
            'code',
            'validation_error',
          ),
        ),
      );
      await expectLater(
        api.sendConversationMessage(
          token: 'tok',
          conversation: ConversationRef.group(_groupA),
          clientNonce: 'nonce-3',
          content: const <MessagePart>[TextPart('hi')],
          mentionedAccounts: <String>[
            for (int i = 0; i < 101; i += 1) '${10000000 + i}',
          ],
        ),
        throwsA(
          isA<AuthFailure>().having(
            (AuthFailure f) => f.code,
            'code',
            'validation_error',
          ),
        ),
      );
    },
  );

  test('send retries preserve client_nonce + mentioned_accounts and detect conflicts', () async {
    final List<Map<String, dynamic>> receivedMessages =
        <Map<String, dynamic>>[];
    int messageAttempts = 0;
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      final String bodyText = await utf8.decodeStream(request);
      final Map<String, dynamic> body = bodyText.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(bodyText) as Map<String, dynamic>;

      if (request.method == 'GET' && path == '/chat/conversations') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'items': <Map<String, dynamic>>[
                <String, dynamic>{
                  'conversation': <String, dynamic>{
                    'type': 'group',
                    'id': _groupA,
                  },
                  'group_number': '20000001',
                  'display_name': '测试群',
                  'last_message': null,
                  'last_activity_at': '2026-11-28T15:00:00Z',
                  'latest_position': 1,
                  'history_through': 0,
                  'membership_revision': 1,
                  'avatar_url': '',
                  'avatar_version': 'gv0',
                },
              ],
              'next_cursor': null,
            }),
          );
        await request.response.close();
        return;
      }

      if (request.method == 'POST' && path == '/messages') {
        if (body['reply_to_message_id'] == 'outside-group') {
          request.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': {'code': 'not_found', 'message': 'not found', 'fields': []},
            }));
          await request.response.close();
          return;
        }
        messageAttempts += 1;
        receivedMessages.add(body);
        if (messageAttempts == 1) {
          request.response
            ..statusCode = 500
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode(<String, dynamic>{
                'error': <String, dynamic>{
                  'code': 'upstream_unavailable',
                  'message': 'transient failure',
                },
              }),
            );
          await request.response.close();
          return;
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'id': 'msg-101',
              'position': 2,
              'sender_account': _alice.account,
              'sender_username': _alice.username,
              'conversation': <String, dynamic>{'type': 'group', 'id': _groupA},
              'created_at': '2026-11-28T15:01:00Z',
              'kind': 'body',
              'content': body['content'],
              if (body['reply_to_message_id'] case final String quoted)
                'reply_to': <String, dynamic>{
                  'message_id': quoted,
                  'sender_account': '10000002',
                  'sender_username': 'Bob',
                  'preview': 'Original',
                },
            }),
          );
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path == '/chat/conversations/$_groupA/messages') {
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'items': [], 'next_position': 0, 'has_more': false}));
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    });

    final Uri baseUri = Uri.parse('http://127.0.0.1:${server.port}');
    final AuthSession session = AuthSession()
      ..establish(token: 'tok-1', user: _alice);
    final ChatApiClient api = ChatApiClient(baseUri: baseUri);
    final ConversationAccessController access = ConversationAccessController();
    final SharedConversationService shared = SharedConversationService(
      api: api,
      session: session,
      access: access,
    );
    addTearDown(shared.dispose);

    // 1. SharedConversationService.sendGroupBodyOutcome preserves mentionedAccounts for retry.
    final SendOutcome firstFailure = await shared.sendGroupBodyOutcome(
      conversation: ConversationRef.group(_groupA),
      content: const <OutgoingPart>[OutgoingText('@Bob hi')],
      mentionedAccounts: const <String>['10000002'],
      operationId: 'op-retry-1',
    );
    expect(firstFailure.succeeded, isFalse);
    expect(firstFailure.mentionedAccounts, const <String>['10000002']);

    final SendOutcome retrySuccess = await shared.sendGroupBodyOutcome(
      conversation: ConversationRef.group(_groupA),
      content: firstFailure.part!,
      mentionedAccounts: firstFailure.mentionedAccounts,
      operationId: firstFailure.operationId,
    );
    expect(retrySuccess.succeeded, isTrue);
    expect(receivedMessages, hasLength(2));
    expect(receivedMessages[0]['client_nonce'], 'op-retry-1');
    expect(receivedMessages[0]['mentioned_accounts'], const <String>[
      '10000002',
    ]);
    expect(receivedMessages[1]['client_nonce'], 'op-retry-1');
    expect(receivedMessages[1]['mentioned_accounts'], const <String>[
      '10000002',
    ]);
    final SendOutcome badQuote = await shared.sendGroupBodyOutcome(
      conversation: ConversationRef.group(_groupA),
      content: const <OutgoingPart>[OutgoingText('Invalid quote')],
      replyToMessageId: 'outside-group',
      operationId: 'op-invalid-quote',
    );
    expect(badQuote.failure?.code, 'not_found');
    expect(access.isRevoked(_alice.account, _groupA), isFalse);

    // 2. ChatService.sendBody records mentionedAccounts in ChatLedger and rejects mismatched retry.
    final Directory cacheDir = await Directory.systemTemp.createTemp(
      'bb_mention_cache_',
    );
    addTearDown(() => cacheDir.delete(recursive: true));
    final ChatLedger ledger = ChatLedger.inMemory();
    final ChatService chat = ChatService(
      api: api,
      session: session,
      ledger: ledger,
      cacheRoot: cacheDir,
      webSocketHints: false,
    );
    addTearDown(chat.dispose);

    final SendOutcome chatSend = await chat.sendBody(
      targetAccount: _groupA,
      content: const <OutgoingPart>[OutgoingText('@Bob @Carol')],
      mentionedAccounts: const <String>['10000002', '10000003'],
      operationId: 'op-chat-1',
    );
    expect(chatSend.succeeded, isTrue);
    final ChatOperationRecord? savedRecord = await ledger.operation(
      _alice.account,
      'op-chat-1',
    );
    expect(savedRecord?.mentionedAccounts, const <String>[
      '10000002',
      '10000003',
    ]);

    final SharedConversationService durableShared = SharedConversationService(
      api: api,
      session: session,
      access: access,
      durableChat: chat,
    );
    addTearDown(durableShared.dispose);
    final int sendsBeforeReplay = receivedMessages.length;
    final SendOutcome replay = await durableShared.sendGroupBodyOutcome(
      conversation: ConversationRef.group(_groupA),
      content: const <OutgoingPart>[OutgoingText('@Bob @Carol')],
      mentionedAccounts: const <String>['10000003', '10000002'],
      operationId: 'op-chat-1',
    );
    expect(replay.message?.id, chatSend.message?.id);
    expect(receivedMessages, hasLength(sendsBeforeReplay));

    final SendOutcome mixed = await durableShared.sendGroupBodyOutcome(
      conversation: ConversationRef.group(_groupA),
      content: const <OutgoingPart>[OutgoingText('Quoted @Bob')],
      mentionedAccounts: const <String>['10000002'],
      replyToMessageId: 'group-original',
      operationId: 'op-mixed',
    );
    expect(mixed.message?.replyTo?.messageId, 'group-original');
    expect(receivedMessages.last['mentioned_accounts'], ['10000002']);
    expect(receivedMessages.last['reply_to_message_id'], 'group-original');
    final ChatOperationRecord? mixedRecord = await ledger.operation(
      _alice.account,
      'op-mixed',
    );
    expect(mixedRecord?.replyToMessageId, 'group-original');
    expect(mixedRecord?.mentionedAccounts, ['10000002']);

    await expectLater(
      chat.sendBody(
        targetAccount: _groupA,
        content: const <OutgoingPart>[OutgoingText('@Bob @Carol')],
        mentionedAccounts: const <String>['10000002'],
        operationId: 'op-chat-1',
      ),
      throwsA(
        isA<AuthFailure>().having(
          (AuthFailure f) => f.code,
          'code',
          'conflict',
        ),
      ),
    );
  });

  test('SharedConversationService alert summary, list, mentions detail, chunked mark_seen, and context', () async {
    final List<List<String>> seenBatches = <List<String>>[];
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));

    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      final String bodyText = await utf8.decodeStream(request);
      final Map<String, dynamic> body = bodyText.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(bodyText) as Map<String, dynamic>;

      if (request.method == 'POST' && path == '/chat/alerts/summary') {
        final String? after = body['after_conversation_id'] as String?;
        final Map<String, dynamic> payload = after == null
            ? <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'conversation_id': _groupA,
                    'display_name': 'A群',
                    'unread_mention_count': 2,
                    'unread_reply_count': 0,
                    'latest_alert': <String, dynamic>{
                      'message_id': 'msg-2',
                      'position': 2,
                      'mention': true,
                      'reply': false,
                    },
                  },
                ],
                'next_cursor': _groupA,
              }
            : <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'conversation_id': _groupB,
                    'display_name': 'B群',
                    'unread_mention_count': 1,
                    'unread_reply_count': 1,
                    'latest_alert': <String, dynamic>{
                      'message_id': 'msg-9',
                      'position': 9,
                      'mention': true,
                      'reply': true,
                    },
                  },
                ],
                'next_cursor': null,
              };
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(payload));
        await request.response.close();
        return;
      }

      if (request.method == 'POST' && path == '/chat/mentions/list') {
        if (body['conversation_id'] == _groupB) {
          request.response
            ..statusCode = 404
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode(<String, dynamic>{
                'error': <String, dynamic>{
                  'code': 'not_found',
                  'message': 'not a member',
                },
              }),
            );
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
                  'message_id': 'msg-10',
                  'position': 10,
                  'sender_account': '10000002',
                  'sender_username': 'Bob',
                  'created_at': '2026-11-28T15:00:00Z',
                  'content': <Map<String, dynamic>>[
                    <String, dynamic>{'type': 'text', 'text': '@Alice hi'},
                  ],
                },
              ],
              'next_cursor': null,
            }),
          );
        await request.response.close();
        return;
      }

      if (request.method == 'POST' && path == '/chat/alerts/mark_seen') {
        final List<String> ids = List<String>.from(body['message_ids'] as List);
        seenBatches.add(ids);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'unread_mention_count': seenBatches.length == 1 ? 5 : 0,
              'unread_reply_count': 0,
            }),
          );
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && path == '/messages/msg-10/context') {
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
                  'created_at': '2026-11-28T15:00:00Z',
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

      if (request.method == 'GET' && path == '/messages/msg-missing/context') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }

      if (request.method == 'POST' && path == '/chat/alerts/list') {
        request.response
          ..statusCode = 404
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 'not_found',
                'message': 'not a member',
              },
            }),
          );
        await request.response.close();
        return;
      }

      request.response.statusCode = 404;
      await request.response.close();
    });

    final AuthSession session = AuthSession()
      ..establish(token: 'tok-1', user: _alice);
    final ChatApiClient api = ChatApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final ConversationAccessController access = ConversationAccessController();
    final SharedConversationService shared = SharedConversationService(
      api: api,
      session: session,
      access: access,
    );
    addTearDown(shared.dispose);

    final List<ClientAlertSummary> all = await shared.listAllAlertSummaries();
    expect(all.map((ClientAlertSummary s) => s.conversationId), <String>[
      _groupA,
      _groupB,
    ]);

    final MentionPage mentions = await shared.listGroupMentions(
      conversation: ConversationRef.group(_groupA),
    );
    expect(mentions.items.single.messageId, 'msg-10');

    // 105 unique IDs + 1 duplicate -> 2 chunks (100 + 5).
    final List<String> ids = <String>[
      for (int i = 0; i < 105; i += 1) 'msg-$i',
      'msg-0',
    ];
    final AlertCounts counts = await shared.markConversationAlertsSeen(
      conversation: ConversationRef.group(_groupA),
      messageIds: ids,
    );
    expect(seenBatches, hasLength(2));
    expect(seenBatches[0], hasLength(100));
    expect(seenBatches[1], hasLength(5));
    expect(counts.hasAny, isFalse);

    // 404 on messageContext returns null without revoking group access.
    expect(
      await shared.loadMessageContext(
        conversation: ConversationRef.group(_groupA),
        messageId: 'msg-missing',
      ),
      isNull,
    );
    expect(access.isRevoked(_alice.account, _groupA), isFalse);

    final MessageContextRecord? ctx = await shared.loadMessageContext(
      conversation: ConversationRef.group(_groupA),
      messageId: 'msg-10',
    );
    expect(ctx?.anchorMessageId, 'msg-10');

    // 404 on group alerts endpoint revokes access for that group.
    await expectLater(
      shared.listConversationAlerts(
        conversation: ConversationRef.group(_groupB),
      ),
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 404),
      ),
    );
    expect(access.isRevoked(_alice.account, _groupB), isTrue);
  });
}
