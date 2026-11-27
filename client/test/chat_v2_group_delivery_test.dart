import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/chat_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('group event replay and notice aggregation preserve current membership and read state', () async {
    const account = '10000001';
    const peer = '10000002';
    const group = 'group:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const ref = {'type': 'group', 'id': group};
    const at = '2026-11-27T00:00:00Z';
    final owner = List.filled(43, 'A').join();
    final temp = await Directory.systemTemp.createTemp('bb-group-delivery-');
    final session = AuthSession()
      ..establish(
        token: 'synthetic',
        user: const AuthUser(account: account, username: 'Alice'),
      );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = ChatApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final events = <Map<String, dynamic>>[];
    final messages = <Map<String, dynamic>>[];
    var revision = 1;
    var boundary = 0;
    var active = true;
    var failNoticeList = false;
    final requests = <String>[];
    final notice = {
      'id': 'invitation-1',
      'type': 'group_invitation',
      'title': 'Synthetic invitation',
      'text': '🙂' * 161,
      'created_at': at,
      'read': false,
      'state': 'pending',
      'actions': [
        {'id': 'accept', 'label': 'Accept', 'available': true},
      ],
      'link': {'type': 'group', 'id': '10000002'},
    };
    void event(String type, Map<String, dynamic> fields) => events.add({
      'version': 1,
      'occurred_at': at,
      'event_id': events.length + 1,
      'type': type,
      ...fields,
    });
    void addMessage(int position, int membership) {
      messages.add({
        'id': 'message-$position',
        'position': position,
        'kind': 'body',
        'conversation': ref,
        'sender_account': peer,
        'sender_username': 'Bob',
        'created_at': at,
        'content': [
          {'type': 'text', 'text': 'Message $position'},
        ],
        'attachment': null,
      });
      event('message.available', {
        'conversation': ref,
        'membership_revision': membership,
        'message_id': 'message-$position',
        'position': position,
      });
    }

    server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      final int latest = messages.isEmpty
          ? 0
          : messages.last['position'] as int;
      Map<String, dynamic> body;
      switch (path) {
        case '/events':
          final after =
              int.tryParse(
                request.uri.queryParameters['after_event_id'] ?? '',
              ) ??
              0;
          body = {
            'items': request.uri.queryParameters['include_groups'] == 'true'
                ? events.skip(after).toList()
                : [],
            'next_event_id': events.length,
            'has_more': false,
          };
        case '/conversations':
          body = {'items': [], 'next_cursor': null};
        case '/chat/conversations':
          body = {
            'items': [
              if (active)
                {
                  'conversation': ref,
                  'group_number': '10000002',
                  'display_name': 'Group',
                  'last_message': messages.lastOrNull,
                  'last_activity_at': at,
                  'latest_position': latest,
                  'history_through': boundary,
                  'membership_revision': revision,
                  'avatar_url': '/group/avatar',
                  'avatar_version': 'v1',
                },
            ],
            'next_cursor': null,
          };
        case '/chat/conversations/$group/messages':
          final after =
              int.tryParse(
                request.uri.queryParameters['after_position'] ?? '',
              ) ??
              0;
          body = {
            'items': messages
                .where((item) => (item['position'] as int) > after)
                .toList(),
            'next_position': latest,
            'has_more': false,
          };
        case '/chat/notices/list':
          if (failNoticeList) {
            request.response.statusCode = 502;
            body = {
              'error': {
                'code': 'upstream_unavailable',
                'message': 'Synthetic outage',
                'fields': [],
              },
            };
          } else {
            body = {
              'items': [notice],
              'next_cursor': null,
              'unread_count': 1,
              'pending_count': 1,
            };
          }
        default:
          request.response.statusCode = 404;
          body = {
            'error': {
              'code': 'not_found',
              'message': 'Unknown test route',
              'fields': [],
            },
          };
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    ChatService start() => ChatService(
      api: api,
      session: session,
      ledger: ChatLedger.atPath('${temp.path}/ledger.json'),
      cacheRoot: Directory('${temp.path}/cache'),
      webSocketHints: false,
    );
    var chat = start();
    addTearDown(() async {
      await chat.dispose();
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    var router = ChatV2Router(session: session, chat: chat);
    final auth = (await router.handle(
      path: '/v2/status',
      ownerKey: null,
      body: {},
    )).body['auth'];
    final enrolled = await router.handle(
      path: '/v2/consumers/create',
      ownerKey: owner,
      body: {'expected_auth': auth, 'session_id': 'group-test'},
    );
    expect(enrolled.status, 200);
    final identity = enrolled.body['identity'];
    Future<({int status, Map<String, dynamic> body})> call(
      String path, [
      Map<String, dynamic> arguments = const {},
    ]) => router.handle(
      path: path,
      ownerKey: owner,
      body: {...arguments, 'expected_identity': identity},
    );
    Future<Map<String, dynamic>> ok(
      String path, [
      Map<String, dynamic> args = const {},
    ]) async {
      final response = await call(path, args);
      expect(response.status, 200, reason: '$path ${response.body}');
      return response.body['result'] as Map<String, dynamic>;
    }

    addMessage(1, revision);
    await ok('/v2/events/subscribe', {'discover': true});
    final initial = await ok('/v2/notifications/changes');
    expect(initial['items'].single['last_message']['message_id'], 'message-1');
    expect(initial['items'].single['membership_revision'], 1);
    final firstCursor = initial['next_cursor'];

    active = false;
    revision = 2;
    event('conversation.access_changed', {
      'conversation': ref,
      'membership_revision': revision,
      'active': false,
      'history_through': boundary,
    });
    await chat.eventFeed.pollOnce();
    expect(
      (await call('/v2/chat/read_messages', {'conversation': ref})).status,
      404,
    );
    expect((await ok('/v2/notifications/changes'))['items'], isEmpty);

    active = true;
    revision = 3;
    boundary = 1;
    event('conversation.access_changed', {
      'conversation': ref,
      'membership_revision': revision,
      'active': true,
      'history_through': boundary,
    });
    addMessage(
      2,
      1,
    ); // A stale locator above the new boundary must still be ignored.
    event('notification.available', {'notification_id': 'invitation-1'});
    await chat.eventFeed.pollOnce();
    failNoticeList = true;
    expect(
      (await call('/v2/notifications/changes', {
        'after_cursor': firstCursor,
      })).status,
      502,
    );

    await chat.dispose();
    chat = start();
    router = ChatV2Router(session: session, chat: chat);
    failNoticeList = false;
    await chat.eventFeed.pollOnce();
    final recovered = await ok('/v2/notifications/changes', {
      'after_cursor': firstCursor,
    });
    expect(recovered['items'], isEmpty);
    expect(
      recovered['business_notices']['last_notice']['notification_id'],
      'invitation-1',
    );
    expect(
      recovered['business_notices']['last_notice']['text'].runes.length,
      160,
    );
    expect(recovered['business_notices']['last_notice']['truncated'], isTrue);
    expect(recovered['business_notices']['new_count'], 1);
    expect(recovered['business_notices']['unread_count'], 1);
    expect(recovered['business_notices']['pending_count'], 1);
    expect(
      requests.where(
        (path) => path.contains('mark_read') || path.contains('execute_action'),
      ),
      isEmpty,
    );

    addMessage(3, revision);
    await chat.eventFeed.pollOnce();
    final fresh = await ok('/v2/notifications/changes', {
      'after_cursor': recovered['next_cursor'],
    });
    expect(fresh['items'].single['membership_revision'], 3);
    expect(fresh['items'].single['new_count'], 1);
    expect(fresh['items'].single['last_message']['message_id'], 'message-3');
    expect(fresh.containsKey('business_notices'), isFalse);
    final history = await ok('/v2/chat/read_messages', {'conversation': ref});
    expect(history['items'].first['message']['id'], 'message-1');
    expect(history['items'].first['presentation'], isNull);
    final list = await ok('/v2/chat/list_conversations');
    expect(list['items'].single['group_number'], '10000002');
  });
}
