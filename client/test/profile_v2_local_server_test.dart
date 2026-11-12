import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late AuthSession session;
  late AuthService auth;
  late ProfileService profile;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late Map<String, dynamic> identity;

  final String owner = List<String>.filled(43, 'A').join();

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> payload, {
    String? owner,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(address.resolve(path));
      request.headers.contentType = ContentType.json;
      if (owner != null) request.headers.set(v2OwnerHeader, owner);
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
    directory = await Directory.systemTemp.createTemp('bb-v2-profile-');
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
    profile = ProfileService(
      api: ProfileApiClient(baseUri: backend.baseUri),
      auth: auth,
      cache: AvatarCache(),
    );
    chat = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
      session: session,
      ledger: ChatLedger.atPath('${directory.path}/ledger.json'),
      cacheRoot: Directory('${directory.path}/cache'),
      webSocketHints: false,
    );
    server = LocalAuthServer(
      service: auth,
      profile: profile,
      chat: chat,
      port: 0,
    );
    address = await server.start();
    final Map<String, dynamic> status = await post('/v2/status', <String, dynamic>{});
    final Map<String, dynamic> expectedAuth =
        (status['body'] as Map<String, dynamic>)['auth']
            as Map<String, dynamic>;
    final Map<String, dynamic> created = await post(
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': expectedAuth,
        'session_id': 'dsh-profile',
      },
      owner: owner,
    );
    expect(created['status'], 200, reason: '${created['body']}');
    identity = (created['body'] as Map<String, dynamic>)['identity']
        as Map<String, dynamic>;
  });

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Map<String, dynamic> withIdentity(Map<String, dynamic> body) =>
      <String, dynamic>{'expected_identity': identity, ...body};

  Future<Map<String, dynamic>> call(
    String path,
    Map<String, dynamic> body,
  ) async {
    final Map<String, dynamic> response = await post(
      path,
      withIdentity(body),
      owner: owner,
    );
    expect(response['status'], 200, reason: '$path -> ${response['body']}');
    final Map<String, dynamic> envelope =
        response['body'] as Map<String, dynamic>;
    expect(envelope['identity'], identity);
    return envelope['result'] as Map<String, dynamic>;
  }

  test('six guarded profile routes preserve params, media and product rules',
      () async {
    final Map<String, dynamic> viewedNickname =
        await call('/v2/profile/view_nickname', <String, dynamic>{
          'account': null,
        });
    expect(viewedNickname['account'], identity['account']);
    expect(viewedNickname['username'], isA<String>());

    final Map<String, dynamic> updatedNickname =
        await call('/v2/profile/update_nickname', <String, dynamic>{
          'value': 'Guarded Alice',
        });
    expect(updatedNickname['account'], identity['account']);
    expect(updatedNickname['username'], 'Guarded Alice');

    final Map<String, dynamic> viewedSignature =
        await call('/v2/profile/view_signature', <String, dynamic>{
          'account': null,
        });
    expect(viewedSignature['account'], identity['account']);
    expect(viewedSignature.containsKey('signature'), isTrue);

    final Map<String, dynamic> updatedSignature =
        await call('/v2/profile/update_signature', <String, dynamic>{
          'value': 'guarded signature',
        });
    expect(updatedSignature['signature'], 'guarded signature');

    final Map<String, dynamic> updatedAvatar =
        await call('/v2/profile/update_avatar', <String, dynamic>{
          'base64': base64Encode(_png),
        });
    expect(updatedAvatar['avatar_url'], isA<String>());
    expect(updatedAvatar['avatar_version'], isA<String>());

    final Map<String, dynamic> viewedAvatar =
        await call('/v2/profile/view_avatar', <String, dynamic>{
          'account': null,
        });
    expect(viewedAvatar['account'], identity['account']);
    expect(viewedAvatar['mime_type'], 'image/png');
    expect(base64Decode(viewedAvatar['data'] as String), _png);
    expect(viewedAvatar['avatar_version'], updatedAvatar['avatar_version']);
  });

  test('owner and identity are required; retired profile routes are 404',
      () async {
    final Map<String, dynamic> noOwner = await post(
      '/v2/profile/view_nickname',
      withIdentity(<String, dynamic>{}),
    );
    expect(noOwner['status'], 409);
    expect(
      (noOwner['body'] as Map<String, dynamic>)['error']['code'],
      staleBindingCode,
    );

    final Map<String, dynamic> noIdentity = await post(
      '/v2/profile/view_nickname',
      <String, dynamic>{},
      owner: owner,
    );
    expect(noIdentity['status'], 422);

    final Map<String, dynamic> extra = await post(
      '/v2/profile/view_nickname',
      withIdentity(<String, dynamic>{'extra': true}),
      owner: owner,
    );
    expect(extra['status'], 422);

    for (final String path in <String>[
      '/profile/view_avatar',
      '/profile/update_avatar',
      '/profile/view_nickname',
      '/profile/update_nickname',
      '/profile/view_signature',
      '/profile/update_signature',
    ]) {
      final Map<String, dynamic> retired = await post(path, <String, dynamic>{});
      expect(retired['status'], 404, reason: path);
    }
  });
}
