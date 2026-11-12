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

/// R1: after a same-owner CAS rebind to a new session, the retained old
/// alias must not be usable through the legacy v1 confirm/ACK routes.
///
/// R2: a new owner must not be able to re-point a legacy session alias at a
/// new consumer and inherit its confirmed receipts, bypassing the ambiguous
/// legacy-migration block.
const String _account = '10000001';
const String _peer = '10000002';
const String _owner = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Map<String, dynamic> _receipt(String session, int position) =>
    <String, dynamic>{
      'receipt_id': '$session-$position',
      'account': _account,
      'consumer_session': session,
      'peer_account': _peer,
      'message_id': 'synthetic-$position',
      'position': position,
      'content_digest': 'synthetic-$position',
      'confirmed': true,
      'attempt_id': null,
    };

Map<String, dynamic> _ambiguousV1Document() => <String, dynamic>{
  'version': 1,
  'accounts': <String, dynamic>{
    _account: <String, dynamic>{
      'server_event_cursor': 0,
      'subscriptions': <String, dynamic>{
        's1': <String, dynamic>{'peer_account': _peer},
        's2': <String, dynamic>{'peer_account': _peer},
      },
      'operations': <String, dynamic>{},
      'downloads': <String, dynamic>{},
      'download_operations': <String, dynamic>{},
      'consumption': <String, int>{_peer: 2},
      'receipts': <String, dynamic>{
        for (final String session in <String>['s1', 's2'])
          for (int position = 1; position <= 2; position++)
            '$session-$position': _receipt(session, position),
      },
      'events': <String, dynamic>{},
      'confirmations': <String, dynamic>{},
      'pending_events': <String, dynamic>{},
    },
  },
};

