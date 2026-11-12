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

/// v2 local protocol (`dea467-local-v2`) against the real LocalAuthServer and a
/// labelled in-process backend. Shape/validation failures here are client
/// contract tests, not independent QA.
const String _account = '10000001';
const String _peer = '10000002';
const String _third = '10000003';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late String ledgerPath;

  final String ownerOne = List<String>.filled(43, 'A').join();
  final String ownerTwo = List<String>.filled(43, 'B').join();

  AuthUser user(String account) => AuthUser(
    account: account,
    username: account == _account
        ? 'alice'
        : account == _peer
        ? 'bob'
        : 'carol',
  );

  Future<void> startServer() async {
    final AuthService auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
    );
    server = LocalAuthServer(service: auth, chat: chat, port: 0);
    address = await server.start();
  }

  Future<Map<String, dynamic>> call(
    String path,
    Map<String, dynamic> body, {
    String? owner,
    int status = 200,
  }) async {
    final _Response response = await _postV2(
      address,
      path,
      body,
      owner: owner,
    );
    expect(
      response.status,
      status,
      reason: '$path -> ${response.body}',
    );
    return response.body;
  }

  Future<(String, String, Map<String, dynamic>)> enroll(String owner) async {
    final Map<String, dynamic> auth =
        (await call('/v2/status', <String, dynamic>{}))['auth']
            as Map<String, dynamic>;
    final Map<String, dynamic> binding = await call(
      '/v2/consumers/create',
      <String, dynamic>{'expected_auth': auth, 'session_id': 'sess-$owner'},
      owner: owner,
    );
    return (
      auth['account'] as String,
      auth['auth_generation'] as String,
      binding['identity'] as Map<String, dynamic>,
    );
  }

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_account: 'alice', _peer: 'bob', _third: 'carol'},
    );
    root = await Directory.systemTemp.createTemp('bb-v2-local-');
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
    await startServer();
  });

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('negotiate and status keep the strict v2 envelope', () async {
    final Map<String, dynamic> negotiated = await call(
      '/v2/protocol/negotiate',
      <String, dynamic>{
        'supported_versions': <int>[1, 2],
      },
    );
    expect(negotiated, <String, dynamic>{
      'selected_version': 2,
      'contract': v2Contract,
      'owner_header': v2OwnerHeader,
    });

    final Map<String, dynamic> unsupported = await call(
      '/v2/protocol/negotiate',
      <String, dynamic>{
        'supported_versions': <int>[1],
      },
      status: 426,
    );
    expect(unsupported['error']['code'], 'unsupported_version');

    await call(
      '/v2/protocol/negotiate',
      <String, dynamic>{
        'supported_versions': <int>[2],
        'extra': true,
      },
      status: 422,
    );

    final Map<String, dynamic> status = await call(
      '/v2/status',
      <String, dynamic>{},
    );
    expect(status['protocol_version'], 2);
    expect(status['auth'], <String, dynamic>{
      'account': _account,
      'auth_generation': session.identity!.authGeneration,
    });
    await call('/v2/status', <String, dynamic>{'x': 1}, status: 422);
  });

  test('owner capability enrollment is idempotent and hash-only', () async {
    await call(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': session.identity!.authGeneration,
        },
        'session_id': 'no-key',
      },
      status: 409,
    );
    await call(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': session.identity!.authGeneration,
        },
        'session_id': 'bad-key',
      },
      owner: List<String>.filled(42, 'C').join(),
      status: 409,
    );

    final Map<String, dynamic> first = await call(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': session.identity!.authGeneration,
        },
        'session_id': 'session-one',
      },
      owner: ownerOne,
    );
    expect(first['active'], isTrue);
    expect(first['migration'], 'ready');
    expect(first['session_id'], 'session-one');
    final Map<String, dynamic> identity =
        first['identity'] as Map<String, dynamic>;
    expect(identity.keys.toSet(), <String>{
      'account',
      'auth_generation',
      'consumer_id',
      'binding_revision',
    });

    // Enrollment retries never rebind or adopt a newer session id.
    final Map<String, dynamic> again = await call(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': session.identity!.authGeneration,
        },
        'session_id': 'session-two',
      },
      owner: ownerOne,
    );
    expect(again, first);

    // Wrong owner and cross-account enumeration are uniform stale_binding.
    await call(
      '/v2/consumers/get',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': session.identity!.authGeneration,
        },
        'consumer_id': identity['consumer_id'],
      },
      owner: ownerTwo,
      status: 409,
    );
    await call(
      '/v2/consumers/get',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': 'g-not-current',
        },
        'consumer_id': identity['consumer_id'],
      },
      owner: ownerOne,
      status: 409,
    );

    // Only the hash is persisted, never the raw capability.
    final String raw = await File(ledgerPath).readAsString();
    expect(raw.contains(ownerOne), isFalse);
    expect(raw.contains(ownerKeyHash(ownerOne)), isTrue);
  });

  test('bind uses owner + revision CAS and one of two competitors wins',
      () async {
    final (_, _, Map<String, dynamic> identity) = await enroll(ownerOne);
    final String consumerId = identity['consumer_id'] as String;

    await call(
      '/v2/consumers/bind',
      <String, dynamic>{
        'expected_auth': <String, dynamic>{
          'account': _account,
          'auth_generation': identity['auth_generation'],
        },
        'consumer_id': consumerId,
        'expected_binding_revision': 99,
        'session_id': 'wrong-revision',
      },
      owner: ownerOne,
      status: 409,
    );

    Future<_Response> bind(String sessionId) {
      final String generation = session.identity!.authGeneration;
      return _postV2(
        address,
        '/v2/consumers/bind',
        <String, dynamic>{
          'expected_auth': <String, dynamic>{
            'account': _account,
            'auth_generation': generation,
          },
          'consumer_id': consumerId,
          'expected_binding_revision': identity['binding_revision'],
          'session_id': sessionId,
        },
        owner: ownerOne,
      );
    }

    final List<_Response> results = await Future.wait(<Future<_Response>>[
      bind('process-one'),
      bind('process-two'),
    ]);
    final List<int> codes = results
        .map((_Response result) => result.status)
        .toList()
      ..sort();
    expect(codes, <int>[200, 409]);
    final _Response conflict = results.firstWhere(
      (_Response result) => result.status == 409,
    );
    expect(conflict.body['error']['code'], 'stale_binding');
    final _Response success = results.firstWhere(
      (_Response result) => result.status == 200,
    );
    expect(
      (success.body['identity'] as Map<String, dynamic>)['binding_revision'],
      (identity['binding_revision'] as int) + 1,
    );
  });

  test('restart keeps the consumer but invalidates the old generation', () async {
    final (_, String generation, Map<String, dynamic> identity) =
        await enroll(ownerOne);
    await call(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': identity,
        'target_account': _peer,
        'operation_id': 'pre-restart-plan',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'durable plan'},
        ],
      },
      owner: ownerOne,
    );
    final int sendsBeforeRestart = backend.sendRequests;

    // Restart: fresh session/ledger/service on the same file and a new server.
    await server.close();
    final AuthSession restarted = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    final ChatService restartedChat = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: restarted,
      ledger: ChatLedger.atPath(ledgerPath),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
    final AuthService auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: restarted,
    );
    final LocalAuthServer restartedServer = LocalAuthServer(
      service: auth,
      chat: restartedChat,
      port: 0,
    );
    final Uri restartedAddress = await restartedServer.start();
    try {
      final _Response status = await _postV2(
        restartedAddress,
        '/v2/status',
        <String, dynamic>{},
      );
      final String newGeneration =
          (status.body['auth'] as Map<String, dynamic>)['auth_generation']
              as String;
      expect(newGeneration, isNot(generation));

      final _Response get = await _postV2(
        restartedAddress,
        '/v2/consumers/get',
        <String, dynamic>{
          'expected_auth': <String, dynamic>{
            'account': _account,
            'auth_generation': newGeneration,
          },
          'consumer_id': identity['consumer_id'],
        },
        owner: ownerOne,
      );
      expect(get.status, 200);
      expect(get.body['active'], isFalse);
      expect(get.body['identity'], identity);

      // The old generation cannot authorize protected work.
      final _Response stale = await _postV2(
        restartedAddress,
        '/v2/chat/consumption',
        <String, dynamic>{
          'expected_identity': identity,
          'account': _peer,
        },
        owner: ownerOne,
      );
      expect(stale.status, 409);
      expect(stale.body['error']['code'], 'stale_identity');

      // Explicit bind with the current revision adopts the new generation.
      final _Response bound = await _postV2(
        restartedAddress,
        '/v2/consumers/bind',
        <String, dynamic>{
          'expected_auth': <String, dynamic>{
            'account': _account,
            'auth_generation': newGeneration,
          },
          'consumer_id': identity['consumer_id'],
          'expected_binding_revision': identity['binding_revision'],
          'session_id': 'after-restart',
        },
        owner: ownerOne,
      );
      expect(bound.status, 200);
      expect(bound.body['active'], isTrue);
      final Map<String, dynamic> rebound =
          bound.body['identity'] as Map<String, dynamic>;
      expect(
        rebound['binding_revision'],
        (identity['binding_revision'] as int) + 1,
      );
      expect(rebound['auth_generation'], newGeneration);

      // A plan accepted before the restart is only queried under the rebound
      // identity: original operation_id, zero resends.
      final _Response operation = await _postV2(
        restartedAddress,
        '/v2/operations/get',
        <String, dynamic>{
          'expected_identity': rebound,
          'operation_id': 'pre-restart-plan',
        },
        owner: ownerOne,
      );
      expect(operation.status, 200);
      expect(operation.body['result']['status'], 'succeeded');
      expect(operation.body['result']['operation_id'], 'pre-restart-plan');
      expect(backend.sendRequests, sendsBeforeRestart);
    } finally {
      await restartedServer.close();
      await restartedChat.dispose();
    }
  });

  test('business replies wrap the validated identity and isolate consumers',
      () async {
    await backend.seedMessage(sender: _peer, target: _account, text: 'p1');
    await backend.seedMessage(sender: _peer, target: _account, text: 'p2');

    final (_, _, Map<String, dynamic> first) = await enroll(ownerOne);
    final (_, _, Map<String, dynamic> second) = await enroll(ownerTwo);
    final String firstId = first['consumer_id'] as String;
    final String secondId = second['consumer_id'] as String;
    expect(firstId, isNot(secondId));

    final Map<String, dynamic> read = await call(
      '/v2/chat/read_messages',
      <String, dynamic>{
        'expected_identity': first,
        'account': _peer,
        'after_position': 0,
        'limit': 100,
      },
      owner: ownerOne,
    );
    expect(read['identity'], first);
    final List<dynamic> items = read['result']['items'] as List<dynamic>;
    expect(items, hasLength(2));
    final List<String> receipts = <String>[
      for (final dynamic item in items)
        (item['presentation'] as Map<String, dynamic>)['receipt_id'] as String,
    ];
    final int through =
        ((items.last as Map<String, dynamic>)['message']
            as Map<String, dynamic>)['position']
            as int;

    final Map<String, dynamic> confirmed = await call(
      '/v2/chat/confirm_presentation',
      <String, dynamic>{
        'expected_identity': first,
        'attempt_id': 'attempt-one',
        'request_digest': List<String>.filled(64, 'a').join(),
        'receipt_ids': receipts,
      },
      owner: ownerOne,
    );
    expect(
      (confirmed['result']['confirmed_receipt_ids'] as List<dynamic>).toSet(),
      receipts.toSet(),
    );

    final Map<String, dynamic> ack = await call(
      '/v2/chat/ack_messages',
      <String, dynamic>{
        'expected_identity': first,
        'account': _peer,
        'through_position': through,
      },
      owner: ownerOne,
    );
    expect(ack['result']['consumed_through'], through);

    // Second consumer cannot inherit the first cursor.
    final Map<String, dynamic> gap = await call(
      '/v2/chat/ack_messages',
      <String, dynamic>{
        'expected_identity': second,
        'account': _peer,
        'through_position': through,
      },
      owner: ownerTwo,
      status: 409,
    );
    expect(gap['error']['code'], 'consumption_gap');
    final Map<String, dynamic> consumption = await call(
      '/v2/chat/consumption',
      <String, dynamic>{'expected_identity': second, 'account': _peer},
      owner: ownerTwo,
    );
    expect(consumption['result'], <String, dynamic>{
      'consumed_through': 0,
      'migration': 'ready',
    });

    // A known consumer id plus another owner key is not authority.
    final Map<String, dynamic> wrongOwner = await call(
      '/v2/chat/consumption',
      <String, dynamic>{'expected_identity': first, 'account': _peer},
      owner: ownerTwo,
      status: 409,
    );
    expect(wrongOwner['error']['code'], 'stale_binding');

    // Distinct consumers may reuse the same logical attempt id; each keeps its
    // own receipts and cursor.
    final Map<String, dynamic> secondRead = await call(
      '/v2/chat/read_messages',
      <String, dynamic>{
        'expected_identity': second,
        'account': _peer,
        'after_position': 0,
        'limit': 100,
      },
      owner: ownerTwo,
    );
    final List<dynamic> secondItems =
        secondRead['result']['items'] as List<dynamic>;
    final Map<String, dynamic> secondConfirm = await call(
      '/v2/chat/confirm_presentation',
      <String, dynamic>{
        'expected_identity': second,
        'attempt_id': 'attempt-one',
        'request_digest': List<String>.filled(64, 'a').join(),
        'receipt_ids': <String>[
          for (final dynamic item in secondItems)
            (item['presentation'] as Map<String, dynamic>)['receipt_id']
                as String,
        ],
      },
      owner: ownerTwo,
    );
    expect(
      (secondConfirm['result']['confirmed_receipt_ids'] as List<dynamic>),
      isNotEmpty,
    );
    final Map<String, dynamic> secondAck = await call(
      '/v2/chat/ack_messages',
      <String, dynamic>{
        'expected_identity': second,
        'account': _peer,
        'through_position': through,
      },
      owner: ownerTwo,
    );
    expect(secondAck['result']['consumed_through'], through);

    // Operations belong to the consumer that accepted them.
    final Map<String, dynamic> sent = await call(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': first,
        'target_account': _peer,
        'operation_id': 'v2-send-one',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'hello v2'},
        ],
      },
      owner: ownerOne,
    );
    expect(sent['identity'], first);
    final Map<String, dynamic> operation = await call(
      '/v2/operations/get',
      <String, dynamic>{
        'expected_identity': first,
        'operation_id': 'v2-send-one',
      },
      owner: ownerOne,
    );
    expect(operation['result']['status'], 'succeeded');
    expect(operation['result']['operation_id'], 'v2-send-one');
    final Map<String, dynamic> foreign = await call(
      '/v2/operations/get',
      <String, dynamic>{
        'expected_identity': second,
        'operation_id': 'v2-send-one',
      },
      owner: ownerTwo,
      status: 404,
    );
    expect(foreign['error']['code'], 'not_found');

    // A stale generation never sends.
    final int before = backend.sendRequests;
    session.establish(token: backend.tokenFor(_account), user: user(_account));
    final Map<String, dynamic> stale = await call(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': first,
        'target_account': _peer,
        'operation_id': 'v2-send-after-switch',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'must not send'},
        ],
      },
      owner: ownerOne,
      status: 409,
    );
    expect(stale['error']['code'], 'stale_identity');
    expect(backend.sendRequests, before);
  });

  test('strict validation runs before auth and never echoes input', () async {
    // Logged-out server: schema errors must still be 422, not 401.
    final AuthSession anonymous = AuthSession();
    final ChatService anonymousChat = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: anonymous,
      ledger: ChatLedger.inMemory(),
      cacheRoot: Directory('${root.path}/anon'),
      webSocketHints: false,
    );
    final LocalAuthServer anonymousServer = LocalAuthServer(
      service: AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: anonymous,
      ),
      chat: anonymousChat,
      port: 0,
    );
    final Uri anonymousAddress = await anonymousServer.start();
    try {
      final _Response missing = await _postV2(
        anonymousAddress,
        '/v2/chat/send_message',
        <String, dynamic>{
          'target_account': _peer,
          'operation_id': 'op-1',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'x'},
          ],
        },
      );
      expect(missing.status, 422);
      expect(missing.body['error']['fields'], <String>['expected_identity']);

      final Map<String, dynamic> identity = <String, dynamic>{
        'account': _account,
        'auth_generation': 'secret-generation-value',
        'consumer_id': 'consumer-x',
        'binding_revision': true,
      };
      final _Response badRevision = await _postV2(
        anonymousAddress,
        '/v2/chat/send_message',
        <String, dynamic>{
          'expected_identity': identity,
          'target_account': _peer,
          'operation_id': 'op-1',
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'x'},
          ],
        },
      );
      expect(badRevision.status, 422);
      expect(
        jsonEncode(badRevision.body).contains('secret-generation-value'),
        isFalse,
      );

      final _Response unknownField = await _postV2(
        anonymousAddress,
        '/v2/chat/ack_messages',
        <String, dynamic>{
          'expected_identity': <String, dynamic>{
            'account': _account,
            'auth_generation': 'g-1',
            'consumer_id': 'c-1',
            'binding_revision': 1,
          },
          'account': _peer,
          'through_position': 1,
          'unknown_key': 'do-not-echo',
        },
      );
      expect(unknownField.status, 422);
      expect(unknownField.body['error']['fields'], <String>['body']);
      expect(jsonEncode(unknownField.body).contains('do-not-echo'), isFalse);

      // A valid schema with no login is 401, not a schema error.
      final _Response unauthenticated = await _postV2(
        anonymousAddress,
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
      expect(unauthenticated.status, 401);
      expect(unauthenticated.body['error']['code'], 'unauthenticated');
    } finally {
      await anonymousServer.close();
      await anonymousChat.dispose();
    }
  });

  test('v2 events carry version 2 and their origin identity', () async {
    final (_, _, Map<String, dynamic> first) = await enroll(ownerOne);
    await backend.seedMessage(sender: _peer, target: _account, text: 'e1');

    await call(
      '/v2/events/subscribe',
      <String, dynamic>{
        'expected_identity': first,
        'peer_account': _peer,
      },
      owner: ownerOne,
    );
    await chat.eventFeed.pollOnce();

    final Map<String, dynamic> page = await call(
      '/v2/events/read',
      <String, dynamic>{
        'expected_identity': first,
        'after_cursor': 0,
        'limit': 50,
      },
      owner: ownerOne,
    );
    final List<dynamic> items = page['result']['items'] as List<dynamic>;
    expect(items, isNotEmpty);
    final Map<String, dynamic> event =
        (items.last as Map<String, dynamic>)['event'] as Map<String, dynamic>;
    expect(event['version'], 2);
    expect(event['origin_identity'], first);
    expect(event['type'], 'message.available');
    expect(
      RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(event['event_id'] as String),
      isTrue,
    );

    // A consumer whose events were admitted without an origin cannot be
    // re-labelled with the caller's binding.
    await chat.ledger.appendLocalEvent(
      account: _account,
      consumerSession: first['consumer_id'] as String,
      event: const LocalEvent(
        eventId: 'legacy:1',
        account: _account,
        consumerSession: 'legacy',
        type: LocalEventType.messageAvailable,
        peerAccount: _peer,
        position: 1,
      ),
    );
    final Map<String, dynamic> legacy = await call(
      '/v2/events/read',
      <String, dynamic>{
        'expected_identity': first,
        'after_cursor': 0,
        'limit': 50,
      },
      owner: ownerOne,
      status: 409,
    );
    expect(legacy['error']['code'], 'migration_required');
  });

  test('v2 downloads keep their origin identity', () async {
    final (_, _, Map<String, dynamic> identity) = await enroll(ownerOne);
    final String mediaId = await backend.addMedia(
      owner: _peer,
      peer: _account,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      mime: 'image/png',
      kind: 'image',
      filename: 'pic.png',
    );
    final Map<String, dynamic> started = await call(
      '/v2/downloads/start',
      <String, dynamic>{
        'expected_identity': identity,
        'operation_id': 'v2-download-one',
        'media_id': mediaId,
        'directory': null,
      },
      owner: ownerOne,
      status: 202,
    );
    final Map<String, dynamic> task = started['result'] as Map<String, dynamic>;
    expect(task['origin_identity'], identity);
    expect(task['operation_id'], 'v2-download-one');
    expect(task['status'], isIn(<String>['pending', 'running', 'succeeded']));

    final Map<String, dynamic> got = await call(
      '/v2/downloads/get',
      <String, dynamic>{
        'expected_identity': identity,
        'task_id': task['task_id'],
      },
      owner: ownerOne,
    );
    expect(got['result']['origin_identity'], identity);

    // A task stored before v2 (no origin) is never re-labelled.
    await chat.ledger.saveDownload(
      _account,
      DownloadTask(
        taskId: 'legacy-task',
        operationId: 'legacy-op',
        consumerSession: identity['consumer_id'] as String,
        status: DownloadStatus.succeeded,
        plannedPath: '/tmp/legacy',
        actualPath: '/tmp/legacy',
      ),
    );
    final Map<String, dynamic> legacy = await call(
      '/v2/downloads/get',
      <String, dynamic>{
        'expected_identity': identity,
        'task_id': 'legacy-task',
      },
      owner: ownerOne,
      status: 409,
    );
    expect(legacy['error']['code'], 'migration_required');
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
  String? token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(address.resolve(path));
    request.headers.contentType = ContentType.json;
    if (owner != null) {
      request.headers.set(v2OwnerHeader, owner);
    }
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
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
