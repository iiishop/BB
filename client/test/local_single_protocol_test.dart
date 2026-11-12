import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
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

/// Single-protocol contract: the old unauthenticated v1 business routes are
/// removed, every first-party business call needs owner plus expected identity,
/// and the stable consumer survives a restart from the same on-disk ledger.
const String _account = '10000001';
const String _owner = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late String ledgerPath;
  late AuthSession session;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_account: 'alice'},
    );
    root = await Directory.systemTemp.createTemp('bb-single-protocol-');
    ledgerPath = '${root.path}/ledger.json';
    session = AuthSession()
      ..establish(
        token: backend.tokenFor(_account),
        user: const AuthUser(account: _account, username: 'alice'),
      );
    chat = _chat(backend, root, ledgerPath, session);
    final AuthService auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: chat.session,
    );
    server = LocalAuthServer(service: auth, chat: chat, port: 0);
    address = await server.start();
  });

  tearDown(() async {
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
    String? owner,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(address.resolve(path));
      request.headers.contentType = ContentType.json;
      if (owner != null) request.headers.set(v2OwnerHeader, owner);
      request.write(jsonEncode(body));
      final HttpClientResponse response = await request.close();
      final String raw = await utf8.decoder.bind(response).join();
      return <String, dynamic>{
        'status': response.statusCode,
        'body': raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw),
      };
    } finally {
      client.close(force: true);
    }
  }

  test('v1 business routes are gone and v2 requires owner plus identity', () async {
    for (final String path in <String>[
      '/chat/list_users',
      '/chat/send_message',
      '/chat/send_attachment',
      '/chat/read_messages',
      '/chat/wait_messages',
      '/chat/ack_messages',
      '/chat/confirm_presentation',
      '/downloads/start',
      '/downloads/get',
      '/operations/get',
      '/events/subscribe',
      '/events/read',
      '/events/wait',
    ]) {
      final Map<String, dynamic> response = await post(path, <String, dynamic>{});
      expect(response['status'], 404, reason: path);
    }

    final Map<String, dynamic> status = await post(
      '/v2/status',
      <String, dynamic>{},
    );
    final Map<String, dynamic> auth =
        (status['body'] as Map<String, dynamic>)['auth']
            as Map<String, dynamic>;
    final Map<String, dynamic> created = await post(
      '/v2/consumers/create',
      <String, dynamic>{'expected_auth': auth, 'session_id': 'dsh-main'},
      owner: _owner,
    );
    expect(created['status'], 200, reason: '${created['body']}');
    final Map<String, dynamic> identity =
        (created['body'] as Map<String, dynamic>)['identity']
            as Map<String, dynamic>;

    // No owner header: the protected route cannot be called anonymously.
    final Map<String, dynamic> anonymous = await post(
      '/v2/chat/list_users',
      <String, dynamic>{'expected_identity': identity},
    );
    expect(anonymous['status'], isNot(200));
    expect(anonymous['status'], isNot(404));

    // Owner but no identity: strict validation rejects before business work.
    final Map<String, dynamic> noIdentity = await post(
      '/v2/chat/list_users',
      <String, dynamic>{},
      owner: _owner,
    );
    expect(noIdentity['status'], 422);

    final Map<String, dynamic> ok = await post(
      '/v2/chat/list_users',
      <String, dynamic>{'expected_identity': identity},
      owner: _owner,
    );
    expect(ok['status'], 200, reason: '${ok['body']}');
  });

  test('stable consumer survives restart and remains the only business path',
      () async {
    final Map<String, dynamic> status = await post(
      '/v2/status',
      <String, dynamic>{},
    );
    final Map<String, dynamic> auth =
        (status['body'] as Map<String, dynamic>)['auth']
            as Map<String, dynamic>;
    final Map<String, dynamic> created = await post(
      '/v2/consumers/create',
      <String, dynamic>{'expected_auth': auth, 'session_id': 'dsh-main'},
      owner: _owner,
    );
    expect(created['status'], 200, reason: '${created['body']}');
    final Map<String, dynamic> identity =
        (created['body'] as Map<String, dynamic>)['identity']
            as Map<String, dynamic>;
    final String consumerId = identity['consumer_id'] as String;

    await server.close();
    await chat.dispose();

    chat = _chat(backend, root, ledgerPath, session);
    final AuthService authService = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: chat.session,
    );
    server = LocalAuthServer(service: authService, chat: chat, port: 0);
    address = await server.start();

    final Map<String, dynamic> reopened = await post(
      '/v2/consumers/get',
      <String, dynamic>{'expected_auth': auth, 'consumer_id': consumerId},
      owner: _owner,
    );
    expect(reopened['status'], 200, reason: '${reopened['body']}');
    final Map<String, dynamic> reopenedIdentity =
        (reopened['body'] as Map<String, dynamic>)['identity']
            as Map<String, dynamic>;
    expect(reopenedIdentity, identity);

    final Map<String, dynamic> ok = await post(
      '/v2/chat/list_users',
      <String, dynamic>{'expected_identity': identity},
      owner: _owner,
    );
    expect(ok['status'], 200, reason: '${ok['body']}');

    final Map<String, dynamic> v1 = await post(
      '/chat/list_users',
      <String, dynamic>{},
    );
    expect(v1['status'], 404);
  });
}

ChatService _chat(
  FakeChatBackend backend,
  Directory root,
  String path,
  AuthSession session,
) {
  return ChatService(
    api: ChatApiClient(baseUri: backend.baseUri),
    session: session,
    ledger: ChatLedger.atPath(path),
    cacheRoot: Directory('${root.path}/cache'),
    webSocketHints: false,
  );
}