void main() {
  late Directory root;
  late String path;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-alias-ownership-');
    path = '${root.path}/ledger.json';
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<({ChatService chat, LocalAuthServer server, Uri origin})> start() async {
    final AuthSession session = AuthSession()
      ..establish(
        token: 'synthetic-unused-local-only',
        user: const AuthUser(account: _account, username: 'synthetic'),
      );
    final ChatService chat = ChatService(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: ChatLedger.atPath(path),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
    final LocalAuthServer server = LocalAuthServer(
      service: AuthService(
        api: AuthApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: session,
      ),
      chat: chat,
      port: 0,
    );
    final Uri origin = await server.start();
    return (chat: chat, server: server, origin: origin);
  }

  Future<Map<String, dynamic>> post(
    Uri origin,
    String route,
    Map<String, dynamic> body, {
    String? owner,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(origin.resolve(route));
      request.headers.contentType = ContentType.json;
      if (owner != null) {
        request.headers.set(v2OwnerHeader, owner);
      }
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

  Future<Map<String, dynamic>> auth(Uri origin) async {
    final Map<String, dynamic> response = await post(
      origin,
      '/v2/status',
      <String, dynamic>{},
      owner: _owner,
    );
    return (response['body'] as Map<String, dynamic>)['auth']
        as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> create(
    Uri origin, {
    required String session,
    String owner = _owner,
  }) async {
    return post(
      origin,
      '/v2/consumers/create',
      <String, dynamic>{
        'expected_auth': await auth(origin),
        'session_id': session,
      },
      owner: owner,
    );
  }

  test('v1 old alias cannot confirm or ACK after a CAS rebind', () async {
    final ({ChatService chat, LocalAuthServer server, Uri origin}) running =
        await start();
    final String oldSession = 'old-session';
    final Map<String, dynamic> created = await create(
      running.origin,
      session: oldSession,
    );
    expect(created['status'], 200, reason: '${created['body']}');
    final Map<String, dynamic> oldIdentity =
        (created['body'] as Map<String, dynamic>)['identity']
            as Map<String, dynamic>;
    final String consumerId = oldIdentity['consumer_id'] as String;
    final PresentationReceipt receipt = await running.chat.ledger
        .prepareReceipt(
          account: _account,
          consumerId: consumerId,
          consumerSession: oldSession,
          peerAccount: _peer,
          messageId: 'm1',
          position: 1,
          contentDigest: 'd1',
        );

    final Map<String, dynamic> rebound = await post(
      running.origin,
      '/v2/consumers/bind',
      <String, dynamic>{
        'expected_auth': await auth(running.origin),
        'consumer_id': consumerId,
        'expected_binding_revision': oldIdentity['binding_revision'],
        'session_id': 'new-session',
      },
      owner: _owner,
    );
    expect(rebound['status'], 200, reason: '${rebound['body']}');

    final Map<String, dynamic> confirmed = await post(
      running.origin,
      '/chat/confirm_presentation',
      <String, dynamic>{
        'consumer_session': oldSession,
        'attempt_id': 'attempt-old',
        'request_digest': 'digest-old',
        'receipt_ids': <String>[receipt.receiptId],
      },
    );
    // Keep the complete counterexample in one failure: if the stale confirm
    // is wrongly admitted, capture the ACK it would unlock before asserting.
    Map<String, dynamic> acked = <String, dynamic>{};
    if (confirmed['status'] == 200) {
      acked = await post(
        running.origin,
        '/chat/ack_messages',
        <String, dynamic>{
          'account': _peer,
          'consumer_session': oldSession,
          'through_position': 1,
        },
      );
    }
    expect(
      confirmed['status'],
      409,
      reason:
          'confirm=${confirmed['status']} ack=${acked['status']} body=${confirmed['body']}',
    );
    expect(
      (confirmed['body'] as Map<String, dynamic>)['error']['code'],
      staleBindingCode,
    );
    if (acked.isNotEmpty) {
      expect(acked['status'], 409);
      expect(
        (acked['body'] as Map<String, dynamic>)['error']['code'],
        staleBindingCode,
      );
    }
    expect(
      await running.chat.ledger.consumedThrough(
        _account,
        _peer,
        consumerId: consumerId,
      ),
      0,
    );
    await running.server.close();
    await running.chat.dispose();

    // Cold reopen from the same file: no confirmation may have been committed
    // and the old alias still points at the rebound consumer.
    final ChatLedger cold = ChatLedger.atPath(path);
    final ConsumerBinding? binding = await cold.bindingById(consumerId);
    expect(binding, isNotNull);
    expect(binding!.sessionId, 'new-session');
    expect(binding.aliases, contains(oldSession));
    expect(await cold.consumedThrough(_account, _peer, consumerId: consumerId), 0);
    final Map<String, dynamic> raw =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final Map<String, dynamic> accountState =
        (raw['accounts'] as Map<String, dynamic>)[_account]
            as Map<String, dynamic>;
    final Map<String, dynamic> receipts =
        accountState['receipts'] as Map<String, dynamic>;
    expect(
      (receipts[receipt.receiptId] as Map<String, dynamic>)['confirmed'],
      isFalse,
    );
  });

  test('new owner cannot reuse an ambiguous legacy alias to inherit receipts',
      () async {
    await File(path).writeAsString(jsonEncode(_ambiguousV1Document()), flush: true);
    final ({ChatService chat, LocalAuthServer server, Uri origin}) running =
        await start();
    final Map<String, dynamic> report =
        (await running.chat.ledger.legacyMigrationReport())!;
    expect(report['requires_attention'], isTrue);
    final Map<String, dynamic> entry =
        (report['entries'] as List<dynamic>).single as Map<String, dynamic>;
    expect(entry['outcome'], migrationRequiredCode);
    final String oldConsumer =
        (await running.chat.ledger.consumerIdForSession(_account, 's1'))!;

    // Reusing the ambiguous legacy session for a new consumer must not
    // overwrite the alias or mint a consumer that inherits the v1 receipts.
    final Map<String, dynamic> reused = await create(
      running.origin,
      session: 's1',
      owner: List<String>.filled(43, 'B').join(),
    );
    Map<String, dynamic> reuseAck = <String, dynamic>{};
    if (reused['status'] == 200) {
      final Map<String, dynamic> reusedIdentity =
          (reused['body'] as Map<String, dynamic>)['identity']
              as Map<String, dynamic>;
      reuseAck = await post(
        running.origin,
        '/v2/chat/ack_messages',
        <String, dynamic>{
          'expected_identity': reusedIdentity,
          'account': _peer,
          'through_position': 2,
        },
        owner: List<String>.filled(43, 'B').join(),
      );
    }
    expect(
      reused['status'],
      409,
      reason:
          'create=${reused['status']} ack=${reuseAck['status']} body=${reused['body']}',
    );
    expect(
      (await running.chat.ledger.consumerIdForSession(_account, 's1'))!,
      oldConsumer,
    );

    // A genuinely fresh alias may be created, but the unresolved ambiguity
    // still blocks the new consumer's ACK; no watermark is written.
    final Map<String, dynamic> fresh = await create(
      running.origin,
      session: 'fresh-session',
      owner: List<String>.filled(43, 'C').join(),
    );
    expect(fresh['status'], 200, reason: '${fresh['body']}');
    final Map<String, dynamic> freshIdentity =
        (fresh['body'] as Map<String, dynamic>)['identity']
            as Map<String, dynamic>;
    final String freshConsumer = freshIdentity['consumer_id'] as String;
    final Map<String, dynamic> acked = await post(
      running.origin,
      '/v2/chat/ack_messages',
      <String, dynamic>{
        'expected_identity': freshIdentity,
        'account': _peer,
        'through_position': 2,
      },
      owner: List<String>.filled(43, 'C').join(),
    );
    expect(acked['status'], 409, reason: '${acked['body']}');
    expect(
      (acked['body'] as Map<String, dynamic>)['error']['code'],
      migrationRequiredCode,
    );
    expect(
      await running.chat.ledger.consumedThrough(
        _account,
        _peer,
        consumerId: freshConsumer,
      ),
      0,
    );
    await running.server.close();
    await running.chat.dispose();

    // Two-phase persistence: the ambiguity and zero watermarks survive a
    // cold reopen, and the old alias was never re-pointed.
    final ChatLedger cold = ChatLedger.atPath(path);
    final Map<String, dynamic> coldReport =
        (await cold.legacyMigrationReport())!;
    expect(coldReport['requires_attention'], isTrue);
    expect(
      (await cold.consumerIdForSession(_account, 's1'))!,
      oldConsumer,
    );
    expect(
      await cold.consumedThrough(_account, _peer, consumerId: freshConsumer),
      0,
    );
  });
}
