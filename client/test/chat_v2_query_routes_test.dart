import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

/// v2 query routes wired to the shared server query layer at 900429c.
const String _account = '10000001';
const String _peer = '10000002';
const String _third = '10000003';
const String _fourth = '10000004';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late String ledgerPath;
  late Map<String, dynamic> identity;
  late String b1Id;
  late String a2Id;
  late String b3Id;

  final String owner = List<String>.filled(43, 'A').join();
  final String otherOwner = List<String>.filled(43, 'B').join();

  AuthUser user(String account) => AuthUser(
    account: account,
    username: 'user-$account',
  );

  Future<void> call(
    String path,
    Map<String, dynamic> body, {
    String? ownerKey,
    required int status,
  }) async {
    final Map<String, dynamic> response = await _postV2(
      address,
      path,
      body,
      owner: ownerKey ?? owner,
    );
    expect(response['status'], status, reason: '$path -> $response');
  }

  Future<Map<String, dynamic>> ok(
    String path,
    Map<String, dynamic> body, {
    String? ownerKey,
  }) async {
    final Map<String, dynamic> response = await _postV2(
      address,
      path,
      body,
      owner: ownerKey ?? owner,
    );
    expect(response['status'], 200, reason: '$path -> $response');
    return response;
  }

  Map<String, dynamic> withIdentity(Map<String, dynamic> body) =>
      <String, dynamic>{'expected_identity': identity, ...body};

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{
        _account: 'alice',
        _peer: 'bob',
        _third: 'carol',
        _fourth: 'dave',
      },
    );
    root = await Directory.systemTemp.createTemp('bb-v2-query-routes-');
    ledgerPath = '${root.path}/ledger.json';
    session = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    chat = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath(ledgerPath),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
    server = LocalAuthServer(
      service: AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: session,
      ),
      chat: chat,
      port: 0,
    );
    address = await server.start();
    final Map<String, dynamic> auth =
        (await ok('/v2/status', <String, dynamic>{}))['body']['auth']
            as Map<String, dynamic>;
    final Map<String, dynamic> binding = await ok(
      '/v2/consumers/create',
      <String, dynamic>{'expected_auth': auth, 'session_id': 'query-routes'},
    );
    identity = binding['body']['identity'] as Map<String, dynamic>;

    final String media = await backend.addImage(
      owner: _account,
      peer: _peer,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    b1Id = await backend.seedMessage(sender: _peer, target: _account, text: 'b1');
    a2Id = await backend.seedMessage(
      sender: _account,
      target: _peer,
      text: 'a2',
      mediaId: media,
    );
    b3Id = await backend.seedMessage(sender: _peer, target: _account, text: 'b3');
    // A missing image must not produce a complete presentation.
    await backend.seedMessage(
      sender: _third,
      target: _account,
      text: 'missing-image',
      mediaId: 'seed-media-missing',
    );
    // A third-party message is never visible through this account's scope.
    await backend.seedMessage(sender: _third, target: _fourth, text: 'hidden');
  });

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('query routes are strict, owner checked and identity checked', () async {
    await call(
      '/v2/chat/list_conversations',
      withIdentity(<String, dynamic>{}),
      status: 409,
      ownerKey: otherOwner,
    );
    await call(
      '/v2/chat/list_conversations',
      withIdentity(<String, dynamic>{'extra': 1}),
      status: 422,
    );
    await call(
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': 'bad.id'}),
      status: 422,
    );
    await call(
      '/v2/chat/get_message',
      <String, dynamic>{'message_id': a2Id},
      status: 422,
      ownerKey: null,
    );
    await call(
      '/v2/chat/get_context',
      withIdentity(<String, dynamic>{
        'message_id': a2Id,
        'before_limit': 50,
      }),
      status: 422,
    );
    await call(
      '/v2/chat/read_messages',
      withIdentity(<String, dynamic>{
        'account': _peer,
        'after_position': 0,
        'before_position': 3,
      }),
      status: 422,
    );
    await call(
      '/v2/chat/read_messages',
      withIdentity(<String, dynamic>{
        'account': _peer,
        'before_position': 0,
      }),
      status: 422,
    );
    // The old unauthenticated business route is gone, not merely restricted.
    final Map<String, dynamic> v1 = await _postV1(
      address,
      '/chat/read_messages',
      <String, dynamic>{
        'account': _peer,
        'consumer_session': 'legacy',
        'before_position': 3,
      },
    );
    expect(v1['status'], 404);
  });

  test('list_conversations is keyset-paged and consumer-enriched', () async {
    final Map<String, dynamic> page = await ok(
      '/v2/chat/list_conversations',
      withIdentity(<String, dynamic>{}),
    );
    final Map<String, dynamic> result =
        page['body']['result'] as Map<String, dynamic>;
    expect(result.keys.toSet(), <String>{'items', 'next_cursor'});
    final List<dynamic> items = result['items'] as List<dynamic>;
    expect(
      items.map((dynamic item) => (item as Map<String, dynamic>)['peer_account']),
      <String>[_peer, _third],
    );
    final Map<String, dynamic> first = items.first as Map<String, dynamic>;
    expect(first.keys.toSet(), <String>{
      'peer_account',
      'last_message',
      'last_activity_at',
      'latest_position',
      'consumed_through',
      'unconsumed_positions',
    });
    expect(first['latest_position'], 3);
    expect(first['consumed_through'], 0);
    expect(first['unconsumed_positions'], 3);

    await chat.ledger.setConsumedThrough(
      _account,
      _peer,
      3,
      consumerId: identity['consumer_id'] as String,
    );
    final Map<String, dynamic> after = await ok(
      '/v2/chat/list_conversations',
      withIdentity(<String, dynamic>{'after_account': _peer, 'limit': 1}),
    );
    final Map<String, dynamic> afterResult =
        after['body']['result'] as Map<String, dynamic>;
    expect(
      (afterResult['items'] as List<dynamic>).map(
        (dynamic item) => (item as Map<String, dynamic>)['peer_account'],
      ),
      <String>[_third],
    );
    // The consumer watermark for the third peer was not ACKed by the query.
    expect(
      await chat.ledger.consumedThrough(
        _account,
        _third,
        consumerId: identity['consumer_id'] as String,
      ),
      0,
    );
  });

  test('get_message is direct, ordered and refuses incomplete display',
      () async {
    final Map<String, dynamic> response = await ok(
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': a2Id}),
    );
    final Map<String, dynamic> result =
        response['body']['result'] as Map<String, dynamic>;
    expect(result.keys.toSet(), <String>{'item', 'missing_media_ids'});
    final Map<String, dynamic> item =
        result['item'] as Map<String, dynamic>;
    expect(item.keys.toSet(), <String>{'message', 'presentation', 'blocks'});
    expect(item['presentation'], isNotNull);
    expect(result['missing_media_ids'], isEmpty);

    // The missing-image message keeps its text block but gets no receipt.
    final Map<String, dynamic> missingResponse = await ok(
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': 'm4'}),
    );
    final Map<String, dynamic> missing =
        missingResponse['body']['result'] as Map<String, dynamic>;
    expect(missing['missing_media_ids'], <String>['seed-media-missing']);
    expect(
      (missing['item'] as Map<String, dynamic>).containsKey('presentation'),
      isFalse,
    );

    final Map<String, dynamic> absent = await _postV2(
      address,
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': 'missing'}),
      owner: owner,
    );
    expect(absent['status'], 404);
    expect(
      ((absent['body'] as Map<String, dynamic>)['error']
          as Map<String, dynamic>)['code'],
      'not_found',
    );
    final Map<String, dynamic> hidden = await _postV2(
      address,
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': 'm5'}),
      owner: owner,
    );
    expect(hidden['status'], 404);
  });

  test('get_context returns the shared range, gaps and missing media',
      () async {
    final Map<String, dynamic> response = await ok(
      '/v2/chat/get_context',
      withIdentity(<String, dynamic>{
        'message_id': a2Id,
        'before_limit': 1,
        'after_limit': 1,
      }),
    );
    final Map<String, dynamic> result =
        response['body']['result'] as Map<String, dynamic>;
    expect(result.keys.toSet(), <String>{
      'peer_account',
      'anchor_message_id',
      'range',
      'before_has_more',
      'after_has_more',
      'missing_positions',
      'missing_truncated',
      'reply_relations',
      'items',
      'missing_media_ids',
    });
    expect(
      (result['items'] as List<dynamic>)
          .map((dynamic item) => ((item as Map<String, dynamic>)['message']
              as Map<String, dynamic>)['position'])
          .toList(),
      <int>[1, 2, 3],
    );
    expect(result['range'], <String, dynamic>{
      'start_position': 1,
      'end_position': 3,
    });
    expect(result['reply_relations'], 'unsupported');
    expect(result['missing_positions'], isEmpty);

    final Map<String, dynamic> missingResponse = await ok(
      '/v2/chat/get_context',
      withIdentity(<String, dynamic>{'message_id': 'm4'}),
    );
    final Map<String, dynamic> missing =
        missingResponse['body']['result'] as Map<String, dynamic>;
    expect(missing['missing_media_ids'], contains('seed-media-missing'));
    final List<dynamic> items = missing['items'] as List<dynamic>;
    expect(
      items.any(
        (dynamic item) =>
            (item as Map<String, dynamic>).containsKey('presentation'),
      ),
      isFalse,
      reason: 'an incomplete display must not receive a consumable receipt',
    );

    final Map<String, dynamic> absent = await _postV2(
      address,
      '/v2/chat/get_context',
      withIdentity(<String, dynamic>{'message_id': 'missing'}),
      owner: owner,
    );
    expect(absent['status'], 404);
  });

  test('read_messages supports before_position and keeps after compatible',
      () async {
    final Map<String, dynamic> before = await ok(
      '/v2/chat/read_messages',
      withIdentity(<String, dynamic>{
        'account': _peer,
        'before_position': 3,
        'limit': 2,
      }),
    );
    final Map<String, dynamic> beforeResult =
        before['body']['result'] as Map<String, dynamic>;
    expect(
      (beforeResult['items'] as List<dynamic>)
          .map((dynamic item) => ((item as Map<String, dynamic>)['message']
              as Map<String, dynamic>)['position'])
          .toList(),
      <int>[1, 2],
    );
    expect(beforeResult['next_position'], 1);
    expect(beforeResult['has_more'], isFalse);

    final Map<String, dynamic> after = await ok(
      '/v2/chat/read_messages',
      withIdentity(<String, dynamic>{
        'account': _peer,
        'after_position': 0,
        'limit': 2,
      }),
    );
    final Map<String, dynamic> afterResult =
        after['body']['result'] as Map<String, dynamic>;
    expect(
      (afterResult['items'] as List<dynamic>)
          .map((dynamic item) => ((item as Map<String, dynamic>)['message']
              as Map<String, dynamic>)['position'])
          .toList(),
      <int>[1, 2],
    );
    expect(afterResult['next_position'], 2);
    expect(afterResult['has_more'], isTrue);

    // Queries prepare receipts but never confirm or ACK.
    final String consumer = identity['consumer_id'] as String;
    final int consumed = await chat.ledger.consumedThrough(
      _account,
      _peer,
      consumerId: consumer,
    );
    expect(consumed, 0);
    final List<PresentationReceipt> receipts = await chat.ledger
        .receiptsForPeer(
          account: _account,
          consumerSession: 'query-routes',
          peerAccount: _peer,
          consumerId: consumer,
        );
    for (final PresentationReceipt receipt in receipts) {
      expect(receipt.confirmed, isFalse);
    }
  });

  test('b1 and b3 remain reachable by direct lookup', () async {
    for (final String id in <String>[b1Id, b3Id]) {
      final Map<String, dynamic> response = await ok(
        '/v2/chat/get_message',
        withIdentity(<String, dynamic>{'message_id': id}),
      );
      expect(
        ((response['body']['result'] as Map<String, dynamic>)['item']
            as Map<String, dynamic>)['message'],
        isNotNull,
      );
    }
  });
}

Future<Map<String, dynamic>> _postV2(
  Uri address,
  String path,
  Map<String, dynamic> body, {
  String? owner,
}) {
  final Map<String, String> headers = <String, String>{};
  if (owner != null) {
    headers[v2OwnerHeader] = owner;
  }
  return _post(address, path, body, owner: owner, headers: headers);
}

Future<Map<String, dynamic>> _postV1(
  Uri address,
  String path,
  Map<String, dynamic> body,
) {
  return _post(address, path, body);
}

Future<Map<String, dynamic>> _post(
  Uri address,
  String path,
  Map<String, dynamic> body, {
  String? owner,
  Map<String, String> headers = const <String, String>{},
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(address.resolve(path));
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    final List<int> bytes = utf8.encode(jsonEncode(body));
    request.contentLength = bytes.length;
    request.add(bytes);
    final HttpClientResponse response = await request.close();
    final String raw = await utf8.decoder.bind(response).join();
    final Object? decoded = raw.isEmpty ? null : jsonDecode(raw);
    return <String, dynamic>{
      'status': response.statusCode,
      'body': decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    };
  } finally {
    client.close(force: true);
  }
}
