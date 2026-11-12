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

/// Optional `cover` per the shared schema (`cover: Source | None = None`):
/// omission and explicit null are valid, a present cover is strictly validated,
/// and v1 keeps its existing compatibility.
const String _account = '10000001';
const String _peer = '10000002';

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService chat;
  late LocalAuthServer server;
  late Uri address;
  late Map<String, dynamic> identity;

  final String owner = List<String>.filled(43, 'A').join();

  AuthUser user(String account) => AuthUser(
    account: account,
    username: 'user-$account',
  );

  Map<String, dynamic> source() => <String, dynamic>{
    'base64': 'c3ludGhldGlj',
    'path': null,
    'url': null,
    'mime_type': 'text/plain',
    'filename': 'probe.txt',
  };

  Map<String, dynamic> body(String operationId) => <String, dynamic>{
    'expected_identity': identity,
    'target_account': _peer,
    'operation_id': operationId,
    'source': source(),
  };

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_account: 'alice', _peer: 'bob'},
    );
    root = await Directory.systemTemp.createTemp('bb-cover-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_account), user: user(_account));
    chat = ChatService(
      api: ChatApiClient(baseUri: backend.baseUri),
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
    final _Response status = await _post(
      address,
      '/v2/status',
      <String, dynamic>{},
      owner: owner,
    );
    final Map<String, dynamic> auth =
        (status.body['auth'] as Map<String, dynamic>);
    final _Response binding = await _post(
      address,
      '/v2/consumers/create',
      <String, dynamic>{'expected_auth': auth, 'session_id': 'cover'},
      owner: owner,
    );
    expect(binding.status, 200);
    identity = (binding.body['identity'] as Map<String, dynamic>);
  });

  tearDown(() async {
    await server.close();
    await chat.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('v2 omitted and explicit-null cover are both accepted', () async {
    final _Response omitted = await _post(
      address,
      '/v2/chat/send_attachment',
      body('cover-omitted'),
      owner: owner,
    );
    expect(omitted.status, 200, reason: '${omitted.body}');
    final _Response explicit = await _post(
      address,
      '/v2/chat/send_attachment',
      <String, dynamic>{...body('cover-null'), 'cover': null},
      owner: owner,
    );
    expect(explicit.status, 200, reason: '${explicit.body}');
  });

  test('v2 valid cover is accepted and invalid cover is rejected', () async {
    final _Response valid = await _post(
      address,
      '/v2/chat/send_attachment',
      <String, dynamic>{...body('cover-valid'), 'cover': source()},
      owner: owner,
    );
    expect(valid.status, 200, reason: '${valid.body}');

    final _Response wrongType = await _post(
      address,
      '/v2/chat/send_attachment',
      <String, dynamic>{...body('cover-string'), 'cover': 'not-a-source'},
      owner: owner,
    );
    expect(wrongType.status, 422, reason: '${wrongType.body}');

    final _Response badSource = await _post(
      address,
      '/v2/chat/send_attachment',
      <String, dynamic>{
        ...body('cover-bad-source'),
        'cover': <String, dynamic>{
          'base64': 'eA',
          'path': null,
          'url': null,
          'mime_type': '',
          'filename': 'x',
        },
      },
      owner: owner,
    );
    expect(badSource.status, 422, reason: '${badSource.body}');
  });

  test('v1 attachment keeps omitted/null/legacy behavior', () async {
    final Map<String, dynamic> v1Body = <String, dynamic>{
      'target_account': _peer,
      'operation_id': 'v1-cover-omitted',
      'source': source(),
    };
    final _Response omitted = await _post(
      address,
      '/chat/send_attachment',
      v1Body,
    );
    expect(omitted.status, 200, reason: '${omitted.body}');
    final _Response explicit = await _post(
      address,
      '/chat/send_attachment',
      <String, dynamic>{...v1Body, 'operation_id': 'v1-cover-null', 'cover': null},
    );
    expect(explicit.status, 200, reason: '${explicit.body}');
    final _Response invalid = await _post(
      address,
      '/chat/send_attachment',
      <String, dynamic>{
        ...v1Body,
        'operation_id': 'v1-cover-invalid',
        'cover': 'not-a-source',
      },
    );
    expect(invalid.status, 500);
  });
}

class _Response {
  const _Response(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;
}

Future<_Response> _post(
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
    return _Response(
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  } finally {
    client.close(force: true);
  }
}
