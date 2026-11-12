import 'dart:async';
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

/// `admitted-send-switch`: the remote send commits, the response is paused,
/// the account switches, then the call continues. The original account's
/// succeeded fact must survive and the stale caller must get 409
/// `stale_identity` — never a fabricated 401/failed outcome and no resend.
const String _account = '10000001';
const String _peer = '10000002';
const String _other = '10000009';

class _Gate {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  Future<void> pause() async {
    if (!entered.isCompleted) {
      entered.complete();
    }
    await release.future;
  }
}

class _GatedApi extends ChatApiClient {
  _GatedApi({required super.baseUri, required this.gate});

  final _Gate gate;

  @override
  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    final ChatMessage message = await super.sendMessage(
      token: token,
      targetAccount: targetAccount,
      clientNonce: clientNonce,
      content: content,
    );
    await gate.pause();
    return message;
  }

  @override
  Future<ChatMessage> sendAttachment({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required String mediaId,
  }) async {
    final ChatMessage message = await super.sendAttachment(
      token: token,
      targetAccount: targetAccount,
      clientNonce: clientNonce,
      mediaId: mediaId,
    );
    await gate.pause();
    return message;
  }
}

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late _Gate gate;

  final String owner = List<String>.filled(43, 'A').join();

  AuthUser user(String account) => AuthUser(
    account: account,
    username: account == _account ? 'alice' : 'bob',
  );

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_account: 'alice', _peer: 'bob', _other: 'carol'},
    );
    root = await Directory.systemTemp.createTemp('bb-admitted-send-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    gate = _Gate();
    chat = ChatService(
      api: _GatedApi(baseUri: backend.baseUri, gate: gate),
      session: session,
      ledger: ChatLedger.atPath('${root.path}/chat-ledger.json'),
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
  });

  tearDown(() async {
    if (!gate.release.isCompleted) {
      gate.release.complete();
    }
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    String? ownerKey,
    required int status,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(
        address.resolve(path),
      );
      request.headers.contentType = ContentType.json;
      if (ownerKey != null) {
        request.headers.set(v2OwnerHeader, ownerKey);
      }
      final List<int> bytes = utf8.encode(jsonEncode(body));
      request.contentLength = bytes.length;
      request.add(bytes);
      final HttpClientResponse response = await request.close();
      final String raw = await utf8.decoder.bind(response).join();
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      expect(
        response.statusCode,
        status,
        reason: '$path -> $decoded',
      );
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> auth() async =>
      (await post('/v2/status', <String, dynamic>{}, status: 200))['auth']
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> enroll() async {
    final Map<String, dynamic> current = await auth();
    final Map<String, dynamic> binding = await post(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': current,
        'session_id': 'admitted-send',
      },
      ownerKey: owner,
      status: 200,
    );
    return binding['identity'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> rebind(Map<String, dynamic> identity) async {
    final Map<String, dynamic> current = await auth();
    final Map<String, dynamic> binding = await post(
      '/v2/consumers/get',
      <String, dynamic>{
        'expected_auth': current,
        'consumer_id': identity['consumer_id'],
      },
      ownerKey: owner,
      status: 200,
    );
    final Map<String, dynamic> bound = await post(
      '/v2/consumers/bind',
      <String, dynamic>{
        'expected_auth': current,
        'consumer_id': identity['consumer_id'],
        'expected_binding_revision':
            (binding['identity'] as Map<String, dynamic>)['binding_revision'],
        'session_id': 'admitted-recovered',
      },
      ownerKey: owner,
      status: 200,
    );
    return bound['identity'] as Map<String, dynamic>;
  }

  Future<void> expectSucceededFactPreserved(
    String operationId,
    int sends,
  ) async {
    expect(backend.sendRequests, sends);
    expect(backend.sendRequestAccounts, List<String>.filled(sends, _account));
    final Map<String, dynamic> doc =
        jsonDecode(await File('${root.path}/chat-ledger.json').readAsString())
            as Map<String, dynamic>;
    final Map<String, dynamic> accounts =
        doc['accounts'] as Map<String, dynamic>;
    final Map<String, dynamic> original =
        (accounts[_account] as Map<String, dynamic>)['operations']
            as Map<String, dynamic>;
    expect(
      (original[operationId] as Map<String, dynamic>)['state'],
      'succeeded',
    );
    final Map<String, dynamic> otherState =
        (accounts[_other] as Map<String, dynamic>?) ?? <String, dynamic>{};
    expect(
      (otherState['operations'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      isNot(contains(operationId)),
    );
  }

  test('body send committed then switched returns 409 and keeps the fact',
      () async {
    final Map<String, dynamic> identity = await enroll();
    final Future<Map<String, dynamic>> pending = post(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': identity,
        'target_account': _peer,
        'operation_id': 'admitted-original',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'synthetic admitted send'},
        ],
      },
      ownerKey: owner,
      status: 409,
    );
    await gate.entered.future;
    // The switch happens while the remote success is paused in the client.
    session.establish(token: backend.tokenFor(_other), user: user(_other));
    gate.release.complete();
    final Map<String, dynamic> response = await pending;
    expect(response['error']['code'], staleIdentityCode);

    await expectSucceededFactPreserved('admitted-original', 1);

    // Recovering under the original account only queries: no resend.
    session.establish(token: backend.tokenFor(_account), user: user(_account));
    final Map<String, dynamic> recovered = await rebind(identity);
    final Map<String, dynamic> queried = await post(
      '/v2/operations/get',
      <String, dynamic>{
        'expected_identity': recovered,
        'operation_id': 'admitted-original',
      },
      ownerKey: owner,
      status: 200,
    );
    expect(queried['result']['status'], 'succeeded');
    expect(queried['result']['operation_id'], 'admitted-original');
    expect(backend.sendRequests, 1);
    expect(backend.sendRequestAccounts, <String>[_account]);
  });

  test('attachment send committed then switched returns 409 and keeps the fact',
      () async {
    final Map<String, dynamic> identity = await enroll();
    final File source = File('${root.path}/synthetic.pdf')
      ..writeAsBytesSync(<int>[37, 80, 68, 70, 45, 49]);
    final Future<Map<String, dynamic>> pending = post(
      '/v2/chat/send_attachment',
      <String, dynamic>{
        'expected_identity': identity,
        'target_account': _peer,
        'operation_id': 'admitted-attachment',
        'source': <String, dynamic>{
          'base64': null,
          'path': source.path,
          'url': null,
          'mime_type': 'application/pdf',
          'filename': 'synthetic.pdf',
        },
        'cover': null,
      },
      ownerKey: owner,
      status: 409,
    );
    await gate.entered.future;
    session.establish(token: backend.tokenFor(_other), user: user(_other));
    gate.release.complete();
    final Map<String, dynamic> response = await pending;
    expect(response['error']['code'], staleIdentityCode);

    await expectSucceededFactPreserved('admitted-attachment', 1);
  });

  test('a genuine logged-out call stays 401', () async {
    final Map<String, dynamic> identity = await enroll();
    session.clear();
    final Map<String, dynamic> response = await post(
      '/v2/chat/send_message',
      <String, dynamic>{
        'expected_identity': identity,
        'target_account': _peer,
        'operation_id': 'no-session',
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'must not send'},
        ],
      },
      ownerKey: owner,
      status: 401,
    );
    expect(response['error']['code'], 'unauthenticated');
    expect(backend.sendRequests, 0);
  });
}
