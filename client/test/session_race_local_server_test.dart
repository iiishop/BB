import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

/// QA-465-02 follow-up: a delayed upstream 401 from the *old* session must not
/// clear a session that was logged in meanwhile through the local API.
class _DelayedProfileApi extends ProfileApiClient {
  _DelayedProfileApi(Uri base) : super(baseUri: base);

  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<Profile> fetchProfile({
    required String token,
    required String account,
  }) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    throw unauthenticated;
  }
}

void main() {
  test(
    'delayed old-session Profile 401 keeps the newly logged-in session',
    () async {
      final FakeAuthBackend backend = await FakeAuthBackend.start();
      backend.issuedToken = 'old-token';
      final Directory directory = await Directory.systemTemp.createTemp(
        'bb-local-race-',
      );
      final SessionStore store = SessionStore.atPath(
        '${directory.path}/session.json',
      );
      final AuthSession session = AuthSession();
      final AuthService auth = AuthService(
        api: AuthApiClient(baseUri: backend.baseUri),
        session: session,
        store: store,
      );
      await auth.login(
        account: backend.validAccount,
        password: backend.validPassword,
      );
      expect(session.tokenForRequest, 'old-token');

      final _DelayedProfileApi delayed = _DelayedProfileApi(backend.baseUri);
      final ProfileService profile = ProfileService(
        api: delayed,
        auth: auth,
        cache: AvatarCache(),
      );
      final ChatService chat = ChatService(
        api: ChatApiClient(baseUri: backend.baseUri),
        session: session,
        ledger: ChatLedger.atPath('${directory.path}/ledger.json'),
        cacheRoot: Directory('${directory.path}/cache'),
        webSocketHints: false,
      );
      int unauthorizedCalls = 0;
      final LocalAuthServer server = LocalAuthServer(
        service: auth,
        profile: profile,
        chat: chat,
        port: 0,
        onUnauthorized: () async {
          unauthorizedCalls += 1;
          await auth.signOut();
        },
      );
      final Uri address = await server.start();
      try {
        final String owner = List<String>.filled(43, 'A').join();
        final _Response status = await _post(
          address.resolve('/v2/status'),
          <String, dynamic>{},
        );
        final Map<String, dynamic> expectedAuth =
            status.body['auth'] as Map<String, dynamic>;
        final _Response created = await _post(
          address.resolve('/v2/consumers/create'),
          <String, dynamic>{
            'expected_auth': expectedAuth,
            'session_id': 'race-session',
          },
          owner: owner,
        );
        final Map<String, dynamic> identity =
            created.body['identity'] as Map<String, dynamic>;
        final Future<_Response> oldRequest = _post(
          address.resolve('/v2/profile/view_nickname'),
          <String, dynamic>{'expected_identity': identity},
          owner: owner,
        );
        await delayed.started.future.timeout(const Duration(seconds: 5));

        // A second login replaces the token while the old request is in flight.
        backend.issuedToken = 'new-token';
        final _Response login = await _post(
          address.resolve('/auth/login'),
          <String, dynamic>{
            'account': backend.validAccount,
            'password': backend.validPassword,
          },
        );
        expect(login.status, 200);
        expect(session.tokenForRequest, 'new-token');
        expect((await store.read())?.token, 'new-token');

        delayed.release.complete();
        final _Response oldResponse = await oldRequest.timeout(
          const Duration(seconds: 5),
        );
        // The old request is classified as a stale identity of the captured
        // session; it never becomes a success in the new session context.
        expect(oldResponse.status, 409);
        expect(
          (oldResponse.body['error'] as Map<String, dynamic>)['code'],
          staleIdentityCode,
        );
        // Let a (buggy) async unauthorized callback run if it was scheduled.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(unauthorizedCalls, 0);
        expect(
          [session.tokenForRequest, (await store.read())?.token],
          <String?>['new-token', 'new-token'],
          reason: 'old request must not revoke the new memory or disk session',
        );
      } finally {
        await server.close();
        await chat.dispose();
        await backend.close();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}

class _Response {
  const _Response(this.status, this.body, this.raw);

  final int status;
  final Map<String, dynamic> body;
  final String raw;
}

Future<_Response> _post(
  Uri uri,
  Map<String, dynamic> payload, {
  String? owner,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    if (owner != null) request.headers.set(v2OwnerHeader, owner);
    final List<int> bytes = utf8.encode(jsonEncode(payload));
    request.contentLength = bytes.length;
    request.add(bytes);
    final HttpClientResponse response = await request.close();
    final String raw = await utf8.decoder.bind(response).join();
    return _Response(
      response.statusCode,
      jsonDecode(raw) as Map<String, dynamic>,
      raw,
    );
  } finally {
    client.close(force: true);
  }
}
