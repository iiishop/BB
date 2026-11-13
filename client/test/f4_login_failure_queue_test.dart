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
      throw const FileSystemException("synthetic failed old replacement");
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

  });

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('failed earlier login cannot erase a later queued successful login', () async {
    gate.armed = true;
    backend.issuedToken = 'token-new';
    final first = post('/auth/login', {
      'account': backend.validAccount, 'password': backend.validPassword,
    });
    await gate.entered.future.timeout(const Duration(seconds: 5));
    backend.issuedToken = 'token-latest';
    final latest = post('/auth/login', {
      'account': backend.validAccount, 'password': backend.validPassword,
    });
    await store.latestQueued.future.timeout(const Duration(seconds: 5));
    expect(session.tokenForRequest, 'token-latest');
    gate.release.complete();
    final oldResponse = await first;
    final response = await latest;
    final cold = await SessionStore.atPath(store.file.path).read();
    // ignore: avoid_print
    print('old login status=${oldResponse["status"]}; latest login status=${response["status"]}; latest memory=${session.tokenForRequest == "token-latest"}; latest cold disk=${cold?.token == "token-latest"}');
    expect(oldResponse['status'], isNot(200));
    expect(response['status'], 200);
    expect(cold?.token, 'token-latest');
    expect(session.tokenForRequest, 'token-latest', reason: 'Failed old persistence must not clear a newer successful login');
    expect(unauthorizedCalls, 0);
  });
}
