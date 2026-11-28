import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/models/reply_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/chat_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reply quote and reply query models encode/decode per DEA-519 contract',
    () {
      final cases = jsonDecode(
        File('../server/contract/chat-v2-cases.json').readAsStringSync(),
      ) as Map<String, dynamic>;

      final unreadResult =
          (cases['outputs']['list_unread_replies']
                  as Map<String, dynamic>)['result']
              as Map<String, dynamic>;
      final unreadItem = UnreadReply.fromJson(
        (unreadResult['items'] as List<dynamic>).single,
      );
      expect(unreadItem.reply.id, 'received-reply');
      expect(unreadItem.reply.senderUsername, 'Bob');
      expect(unreadItem.reply.replyTo?.messageId, 'own-example-message');
      expect(unreadItem.reply.replyTo?.senderAccount, '10000001');
      expect(unreadItem.reply.replyTo?.senderUsername, 'Alice');
      expect(unreadItem.reply.replyTo?.preview, 'hello');
      expect(unreadItem.original.id, 'own-example-message');
      expect(unreadItem.original.replyTo, isNull);
      expect(unreadItem.toJson(), {
        'reply': {
          ...(unreadResult['items'] as List<dynamic>).single['reply']
              as Map<String, dynamic>,
          'created_at': '2026-11-11T00:00:00.000Z',
        },
        'original': {
          ...(unreadResult['items'] as List<dynamic>).single['original']
              as Map<String, dynamic>,
          'created_at': '2026-11-11T00:00:00.000Z',
        },
      });
      expect(
        (unreadItem.toJson()['original'] as Map<String, dynamic>).containsKey(
          'reply_to',
        ),
        isFalse,
      );

      final systemQuote = ReplyQuote.fromJson(<String, dynamic>{
        'message_id': 'sys-1',
        'sender_account': null,
        'sender_username': null,
        'preview': 'Bob joined the group',
      });
      expect(systemQuote.senderAccount, isNull);
      expect(systemQuote.senderUsername, isNull);
      expect(systemQuote.preview, 'Bob joined the group');

      final directResult =
          (cases['outputs']['list_direct_replies']
                  as Map<String, dynamic>)['result']
              as Map<String, dynamic>;
      final directReply = ReplyMessage.fromJson(
        (directResult['items'] as List<dynamic>).single,
      );
      expect(directReply.id, 'sent-reply');
      expect(directReply.replyTo?.messageId, 'example-message');

      final sendResult =
          (cases['outputs']['send_reply'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>;
      final sentMessage = ChatMessage.fromJson(sendResult);
      expect(sentMessage.replyTo?.messageId, 'example-message');
      expect(
        sentMessage.withOperationId('op-1').replyTo?.messageId,
        'example-message',
      );
      expect(messageToJson(sentMessage).containsKey('reply_to'), isTrue);
    },
  );

  test('DEA-519 v2 reply routes, persistence, idempotency, and HTTP wiring', () async {
    const alice = '10000001';
    const bob = '10000002';
    const dmId = 'dm:$alice:$bob';
    const groupId = 'group:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const groupRef = {'type': 'group', 'id': groupId};
    const dmRef = {'type': 'direct', 'id': dmId};
    const createdAt = '2026-11-28T12:00:00.000Z';
    final owner = List.filled(43, 'A').join();
    final temp = await Directory.systemTemp.createTemp('bb-replies-v2-');

    final messagesById = <String, Map<String, dynamic>>{};
    final operations = <String, Map<String, dynamic>>{};
    final requests =
        <({String method, String path, Map<String, dynamic>? body})>[];
    var seq = 0;

    final origDm = <String, dynamic>{
      'id': 'dm-orig-1',
      'position': 1,
      'created_at': createdAt,
      'sender_account': bob,
      'target_account': alice,
      'kind': 'body',
      'content': [
        {'type': 'text', 'text': 'Original DM'},
      ],
      'attachment': null,
    };
    final origGroup = <String, dynamic>{
      'id': 'grp-orig-1',
      'position': 1,
      'created_at': createdAt,
      'sender_account': bob,
      'sender_username': 'Bob',
      'conversation': groupRef,
      'kind': 'body',
      'content': [
        {'type': 'text', 'text': 'Original group'},
      ],
      'attachment': null,
    };
    messagesById['dm-orig-1'] = origDm;
    messagesById['grp-orig-1'] = origGroup;

    final incomingReply = <String, dynamic>{
      'id': 'dm-reply-in',
      'position': 2,
      'created_at': createdAt,
      'sender_account': bob,
      'sender_username': 'Bob',
      'kind': 'body',
      'content': [
        {'type': 'text', 'text': 'Reply from Bob'},
      ],
      'attachment': null,
      'reply_to': {
        'message_id': 'dm-own-1',
        'sender_account': alice,
        'sender_username': 'Alice',
        'preview': 'Alice own message',
      },
    };
    final ownOriginal = <String, dynamic>{
      'id': 'dm-own-1',
      'position': 1,
      'created_at': createdAt,
      'sender_account': alice,
      'target_account': bob,
      'kind': 'body',
      'content': [
        {'type': 'text', 'text': 'Alice own message'},
      ],
      'attachment': null,
    };

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = Uri.decodeComponent(request.uri.path);
      final rawBody = await utf8.decoder.bind(request).join();
      final body = rawBody.isEmpty
          ? null
          : jsonDecode(rawBody) as Map<String, dynamic>;
      requests.add((method: request.method, path: path, body: body));

      Future<void> writeJson(int status, Map<String, dynamic> payload) async {
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));
        await request.response.close();
      }

      if (request.method == 'GET' && path == '/chat/conversations') {
        await writeJson(200, {
          'items': [
            {
              'conversation': groupRef,
              'group_number': '10000002',
              'display_name': 'Study',
              'last_message': origGroup,
              'last_activity_at': createdAt,
              'latest_position': 1,
              'history_through': 0,
              'membership_revision': 1,
              'avatar_url': '/avatars/group.png',
              'avatar_version': 'v1',
            },
          ],
          'next_cursor': null,
        });
        return;
      }
      if (request.method == 'POST' && path == '/chat/replies/unread') {
        if (body!['conversation_id'] != dmId) {
          await writeJson(404, {
            'error': {
              'code': 'not_found',
              'message': 'not found',
              'fields': [],
            },
          });
          return;
        }
        await writeJson(200, {
          'items': [
            {'reply': incomingReply, 'original': ownOriginal},
          ],
          'next_cursor': body['before_position'] == null ? 2 : null,
        });
        return;
      }
      if (request.method == 'POST' && path == '/chat/replies/direct') {
        if (body!['original_message_id'] != 'dm-orig-1') {
          await writeJson(404, {
            'error': {
              'code': 'not_found',
              'message': 'not found',
              'fields': [],
            },
          });
          return;
        }
        await writeJson(200, {
          'items': [
            {
              'id': 'direct-reply-1',
              'position': 3,
              'created_at': createdAt,
              'sender_account': alice,
              'sender_username': 'Alice',
              'kind': 'body',
              'content': body['before_position'] == null
                  ? [
                      {'type': 'text', 'text': 'first direct reply'},
                    ]
                  : [
                      {'type': 'text', 'text': 'earlier direct reply'},
                    ],
              'attachment': null,
              'reply_to': {
                'message_id': 'dm-orig-1',
                'sender_account': bob,
                'sender_username': 'Bob',
                'preview': 'Original DM',
              },
            },
          ],
          'next_cursor': body['before_position'] == null ? 3 : null,
        });
        return;
      }
      if (request.method == 'POST' &&
          (path == '/messages' || path == '/messages/attachments')) {
        final replyToId = body!['reply_to_message_id'] as String?;
        final targetConv = body['conversation'] as Map<String, dynamic>?;
        final targetPeer = body['target_account'] as String?;
        final nonce = body['client_nonce'] as String;
        final existing = operations[nonce];
        if (existing != null) {
          await writeJson(200, existing);
          return;
        }
        if (replyToId != null) {
          final original = messagesById[replyToId];
          final sameScope =
              original != null &&
              ((targetConv != null &&
                      original['conversation']?['id'] == targetConv['id']) ||
                  (targetPeer != null &&
                      original['target_account'] == alice &&
                      original['sender_account'] == targetPeer));
          if (!sameScope) {
            await writeJson(404, {
              'error': {
                'code': 'not_found',
                'message': 'not found',
                'fields': [],
              },
            });
            return;
          }
        }
        final original = replyToId == null ? null : messagesById[replyToId]!;
        final sent = <String, dynamic>{
          'id': 'sent-${++seq}',
          'position': 10 + seq,
          'created_at': createdAt,
          'sender_account': alice,
          if (targetConv != null) ...{
            'conversation': targetConv,
            'sender_username': 'Alice',
          } else
            'target_account': targetPeer,
          'kind': path == '/messages' ? 'body' : 'attachment',
          if (path == '/messages') 'content': body['content'],
          'attachment': path == '/messages'
              ? null
              : {
                  'media_id': body['media_id'],
                  'media_type': 'document',
                  'filename': 'doc.pdf',
                  'mime_type': 'application/pdf',
                  'byte_size': 12,
                },
          if (original != null)
            'reply_to': {
              'message_id': original['id'],
              'sender_account': original['sender_account'],
              'sender_username': 'Bob',
              'preview': (original['content'] as List).first['text'],
            },
        };
        operations[nonce] = sent;
        await writeJson(200, sent);
        return;
      }
      if (request.method == 'GET' && path.startsWith('/operations/')) {
        final id = path.substring('/operations/'.length);
        final saved = operations[id];
        if (saved == null) {
          await writeJson(404, {
            'error': {
              'code': 'not_found',
              'message': 'not found',
              'fields': [],
            },
          });
          return;
        }
        await writeJson(200, {
          'operation_id': id,
          'kind': 'message',
          'status': 'succeeded',
          'message': saved,
        });
        return;
      }
      await writeJson(404, {
        'error': {'code': 'not_found', 'message': 'not found', 'fields': []},
      });
    });

    final session = AuthSession()
      ..establish(
        token: 'tok-alice',
        user: const AuthUser(account: alice, username: 'Alice'),
      );
    final api = ChatApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final ledgerPath = '${temp.path}/ledger.json';
    var chat = ChatService(
      api: api,
      session: session,
      ledger: ChatLedger.atPath(ledgerPath),
      cacheRoot: Directory('${temp.path}/cache'),
      webSocketHints: false,
    );
    var router = ChatV2Router(session: session, chat: chat);
    addTearDown(() async {
      await chat.dispose();
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    final auth = (await router.handle(
      path: '/v2/status',
      ownerKey: null,
      body: {},
    )).body['auth'];
    final enrolled = await router.handle(
      path: '/v2/consumers/create',
      ownerKey: owner,
      body: {'expected_auth': auth, 'session_id': 'reply-test'},
    );
    final identity = enrolled.body['identity'] as Map<String, dynamic>;

    Future<({int status, Map<String, dynamic> body})> call(
      String path,
      Map<String, dynamic> args,
    ) => router.handle(
      path: path,
      ownerKey: owner,
      body: {'expected_identity': identity, ...args},
    );

    // 1. Query validation (422) and out-of-scope 404.
    expect(
      (await call('/v2/chat/list_unread_replies', {
        'conversation_id': 'bad',
      })).status,
      422,
    );
    expect(
      (await call('/v2/chat/list_unread_replies', {
        'conversation_id': dmId,
        'before_position': 0,
      })).status,
      422,
    );
    expect(
      (await call('/v2/chat/list_unread_replies', {
        'conversation_id': groupId,
      })).status,
      404,
    );
    expect(
      (await call('/v2/chat/list_direct_replies', {
        'original_message_id': '../bad',
      })).status,
      422,
    );
    expect(
      (await call('/v2/chat/list_direct_replies', {
        'original_message_id': 'missing-id',
      })).status,
      404,
    );
    expect(
      (await call('/v2/chat/send_reply', {
        'conversation': {'type': 'direct', 'id': 'dm:10000002:10000003'},
        'reply_to_message_id': 'dm-orig-1',
        'operation_id': 'bad-dm',
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      })).status,
      422,
    );

    // 2. Read-only reply queries (no presentation/mark_seen side effects).
    final unread = await call('/v2/chat/list_unread_replies', {
      'conversation_id': dmId,
      'limit': 1,
    });
    expect(unread.status, 200);
    expect(unread.body['result']['next_cursor'], 2);
    expect(unread.body['result']['items'][0]['reply']['id'], 'dm-reply-in');
    expect(unread.body['result']['items'][0]['original']['id'], 'dm-own-1');

    final direct = await call('/v2/chat/list_direct_replies', {
      'original_message_id': 'dm-orig-1',
      'before_position': 5,
      'limit': 10,
    });
    expect(direct.status, 200);
    expect(direct.body['result']['next_cursor'], isNull);
    expect(direct.body['result']['items'][0]['id'], 'direct-reply-1');
    expect(
      requests.where(
        (r) => r.path.contains('mark_seen') || r.path.contains('confirm'),
      ),
      isEmpty,
    );

    // 3. Cross-conversation quote rejected with 404.
    final crossScope = await call('/v2/chat/send_reply', {
      'conversation': dmRef,
      'reply_to_message_id': 'grp-orig-1',
      'operation_id': 'op-cross',
      'content': [
        {'type': 'text', 'text': 'cross'},
      ],
    });
    expect(crossScope.status, 404);
    expect(crossScope.body['error']['code'], 'not_found');

    // 4. Send DM reply & group reply, then verify conflict & restart replay.
    final dmReply = await call('/v2/chat/send_reply', {
      'conversation': dmRef,
      'reply_to_message_id': 'dm-orig-1',
      'operation_id': 'op-dm-reply',
      'content': [
        {'type': 'text', 'text': 'dm reply body'},
      ],
    });
    expect(dmReply.status, 200);
    expect(dmReply.body['result']['reply_to'], {
      'message_id': 'dm-orig-1',
      'sender_account': bob,
      'sender_username': 'Bob',
      'preview': 'Original DM',
    });

    final grpReply = await call('/v2/chat/send_reply', {
      'conversation': groupRef,
      'reply_to_message_id': 'grp-orig-1',
      'operation_id': 'op-grp-reply',
      'content': [
        {'type': 'text', 'text': 'group reply body'},
      ],
    });
    expect(grpReply.status, 200);
    expect(grpReply.body['result']['conversation'], groupRef);
    expect(grpReply.body['result']['reply_to']['message_id'], 'grp-orig-1');

    // Changing reply_to_message_id on same operation_id -> 409 idempotency_conflict.
    final conflictReply = await call('/v2/chat/send_reply', {
      'conversation': dmRef,
      'reply_to_message_id': 'dm-orig-2',
      'operation_id': 'op-dm-reply',
      'content': [
        {'type': 'text', 'text': 'dm reply body'},
      ],
    });
    expect(conflictReply.status, 409);
    expect(conflictReply.body['error']['code'], 'idempotency_conflict');

    // Also conflict if same operation_id is reused without reply_to_message_id.
    final conflictPlain = await call('/v2/chat/send_message', {
      'target_account': bob,
      'operation_id': 'op-dm-reply',
      'content': [
        {'type': 'text', 'text': 'dm reply body'},
      ],
    });
    expect(conflictPlain.status, 409);
    expect(conflictPlain.body['error']['code'], 'idempotency_conflict');

    // Simulate restart: reload ledger from disk and replay without extra HTTP POST.
    final postCountBeforeRestart = requests
        .where((r) => r.method == 'POST' && r.path == '/messages')
        .length;
    await chat.dispose();
    chat = ChatService(
      api: api,
      session: session,
      ledger: ChatLedger.atPath(ledgerPath),
      cacheRoot: Directory('${temp.path}/cache'),
      webSocketHints: false,
    );
    router = ChatV2Router(session: session, chat: chat);
    final replayed = await call('/v2/chat/send_reply', {
      'conversation': dmRef,
      'reply_to_message_id': 'dm-orig-1',
      'operation_id': 'op-dm-reply',
      'content': [
        {'type': 'text', 'text': 'dm reply body'},
      ],
    });
    expect(replayed.status, 200);
    expect(replayed.body['result'], dmReply.body['result']);
    expect(
      requests.where((r) => r.method == 'POST' && r.path == '/messages').length,
      postCountBeforeRestart,
    );

    final opLookup = await call('/v2/operations/get', {
      'operation_id': 'op-dm-reply',
    });
    expect(opLookup.status, 200);
    expect(
      opLookup.body['result']['message']['reply_to']['message_id'],
      'dm-orig-1',
    );

    // 5. Attachment reply via ChatApiClient sends reply_to_message_id.
    final att = await api.sendAttachment(
      token: 'tok-alice',
      targetAccount: bob,
      clientNonce: 'op-att-reply',
      mediaId: 'med-1',
      replyToMessageId: 'dm-orig-1',
    );
    expect(att.replyTo?.messageId, 'dm-orig-1');
    final lastAttReq = requests.lastWhere(
      (r) => r.path == '/messages/attachments',
    );
    expect(lastAttReq.body!['reply_to_message_id'], 'dm-orig-1');
  });
}
