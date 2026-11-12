import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

/// Local control API contract for the nine STEP-3 tools plus the R3
/// presentation/event additions. Uses the labelled in-process double; the real
/// FastAPI chain is in `live_chat_e2e_test.dart`.
void main() {
  const String accountA = '10000001';
  const String accountB = '10000002';
  const String accountC = '10000003';
  late FakeChatBackend backend;
  late Directory root;
  late ChatService chatA;
  late ChatService chatB;
  late LocalAuthServer server;
  late Uri address;

  Future<void> setUpAllAccounts() async {}

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{
        accountA: 'alice',
        accountB: 'bob',
        accountC: 'carol',
      },
    );
    root = await Directory.systemTemp.createTemp('bb-local-chat-');
    chatA = _chatFor(backend, root, accountA, 'alice');
    chatB = _chatFor(backend, root, accountB, 'bob');
    final AuthService auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: chatA.session,
    );
    server = LocalAuthServer(service: auth, chat: chatA, port: 0);
    address = await server.start();
  });

  tearDown(() async {
    await server.close();
    await chatA.dispose();
    await chatB.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('unauthenticated local chat calls are 401', () async {
    final AuthUser user = chatA.session.user!;
    final String token = chatA.session.tokenForRequest!;
    chatA.session.clear();
    try {
      final _Response response = await _post(
        address.resolve('/chat/list_users'),
        <String, dynamic>{},
        token: null,
      );
      expect(response.status, 401);
    } finally {
      chatA.session.establish(token: token, user: user);
    }
  });

  test('list_users excludes self and honours pagination fields', () async {
    final _Response response = await _post(
      address.resolve('/chat/list_users'),
      <String, dynamic>{'limit': 1},
      token: backend.tokenFor(accountA),
    );
    expect(response.status, 200);
    final List<dynamic> items = response.body['items'] as List<dynamic>;
    expect(items, hasLength(1));
    expect((items.single as Map<String, dynamic>)['account'], accountB);
    expect(response.body['next_cursor'], accountB);
  });

  test('send_message preserves text/image order and is idempotent', () async {
    final Map<String, dynamic> payload = <String, dynamic>{
      'target_account': accountB,
      'operation_id': 'local-send-1',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'before'},
        <String, dynamic>{
          'type': 'image',
          'source': <String, dynamic>{
            'base64': _png,
            'filename': 'one.png',
            'mime_type': 'image/png',
          },
        },
        <String, dynamic>{'type': 'text', 'text': 'after'},
      ],
    };
    final _Response first = await _post(
      address.resolve('/chat/send_message'),
      payload,
      token: backend.tokenFor(accountA),
    );
    expect(first.status, 200, reason: jsonEncode(first.body));
    final Map<String, dynamic> message = first.body;
    final List<dynamic> content = message['content'] as List<dynamic>;
    expect((content[0] as Map<String, dynamic>)['type'], 'text');
    expect((content[1] as Map<String, dynamic>)['type'], 'image');
    expect((content[2] as Map<String, dynamic>)['type'], 'text');

    final _Response replay = await _post(
      address.resolve('/chat/send_message'),
      payload,
      token: backend.tokenFor(accountA),
    );
    expect(replay.status, 200);
    expect(replay.body['id'], message['id']);

    final _Response conflict = await _post(
      address.resolve('/chat/send_message'),
      <String, dynamic>{
        'target_account': accountB,
        'operation_id': 'local-send-1',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'changed'},
        ],
      },
      token: backend.tokenFor(accountA),
    );
    expect(conflict.status, 409);
    expect(conflict.body['error']['code'], 'conflict');
  });

  test(
    'a definitively failed send can be retried with the same operation id',
    () async {
      backend.failNextSendStatus = 503;
      final Map<String, dynamic> payload = <String, dynamic>{
        'target_account': accountB,
        'operation_id': 'retry-send-1',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'retry me'},
        ],
      };
      final _Response failed = await _post(
        address.resolve('/chat/send_message'),
        payload,
        token: backend.tokenFor(accountA),
      );
      expect(failed.status, 503);

      final _Response retried = await _post(
        address.resolve('/chat/send_message'),
        payload,
        token: backend.tokenFor(accountA),
      );
      expect(retried.status, 200, reason: jsonEncode(retried.body));
      final _Response replay = await _post(
        address.resolve('/chat/send_message'),
        payload,
        token: backend.tokenFor(accountA),
      );
      expect(replay.status, 200);
      expect(replay.body['id'], retried.body['id']);
    },
  );

  test(
    'read/confirm/ack enforces display evidence and gap semantics',
    () async {
      await chatA.sendBody(
        targetAccount: accountB,
        content: <OutgoingPart>[const OutgoingText('hello bob')],
      );
      final _Response read = await _post(
        address.resolve('/chat/read_messages'),
        <String, dynamic>{'account': accountB, 'consumer_session': 's1'},
        token: backend.tokenFor(accountA),
      );
      expect(read.status, 200);
      final List<dynamic> items = read.body['items'] as List<dynamic>;
      expect(items, hasLength(1));
      final Map<String, dynamic> visible = items.single as Map<String, dynamic>;
      final Map<String, dynamic> presentation =
          visible['presentation'] as Map<String, dynamic>;
      expect(presentation['receipt_id'], isA<String>());
      expect(presentation['content_digest'], isA<String>());

      final _Response ackGap = await _post(
        address.resolve('/chat/ack_messages'),
        <String, dynamic>{
          'account': accountB,
          'consumer_session': 's1',
          'through_position': 1,
        },
        token: backend.tokenFor(accountA),
      );
      expect(ackGap.status, 409);
      expect(ackGap.body['error']['code'], 'consumption_gap');

      final _Response confirm = await _post(
        address.resolve('/chat/confirm_presentation'),
        <String, dynamic>{
          'consumer_session': 's1',
          'attempt_id': 'attempt-1',
          'request_digest': 'digest-1',
          'receipt_ids': <String>[presentation['receipt_id']],
        },
        token: backend.tokenFor(accountA),
      );
      expect(confirm.status, 200);
      expect(confirm.body['confirmed_receipt_ids'], <String>[
        presentation['receipt_id'],
      ]);

      final _Response ack = await _post(
        address.resolve('/chat/ack_messages'),
        <String, dynamic>{
          'account': accountB,
          'consumer_session': 's1',
          'through_position': 1,
        },
        token: backend.tokenFor(accountA),
      );
      expect(ack.status, 200);
      expect(ack.body['consumed_through'], 1);

      // Unknown receipt is 404, another consumer is a conflict.
      final _Response wrongConsumer = await _post(
        address.resolve('/chat/confirm_presentation'),
        <String, dynamic>{
          'consumer_session': 's2',
          'attempt_id': 'attempt-2',
          'request_digest': 'digest-2',
          'receipt_ids': <String>[presentation['receipt_id']],
        },
        token: backend.tokenFor(accountA),
      );
      expect(wrongConsumer.status, 409);
      final _Response unknown = await _post(
        address.resolve('/chat/confirm_presentation'),
        <String, dynamic>{
          'consumer_session': 's1',
          'attempt_id': 'attempt-3',
          'request_digest': 'digest-3',
          'receipt_ids': <String>['missing'],
        },
        token: backend.tokenFor(accountA),
      );
      expect(unknown.status, 404);
    },
  );

  test('attachment send, async download and operation query', () async {
    final Uint8List pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.4\nprobe\n%%EOF\n'),
    );
    final _Response sent = await _post(
      address.resolve('/chat/send_attachment'),
      <String, dynamic>{
        'target_account': accountB,
        'operation_id': 'local-file-1',
        'source': <String, dynamic>{
          'base64': base64Encode(pdf),
          'filename': 'note.pdf',
          'mime_type': 'application/pdf',
        },
      },
      token: backend.tokenFor(accountA),
    );
    expect(sent.status, 200, reason: jsonEncode(sent.body));
    final Map<String, dynamic> attachment =
        sent.body['attachment'] as Map<String, dynamic>;
    final String mediaId = attachment['media_id'] as String;
    expect(attachment['byte_size'], pdf.length);

    final _Response started = await _post(
      address.resolve('/downloads/start'),
      <String, dynamic>{
        'operation_id': 'local-dl-1',
        'consumer_session': 's1',
        'media_id': mediaId,
      },
      token: backend.tokenFor(accountA),
    );
    expect(started.status, 202, reason: jsonEncode(started.body));
    final String taskId = started.body['task_id'] as String;
    expect(started.body['actual_path'], isNull);
    expect(started.body['planned_path'], isA<String>());

    Map<String, dynamic>? task;
    for (int i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final _Response got = await _post(
        address.resolve('/downloads/get'),
        <String, dynamic>{'task_id': taskId, 'consumer_session': 's1'},
        token: backend.tokenFor(accountA),
      );
      expect(got.status, 200);
      task = got.body;
      if (task['status'] == 'succeeded' || task['status'] == 'failed') {
        break;
      }
    }
    expect(task!['status'], 'succeeded');
    expect(await File(task['actual_path'] as String).readAsBytes(), pdf);

    final _Response op = await _post(
      address.resolve('/operations/get'),
      <String, dynamic>{'operation_id': 'local-dl-1'},
      token: backend.tokenFor(accountA),
    );
    expect(op.status, 200);
    expect(op.body['kind'], 'download');
    expect(op.body['status'], 'succeeded');
    expect(op.body['task_id'], taskId);

    // Same start call is the same task.
    final _Response again = await _post(
      address.resolve('/downloads/start'),
      <String, dynamic>{
        'operation_id': 'local-dl-1',
        'consumer_session': 's1',
        'media_id': mediaId,
      },
      token: backend.tokenFor(accountA),
    );
    expect(again.status, 202);
    expect(again.body['task_id'], taskId);
  });

  test(
    'events subscribe/read deliver a message.available after readability',
    () async {
      final _Response subscribed = await _post(
        address.resolve('/events/subscribe'),
        <String, dynamic>{
          'consumer_session': 'evt-1',
          'peer_account': accountB,
        },
        token: backend.tokenFor(accountA),
      );
      expect(subscribed.status, 200);
      expect(subscribed.body['peer_account'], accountB);

      await chatB.sendBody(
        targetAccount: accountA,
        content: <OutgoingPart>[const OutgoingText('event hello')],
      );
      await chatA.eventFeed.pollOnce();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await chatA.eventFeed.pollOnce();

      final _Response read = await _post(
        address.resolve('/events/read'),
        <String, dynamic>{'consumer_session': 'evt-1', 'after_cursor': 0},
        token: backend.tokenFor(accountA),
      );
      expect(read.status, 200);
      final List<dynamic> items = read.body['items'] as List<dynamic>;
      expect(items, isNotEmpty);
      final Map<String, dynamic> event =
          (items.last as Map<String, dynamic>)['event'] as Map<String, dynamic>;
      expect(event['type'], 'message.available');
      expect(event['peer_account'], accountB);
      expect(read.body['next_cursor'], isA<int>());
    },
  );

  test(
    'events/wait accepts limit 1..100, defaults 50 and rejects invalid values',
    () async {
      await chatB.subscribeEvents(
        consumerSession: 'wait-limit',
        peerAccount: accountA,
      );
      for (int i = 0; i < 3; i++) {
        await chatB.sendBody(
          targetAccount: accountA,
          content: <OutgoingPart>[OutgoingText('limit $i')],
        );
      }
      await chatA.subscribeEvents(
        consumerSession: 'wait-limit',
        peerAccount: accountB,
      );
      await chatA.eventFeed.pollOnce();

      final _Response bounded = await _post(
        address.resolve('/events/wait'),
        <String, dynamic>{
          'consumer_session': 'wait-limit',
          'after_cursor': 0,
          'limit': 2,
          'timeout': 30,
        },
        token: backend.tokenFor(accountA),
      );
      expect(bounded.status, 200, reason: jsonEncode(bounded.body));
      expect((bounded.body['items'] as List<dynamic>), hasLength(2));
      expect(bounded.body['has_more'], isTrue);
      expect(bounded.body['reason'], 'events');

      final _Response defaulted = await _post(
        address.resolve('/events/wait'),
        <String, dynamic>{
          'consumer_session': 'wait-limit',
          'after_cursor': 0,
          'timeout': 30,
        },
        token: backend.tokenFor(accountA),
      );
      expect(defaulted.status, 200);
      expect((defaulted.body['items'] as List<dynamic>), hasLength(3));

      for (final int invalid in <int>[0, 101]) {
        final _Response rejected = await _post(
          address.resolve('/events/wait'),
          <String, dynamic>{
            'consumer_session': 'wait-limit',
            'after_cursor': 0,
            'limit': invalid,
            'timeout': 30,
          },
          token: backend.tokenFor(accountA),
        );
        expect(rejected.status, 422, reason: 'limit $invalid');
        expect(rejected.body['error']['code'], 'validation_error');
      }

      final _Response readInvalid = await _post(
        address.resolve('/events/read'),
        <String, dynamic>{
          'consumer_session': 'wait-limit',
          'after_cursor': 0,
          'limit': 101,
        },
        token: backend.tokenFor(accountA),
      );
      expect(readInvalid.status, 422);
    },
  );

  test('unknown fields and invalid values keep the strict envelope', () async {
    final _Response extra = await _post(
      address.resolve('/chat/list_users'),
      <String, dynamic>{'after_account': '', 'unexpected': true},
      token: backend.tokenFor(accountA),
    );
    expect(extra.status, 422);
    expect(extra.body['error']['code'], 'validation_error');

    final _Response badTimeout = await _post(
      address.resolve('/chat/wait_messages'),
      <String, dynamic>{
        'account': accountB,
        'consumer_session': 's1',
        'seen_position': 0,
        'timeout': 15,
      },
      token: backend.tokenFor(accountA),
    );
    expect(badTimeout.status, 422);
  });

  test('local wait returns an arriving message before its deadline', () async {
    final Future<_Response> waiting = _post(
      address.resolve('/chat/wait_messages'),
      <String, dynamic>{
        'account': accountB,
        'consumer_session': 'wait-1',
        'seen_position': 0,
        'timeout': 30,
      },
      token: backend.tokenFor(accountA),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await chatB.sendBody(
      targetAccount: accountA,
      content: <OutgoingPart>[const OutgoingText('arrived while waiting')],
    );
    final _Response result = await waiting;
    expect(result.status, 200);
    expect(result.body['reason'], 'messages');
    expect((result.body['items'] as List<dynamic>), isNotEmpty);
  });

  setUpAll(setUpAllAccounts);
}

ChatService _chatFor(
  FakeChatBackend backend,
  Directory root,
  String account,
  String username,
) {
  final AuthSession session = AuthSession()
    ..establish(
      token: backend.tokenFor(account),
      user: AuthUser(account: account, username: username),
    );
  return ChatService(
    api: ChatApiClient(baseUri: backend.baseUri),
    session: session,
    ledger: ChatLedger.atPath('${root.path}/ledger-$account.json'),
    cacheRoot: Directory('${root.path}/cache-$account'),
    webSocketHints: false,
  );
}

const String _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=';

Future<_Response> _post(
  Uri uri,
  Map<String, dynamic> body, {
  String? token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(uri);
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final List<int> bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
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

class _Response {
  _Response(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}
