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

  @override
  Future<UserPage> listUsers({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async => throw unauthenticated;
}

class _ReplaceGate {
  bool armed = false;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  Future<void> call(File temporary, File target) async {
    if (armed) {
      armed = false;
      entered.complete();
      await release.future;
    }
    await SessionStore.replaceFile(temporary, target);
  }
}

class _GatedStore extends SessionStore {
  // ignore: use_super_parameters
  _GatedStore(String path, this.gate) : super.atPath(path, replace: gate.call);

  final _ReplaceGate gate;
  final Completer<void> latestQueued = Completer<void>();
  @override
  Future<void> write(PersistedSession value) async {
    final pending = super.write(value);
    if (value.token == 'token-latest' && !latestQueued.isCompleted) {
      latestQueued.complete();
    }
    await pending;
  }
  final Completer<void> clearEntered = Completer<void>();
  final Completer<void> clearRelease = Completer<void>();

  @override
  Future<void> clear() async {
    await super.clear(); // Real deletion under the serialized commit lock.
    if (!clearEntered.isCompleted) {
      clearEntered.complete();
      await clearRelease.future;
    }
  }
}

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late AuthSession session;
  late _GatedStore store;
  late _ReplaceGate gate;
  late AuthService auth;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late String owner;
  late Map<String, dynamic> identity;
  late int unauthorizedCalls;
  late Future<Map<String, dynamic>> cleanup;

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
    directory = await Directory.systemTemp.createTemp('bb-f4-replace-');
    session = AuthSession();
    gate = _ReplaceGate();
    store = _GatedStore('${directory.path}/session.json', gate);
    auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
      store: store,
    );
    await auth.login(
      account: backend.validAccount,
      password: backend.validPassword,
    );
    chat = ChatService(
      api: _RejectingApi(),
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

  Future<void> reachPausedRepair() async {
    final oldRequest = post('/v2/chat/list_users', expected(), ownerKey: owner);
    cleanup = oldRequest;
    await store.clearEntered.future;
    backend.issuedToken = 'token-new';
    final login = await post('/auth/login', <String, dynamic>{
      'account': backend.validAccount,
      'password': backend.validPassword,
    });
    expect(login['status'], 200);
    expect(session.tokenForRequest, 'token-new');
    gate.armed = true;
    store.clearRelease.complete();
    await gate.entered.future.timeout(const Duration(seconds: 5));
    addTearDown(() async {
      if (!gate.release.isCompleted) gate.release.complete();
      await oldRequest;
    });
  }

  test('queued old clear cannot invalidate a later queued successful login', () async {
    await reachPausedRepair();
    // Both operations queue behind the same paused real replacement.
    final logout = auth.signOut();
    backend.issuedToken = 'token-latest';
    final latest = post('/auth/login', {
      'account': backend.validAccount,
      'password': backend.validPassword,
    });
    await store.latestQueued.future.timeout(const Duration(seconds: 5));
    expect(session.tokenForRequest, 'token-latest');
    gate.release.complete();
    await logout.timeout(const Duration(seconds: 5));
    final response = await latest.timeout(const Duration(seconds: 5));
    final oldResponse = await cleanup.timeout(const Duration(seconds: 5));
    final cold = await SessionStore.atPath(store.file.path).read();
    // ignore: avoid_print
    print('login status=${response['status']}; old request=${oldResponse['status']}; '
        'latest memory=${session.tokenForRequest == 'token-latest'}; '
        'latest cold disk=${cold?.token == 'token-latest'}; credential absent=${cold == null}');
    expect(response['status'], 200);
    expect(unauthorizedCalls, 1);
    expect(session.tokenForRequest, 'token-latest');
    expect(cold?.token, 'token-latest',
        reason: 'A successful later login must survive earlier queued logout on disk');
  });
}
