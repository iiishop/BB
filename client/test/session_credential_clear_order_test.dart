import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

/// The credential file is the only part of "signed in" that another process can
/// observe. The standalone `bb_client_api` test therefore waits for the file to
/// disappear and only then asks the local control API about the session, which
/// means a 401 revocation must already be out of memory when the deletion
/// lands. On CI 2026-11-17 it was not: `Expected: null` at
/// standalone_entry_test.dart:124 while the deletion had provably happened.
///
/// [signOut] keeps two orderings on purpose (see the comment there): a
/// server-side invalidation revokes first, a user-directed sign-out erases
/// first. Both contracts are pinned here so neither can be "simplified" back.
class _PausedAfterDeleteStore extends SessionStore {
  // ignore: use_super_parameters
  _PausedAfterDeleteStore(String path) : super.atPath(path);

  /// Completes once the real deletion has run, before [clear] returns.
  final Completer<void> deleted = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> clear() async {
    await super.clear();
    if (!deleted.isCompleted) {
      deleted.complete();
    }
    await release.future;
  }
}

class _FailingClearStore extends SessionStore {
  // ignore: use_super_parameters
  _FailingClearStore(String path) : super.atPath(path);

  @override
  Future<void> clear() async {
    await super.clear();
    throw const SessionStorageException('synthetic clear failure');
  }
}

void main() {
  late FakeAuthBackend backend;
  late Directory directory;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-clear-order-');
  });

  tearDown(() async {
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  group('a server-side invalidation revokes memory before the file', () {
    late AuthSession session;
    late _PausedAfterDeleteStore store;
    late AuthService auth;
    late LocalAuthServer server;
    late Uri address;

    Future<Map<String, dynamic>> post(
      String path,
      Map<String, dynamic> payload,
    ) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.postUrl(
          address.resolve(path),
        );
        request.headers.contentType = ContentType.json;
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
      session = AuthSession();
      store = _PausedAfterDeleteStore('${directory.path}/session.json');
      auth = AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: session,
        store: store,
      );
      await auth.login(
        account: backend.validAccount,
        password: backend.validPassword,
      );
      server = LocalAuthServer(service: auth, port: 0);
      address = await server.start();
    });

    tearDown(() async {
      if (!store.release.isCompleted) {
        store.release.complete();
      }
      await server.close();
    });

    test(
      'the status probe never reports a session whose credential file is gone',
      () async {
        final Map<String, dynamic> before = await post(
          '/v2/status',
          <String, dynamic>{},
        );
        expect(before['body']['auth'], isNotNull);

        // Exactly what a heartbeat 401 does: revoke this specific token.
        final String token = session.tokenForRequest!;
        final Future<void> revoke = auth.signOut(expectedToken: token);
        await store.deleted.future.timeout(const Duration(seconds: 5));
        expect(store.file.existsSync(), isFalse, reason: 'the deletion really ran');

        final Map<String, dynamic> during = await post(
          '/v2/status',
          <String, dynamic>{},
        );
        store.release.complete();
        await revoke.timeout(const Duration(seconds: 5));

        expect(
          during['body']['auth'],
          isNull,
          reason: '凭据文件已经不在，本地接口就不能再报告已登录',
        );
      },
    );
  });

  group('a user-directed sign-out stays atomic', () {
    late AuthSession session;
    late AuthService auth;

    setUp(() async {
      session = AuthSession();
      auth = AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: session,
        store: _FailingClearStore('${directory.path}/session.json'),
      );
      await auth.login(
        account: backend.validAccount,
        password: backend.validPassword,
      );
    });

    test('a deletion that fails leaves the session usable', () async {
      final String token = session.tokenForRequest!;
      await expectLater(
        auth.signOut(),
        throwsA(
          isA<AuthFailure>().having(
            (AuthFailure failure) => failure.code,
            'code',
            sessionStorageUnavailable.code,
          ),
        ),
      );
      expect(
        session.tokenForRequest,
        token,
        reason: '删不掉凭据文件时不能把用户留在半退出状态',
      );
    });
  });
}
