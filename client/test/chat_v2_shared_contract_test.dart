import 'dart:convert';
import 'dart:io';

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

/// Consumes the shared machine fixtures from `server/contract/` in the
/// integrated tree: the client must implement exactly the declared routes,
/// reject every declared invalid input and return the declared error/status
/// and result shapes.
const String _account = '10000001';
const String _peer = '10000002';

void main() {
  late Map<String, dynamic> cases;
  late Map<String, dynamic> openapi;
  late Map<String, String> opPath;
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;

  final String ownerOne = List<String>.filled(43, 'A').join();
  final String ownerTwo = List<String>.filled(43, 'B').join();

  AuthUser user(String account) =>
      AuthUser(account: account, username: 'user-$account');

  setUpAll(() async {
    final File casesFile = File(
      '../server/contract/chat-v2-cases.json',
    );
    final File openapiFile = File(
      '../server/contract/chat-v2-openapi.json',
    );
    expect(
      casesFile.existsSync(),
      isTrue,
      reason: 'integrated tree must provide the shared v2 fixtures',
    );
    expect(openapiFile.existsSync(), isTrue);
    cases = jsonDecode(casesFile.readAsStringSync()) as Map<String, dynamic>;
    openapi =
        jsonDecode(openapiFile.readAsStringSync()) as Map<String, dynamic>;
    opPath = <String, String>{};
    final Map<String, dynamic> paths =
        openapi['paths'] as Map<String, dynamic>;
    for (final MapEntry<String, dynamic> entry in paths.entries) {
      for (final Object? operation
          in (entry.value as Map<String, dynamic>).values) {
        final Object? id = (operation as Map<String, dynamic>)['operationId'];
        if (id is String) {
          opPath[id] = entry.key;
        }
      }
    }
  });

  Future<void> start({required bool loggedIn}) async {
    backend = await FakeChatBackend.start(
      users: <String, String>{
        _account: 'alice',
        _peer: 'bob',
        '10000009': 'carol',
      },
    );
    root = await Directory.systemTemp.createTemp('bb-v2-fixtures-');
    session = AuthSession();
    if (loggedIn) {
      session.establish(token: backend.tokenFor(_account), user: user(_account));
    }
    chat = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
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
  }

  Future<_Response> post(
    String path,
    Map<String, dynamic> body, {
    String? owner,
  }) {
    return _postV2(
      address,
      path,
      body,
      owner: owner ?? ownerOne,
    );
  }

  Map<String, dynamic> errorBody(Map<String, dynamic> response) =>
      response['error'] as Map<String, dynamic>;

  void expectEnvelope(Map<String, dynamic> body, String code) {
    final Map<String, dynamic> error = errorBody(body);
    expect(error.keys.toSet(), <String>{'code', 'message', 'fields'});
    expect(error['code'], code);
    expect(error['message'], isA<String>());
    expect(error['message'].toString().length, lessThanOrEqualTo(200));
    final Object? fields = error['fields'];
    expect(fields, isA<List<dynamic>>());
    for (final Object? field in fields as List<dynamic>) {
      expect(field, isA<String>());
      expect(field, isNot(contains(' ')), reason: 'field names only');
    }
  }

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('contract header/version and every declared route are implemented',
      () async {
    expect(cases['version'], v2Contract);
    final Map<String, dynamic> header =
        cases['owner_header'] as Map<String, dynamic>;
    expect(header['name'], v2OwnerHeader);
    expect(isValidOwnerKey(header['value'] as String), isTrue);

    await start(loggedIn: false);
    final Map<String, dynamic> paths =
        openapi['paths'] as Map<String, dynamic>;
    for (final String path in paths.keys) {
      // `{}` is rejected by every strict schema (or answers status/negotiate),
      // but the route must exist rather than 404.
      final _Response response = await post(path, <String, dynamic>{});
      expect(response.status, isNot(404), reason: path);
    }
    expect(
      (await post('/v2/chat/not_a_route', <String, dynamic>{})).status,
      404,
    );
    expect(opPath.length, paths.length);
  });

  test('every declared invalid input is rejected with 422', () async {
    await start(loggedIn: false);
    for (final Object? entry in cases['invalid_inputs'] as List<dynamic>) {
      final Map<String, dynamic> invalid = entry as Map<String, dynamic>;
      final String path = opPath[invalid['operation']]!;
      final _Response response = await post(
        path,
        Map<String, dynamic>.from(invalid['input'] as Map<String, dynamic>),
      );
      expect(response.status, 422, reason: invalid['id'] as String);
      expectEnvelope(response.body, 'validation_error');
    }
  });

  test('declared error statuses and the result shapes match the fixtures',
      () async {
    final Map<String, dynamic> errors =
        cases['errors'] as Map<String, dynamic>;
    int declared(String code) =>
        (errors[code] as Map<String, dynamic>)['status'] as int;

    await start(loggedIn: false);
    final _Response unsupported = await post(
      '/v2/protocol/negotiate',
      <String, dynamic>{
        'supported_versions': <int>[1],
      },
    );
    expect(unsupported.status, declared('unsupported_version'));
    expectEnvelope(unsupported.body, 'unsupported_version');

    final _Response validation = await post(
      '/v2/status',
      <String, dynamic>{'x': 1},
    );
    expect(validation.status, declared('validation_error'));
    expectEnvelope(validation.body, 'validation_error');

    final _Response unauthenticated = await post(
      '/v2/chat/consumption',
      <String, dynamic>{
        'expected_identity': <String, dynamic>{
          'account': _account,
          'auth_generation': 'g-1',
          'consumer_id': 'c-1',
          'binding_revision': 1,
        },
        'account': _peer,
      },
    );
    expect(unauthenticated.status, declared('unauthenticated'));
    expectEnvelope(unauthenticated.body, 'unauthenticated');
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }

    // Logged-in flow for the remaining codes and shape checks.
    await start(loggedIn: true);
    final Map<String, dynamic> auth =
        (await post('/v2/status', <String, dynamic>{})).body['auth']
            as Map<String, dynamic>;
    Future<Map<String, dynamic>> create(String owner, String sessionId) async {
      final _Response response = await post(
        '/v2/consumers/create',
        <String, dynamic>{'expected_auth': auth, 'session_id': sessionId},
        owner: owner,
      );
      expect(response.status, 200);
      return response.body['identity'] as Map<String, dynamic>;
    }

    final Map<String, dynamic> first = await create(ownerOne, 's-one');
    final Map<String, dynamic> second = await create(ownerTwo, 's-two');

    final _Response staleIdentity = await post(
      '/v2/chat/consumption',
      <String, dynamic>{
        'expected_identity': <String, dynamic>{
          ...first,
          'auth_generation': 'g-not-current',
        },
        'account': _peer,
      },
      owner: ownerOne,
    );
    expect(staleIdentity.status, declared('stale_identity'));
    expectEnvelope(staleIdentity.body, 'stale_identity');

    final _Response wrongOwner = await post(
      '/v2/chat/consumption',
      <String, dynamic>{'expected_identity': first, 'account': _peer},
      owner: ownerTwo,
    );
    expect(wrongOwner.status, declared('stale_binding'));
    expectEnvelope(wrongOwner.body, 'stale_binding');

    await backend.seedMessage(sender: _peer, target: _account, text: 'one');
    final _Response read = await post(
      '/v2/chat/read_messages',
      <String, dynamic>{
        'expected_identity': first,
        'account': _peer,
        'after_position': 0,
        'limit': 50,
      },
      owner: ownerOne,
    );
    expect(read.status, 200);
    final Map<String, dynamic> readResult =
        read.body['result'] as Map<String, dynamic>;
    expect(
      readResult.keys.toSet(),
      ((cases['outputs']['read_messages'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)
          .keys
          .toSet(),
    );
    final Map<String, dynamic> item =
        (readResult['items'] as List<dynamic>).single as Map<String, dynamic>;
    expect(
      item.keys.toSet(),
      (((cases['outputs']['read_messages'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)['items'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .first
          .keys
          .toSet(),
    );
    expect(
      (item['presentation'] as Map<String, dynamic>).keys.toSet(),
      <String>{'receipt_id', 'content_digest'},
    );
    final List<String> receipts = <String>[
      (item['presentation'] as Map<String, dynamic>)['receipt_id'] as String,
    ];

    Map<String, dynamic> expectedResult(String name) =>
        (cases['outputs'][name] as Map<String, dynamic>)['result']
            as Map<String, dynamic>;
    Future<Map<String, dynamic>> query(
      String path,
      Map<String, dynamic> body,
    ) async {
      final _Response response = await post(path, body, owner: ownerOne);
      expect(response.status, 200, reason: '$path -> ${response.body}');
      return (response.body['result'] as Map<String, dynamic>);
    }

    final Map<String, dynamic> conversations = await query(
      '/v2/chat/list_conversations',
      <String, dynamic>{'expected_identity': first},
    );
    expect(
      conversations.keys.toSet(),
      expectedResult('list_conversations').keys.toSet(),
    );
    expect(
      ((conversations['items'] as List<dynamic>).single
              as Map<String, dynamic>)
          .keys
          .toSet(),
      ((expectedResult('list_conversations')['items'] as List<dynamic>)
              .single as Map<String, dynamic>)
          .keys
          .toSet(),
    );
    final String messageId =
        (item['message'] as Map<String, dynamic>)['id'] as String;
    final Map<String, dynamic> message = await query(
      '/v2/chat/get_message',
      <String, dynamic>{
        'expected_identity': first,
        'message_id': messageId,
      },
    );
    expect(message.keys.toSet(), expectedResult('get_message').keys.toSet());
    expect(
      (message['item'] as Map<String, dynamic>).keys.toSet(),
      (expectedResult('get_message')['item'] as Map<String, dynamic>).keys
          .toSet(),
    );
    final Map<String, dynamic> context = await query(
      '/v2/chat/get_context',
      <String, dynamic>{
        'expected_identity': first,
        'message_id': messageId,
      },
    );
    expect(context.keys.toSet(), expectedResult('get_context').keys.toSet());
    expect(
      (context['range'] as Map<String, dynamic>).keys.toSet(),
      ((expectedResult('get_context')['range'] as Map<String, dynamic>).keys
          .toSet()),
    );
    expect(context['reply_relations'], 'unsupported');

    final _Response confirm = await post(
      '/v2/chat/confirm_presentation',
      <String, dynamic>{
        'expected_identity': first,
        'attempt_id': 'fixture-attempt',
        'request_digest': List<String>.filled(64, 'a').join(),
        'receipt_ids': receipts,
      },
      owner: ownerOne,
    );
    expect(confirm.status, 200);
    expect(
      (confirm.body['result'] as Map<String, dynamic>).keys.toSet(),
      ((cases['outputs']['confirm_presentation'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)
          .keys
          .toSet(),
    );

    final _Response ack = await post(
      '/v2/chat/ack_messages',
      <String, dynamic>{
        'expected_identity': first,
        'account': _peer,
        'through_position': 1,
      },
      owner: ownerOne,
    );
    expect(ack.status, 200);
    expect(
      (ack.body['result'] as Map<String, dynamic>).keys.toSet(),
      ((cases['outputs']['ack_messages'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)
          .keys
          .toSet(),
    );

    final _Response consumption = await post(
      '/v2/chat/consumption',
      <String, dynamic>{'expected_identity': first, 'account': _peer},
      owner: ownerOne,
    );
    expect(
      (consumption.body['result'] as Map<String, dynamic>).keys.toSet(),
      ((cases['outputs']['get_consumption'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)
          .keys
          .toSet(),
    );

    final _Response gap = await post(
      '/v2/chat/ack_messages',
      <String, dynamic>{
        'expected_identity': second,
        'account': _peer,
        'through_position': 1,
      },
      owner: ownerTwo,
    );
    expect(gap.status, declared('consumption_gap'));
    expectEnvelope(gap.body, 'consumption_gap');

    final _Response notFound = await post(
      '/v2/operations/get',
      <String, dynamic>{
        'expected_identity': first,
        'operation_id': 'fixture-missing',
      },
      owner: ownerOne,
    );
    expect(notFound.status, declared('not_found'));
    expectEnvelope(notFound.body, 'not_found');

    final _Response sent = await post(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': first,
        'target_account': _peer,
        'operation_id': 'fixture-send',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'hello'},
        ],
      },
      owner: ownerOne,
    );
    expect(sent.status, 200);
    expect(
      (sent.body['result'] as Map<String, dynamic>).keys.toSet(),
      ((cases['outputs']['send_message'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)
          .keys
          .toSet(),
    );
    final _Response conflict = await post(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': first,
        'target_account': _peer,
        'operation_id': 'fixture-send',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'different intent'},
        ],
      },
      owner: ownerOne,
    );
    expect(conflict.status, declared('idempotency_conflict'));
    expectEnvelope(conflict.body, 'idempotency_conflict');

    final _Response operation = await post(
      '/v2/operations/get',
      <String, dynamic>{
        'expected_identity': first,
        'operation_id': 'fixture-send',
      },
      owner: ownerOne,
    );
    expect(operation.status, 200);
    expect(
      (operation.body['result'] as Map<String, dynamic>).keys.toSet(),
      ((cases['outputs']['get_operation'] as Map<String, dynamic>)['result']
              as Map<String, dynamic>)
          .keys
          .toSet(),
    );

    // Legacy event without a provable origin is a migration error, not a
    // relabelled v2 event.
    await chat.ledger.appendLocalEvent(
      account: _account,
      consumerSession: second['consumer_id'] as String,
      event: const LocalEvent(
        eventId: 'legacy:fixture',
        account: _account,
        consumerSession: 'legacy',
        type: LocalEventType.messageAvailable,
        peerAccount: _peer,
        position: 1,
      ),
    );
    final _Response migrated = await post(
      '/v2/events/read',
      <String, dynamic>{
        'expected_identity': second,
        'after_cursor': 0,
        'limit': 50,
      },
      owner: ownerTwo,
    );
    expect(migrated.status, declared('migration_required'));
    expectEnvelope(migrated.body, 'migration_required');
  });
}

class _Response {
  _Response(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

Future<_Response> _postV2(
  Uri address,
  String path,
  Map<String, dynamic> body, {
  String? owner,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(address.resolve(path));
    request.headers.contentType = ContentType.json;
    if (owner != null) {
      request.headers.set(v2OwnerHeader, owner);
    }
    final List<int> bytes = utf8.encode(jsonEncode(body));
    request.contentLength = bytes.length;
    request.add(bytes);
    final HttpClientResponse response = await request.close();
    final String raw = await utf8.decoder.bind(response).join();
    final Object? decoded = raw.isEmpty ? null : jsonDecode(raw);
    return _Response(
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  } finally {
    client.close(force: true);
  }
}
