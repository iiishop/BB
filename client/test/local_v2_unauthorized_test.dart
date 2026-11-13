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
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

class _RejectingApi extends ChatApiClient {
  _RejectingApi() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<UserPage> listUsers({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    if (entered != null) {
      entered!.complete();
      await release!.future;
    }
    throw unauthenticated;
  }
}

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late AuthSession session;
  late AuthService auth;
  late _RejectingApi api;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late String owner;
  late Map<String, dynamic> identity;
  late int unauthorizedCalls;

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> payload, {
    String? ownerKey,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(address.resolve(path));
      request.headers.contentType = ContentType.json;
      if (ownerKey != null) request.headers.set(v2OwnerHeader, ownerKey);
      request.write(jsonEncode(payload));
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

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-v2-401-');
    session = AuthSession();
    auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
      store: SessionStore.atPath('${directory.path}/session.json'),
    );
    await auth.login(
      account: backend.validAccount,
      password: backend.validPassword,
    );
    api = _RejectingApi();
    chat = ChatService(
      api: api,
      session: session,
      ledger: ChatLedger.atPath('${directory.path}/ledger.json'),
      cacheRoot: Directory('${directory.path}/cache'),
      webSocketHints: false,
    );
    owner = List<String>.filled(43, 'A').join();
    unauthorizedCalls = 0;
    server = LocalAuthServer(
      service: auth,
      chat: chat,
      port: 0,
      onUnauthorized: (String token) async {
        unauthorizedCalls++;
        if (session.tokenForRequest == token) {
          await auth.signOut();
        }
      },
    );
    address = await server.start();
    final Map<String, dynamic> status = await post(
      '/v2/status',
      <String, dynamic>{},
    );
    final Map<String, dynamic> created = await post(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': status['body']['auth'],
        'session_id': 'session',
      },
      ownerKey: owner,
    );
    identity = created['body']['identity'] as Map<String, dynamic>;
  });

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Map<String, dynamic> expected() =>
      <String, dynamic>{'expected_identity': identity};

  test('a genuine current-credential 401 runs the invalidation callback',
      () async {
    final Map<String, dynamic> response = await post(
      '/v2/chat/list_users',
      expected(),
      ownerKey: owner,
    );
    expect(response['status'], 401, reason: '${response['body']}');
    expect(unauthorizedCalls, 1);
    expect(session.hasToken, isFalse);
    final Map<String, dynamic> status = await post(
      '/v2/status',
      <String, dynamic>{},
    );
    expect(status['body']['auth'], isNull);
  });

  test('an old 401 cannot clear a concurrently established new login',
      () async {
    api.entered = Completer<void>();
    api.release = Completer<void>();
    final Future<Map<String, dynamic>> oldRequest = post(
      '/v2/chat/list_users',
      expected(),
      ownerKey: owner,
    );
    await api.entered!.future;

    backend.issuedToken = 'token-new';
    final Map<String, dynamic> login = await post(
      '/auth/login',
      <String, dynamic>{
        'account': backend.validAccount,
        'password': backend.validPassword,
      },
    );
    expect(login['status'], 200, reason: '${login['body']}');
    expect(session.tokenForRequest, 'token-new');

    api.release!.complete();
    final Map<String, dynamic> old = await oldRequest;
    expect(old['status'], anyOf(401, 409), reason: '${old['body']}');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(unauthorizedCalls, 0);
    expect(session.tokenForRequest, 'token-new');
    expect(session.hasToken, isTrue);
  });
}
