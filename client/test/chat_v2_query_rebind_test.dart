import 'dart:async';
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

/// Query completion fence: a same-owner CAS rebind during an in-flight query
/// must answer 409 stale_binding and must not leave a presentation that the
/// replacement binding could consume. Account/generation changes stay
/// stale_identity.
const String _account = '10000001';
const String _peer = '10000002';
const String _other = '10000009';
const String _consumerSession = 'query-rebind';

class _Gate {
  String? edge;
  Completer<void> entered = Completer<void>();
  Completer<void> release = Completer<void>();

  void arm(String next) {
    edge = next;
    entered = Completer<void>();
    release = Completer<void>();
  }

  Future<void> pause(String at) async {
    if (edge != at) {
      return;
    }
    edge = null;
    entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) {
      release.complete();
    }
  }
}

class _GatedApi extends ChatApiClient {
  _GatedApi({required super.baseUri, required this.gate});

  final _Gate gate;

  @override
  Future<ChatMessage?> messageById({
    required String token,
    required String messageId,
  }) async {
    final ChatMessage? message = await super.messageById(
      token: token,
      messageId: messageId,
    );
    await gate.pause('message');
    return message;
  }

  @override
  Future<MessagePage> conversation({
    required String token,
    required String account,
    int? afterPosition = 0,
    int? beforePosition,
    int limit = 50,
  }) async {
    final MessagePage page = await super.conversation(
      token: token,
      account: account,
      afterPosition: afterPosition,
      beforePosition: beforePosition,
      limit: limit,
    );
    await gate.pause('history');
    return page;
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
  late Map<String, dynamic> identity;
  late String messageId;

  final String owner = List<String>.filled(43, 'A').join();

  AuthUser user(String account) => AuthUser(
    account: account,
    username: 'user-$account',
  );

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    return _postV2(address, path, body, owner: owner);
  }

  Future<Map<String, dynamic>> auth() async {
    final Map<String, dynamic> response = await post(
      '/v2/status',
      <String, dynamic>{},
    );
    expect(response['status'], 200);
    return (response['body'] as Map<String, dynamic>)['auth']
        as Map<String, dynamic>;
  }

  Map<String, dynamic> withIdentity(Map<String, dynamic> body) =>
      <String, dynamic>{'expected_identity': identity, ...body};

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_account: 'alice', _peer: 'bob', _other: 'carol'},
    );
    root = await Directory.systemTemp.createTemp('bb-query-rebind-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    gate = _Gate();
    chat = ChatService(
      api: _GatedApi(baseUri: backend.baseUri, gate: gate),
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
    final Map<String, dynamic> current = await auth();
    final Map<String, dynamic> binding = await post(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': current,
        'session_id': _consumerSession,
      },
    );
    expect(binding['status'], 200);
    identity = (binding['body'] as Map<String, dynamic>)['identity']
        as Map<String, dynamic>;
    final String media = await backend.addImage(
      owner: _account,
      peer: _peer,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    messageId = await backend.seedMessage(
      sender: _account,
      target: _peer,
      text: 'with image',
      mediaId: media,
    );
  });

  tearDown(() async {
    gate.open();
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> rebind() async {
    final Map<String, dynamic> current = await auth();
    final Map<String, dynamic> response = await post(
      '/v2/consumers/bind',
      <String, dynamic>{
        'expected_auth': current,
        'consumer_id': identity['consumer_id'],
        'expected_binding_revision': identity['binding_revision'],
        'session_id': 'replacement',
      },
    );
    expect(response['status'], 200, reason: '${response['body']}');
    identity = (response['body'] as Map<String, dynamic>)['identity']
        as Map<String, dynamic>;
  }

  Future<void> expectNoPresentation(String consumerId) async {
    final List<PresentationReceipt> receipts = await chat.ledger
        .receiptsForPeer(
          account: _account,
          consumerSession: _consumerSession,
          peerAccount: _peer,
          consumerId: consumerId,
        );
    expect(
      receipts,
      isEmpty,
      reason: 'a stale query must not leave consumable presentation evidence',
    );
  }

  test('rebind during get_message returns 409 stale_binding without receipt',
      () async {
    final String consumerId = identity['consumer_id'] as String;
    gate.arm('message');
    final Future<Map<String, dynamic>> pending = post(
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': messageId}),
    );
    await gate.entered.future;
    await rebind();
    gate.open();
    final Map<String, dynamic> response = await pending;
    expect(response['status'], 409);
    final Map<String, dynamic> error =
        (response['body'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'stale_binding');
    await expectNoPresentation(consumerId);
  });

  test('rebind during read_messages returns 409 stale_binding without receipt',
      () async {
    final String consumerId = identity['consumer_id'] as String;
    gate.arm('history');
    final Future<Map<String, dynamic>> pending = post(
      '/v2/chat/read_messages',
      withIdentity(<String, dynamic>{
        'account': _peer,
        'after_position': 0,
        'limit': 50,
      }),
    );
    await gate.entered.future;
    await rebind();
    gate.open();
    final Map<String, dynamic> response = await pending;
    expect(response['status'], 409);
    final Map<String, dynamic> error =
        (response['body'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'stale_binding');
    await expectNoPresentation(consumerId);
  });

  test('account switch during a query stays stale_identity', () async {
    final String consumerId = identity['consumer_id'] as String;
    gate.arm('message');
    final Future<Map<String, dynamic>> pending = post(
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': messageId}),
    );
    await gate.entered.future;
    session.establish(token: backend.tokenFor(_other), user: user(_other));
    gate.open();
    final Map<String, dynamic> response = await pending;
    expect(response['status'], 409);
    final Map<String, dynamic> error =
        (response['body'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'stale_identity');
    await expectNoPresentation(consumerId);
  });

  test('same-account re-login during a query stays stale_identity', () async {
    final String consumerId = identity['consumer_id'] as String;
    gate.arm('message');
    final Future<Map<String, dynamic>> pending = post(
      '/v2/chat/get_message',
      withIdentity(<String, dynamic>{'message_id': messageId}),
    );
    await gate.entered.future;
    session.establish(token: backend.tokenFor(_account), user: user(_account));
    gate.open();
    final Map<String, dynamic> response = await pending;
    expect(response['status'], 409);
    final Map<String, dynamic> error =
        (response['body'] as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(error['code'], 'stale_identity');
    await expectNoPresentation(consumerId);
  });
}

Future<Map<String, dynamic>> _postV2(
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
    return <String, dynamic>{
      'status': response.statusCode,
      'body': decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    };
  } finally {
    client.close(force: true);
  }
}
