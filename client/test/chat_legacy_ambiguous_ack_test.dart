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

/// `migration-ambiguous`: two legacy sessions both have continuous confirmed
/// receipts, so the old account+peer watermark is ambiguous. Any ACK from an
/// affected consumer must be 409 `migration_required` (never 200/2), even when
/// receipts happen to be continuous or the ACK would hit the idempotent
/// branch. Unrelated verified consumers and already-migrated scopes stay
/// usable; the backup and preserved evidence are never rewritten.
const String _account = '10000001';
const String _peer = '10000002';

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

Map<String, dynamic> _v1Document(List<String> sessions) => <String, dynamic>{
  'version': 1,
  'accounts': <String, dynamic>{
    _account: <String, dynamic>{
      'server_event_cursor': 0,
      'subscriptions': <String, dynamic>{
        for (final String session in sessions)
          session: <String, dynamic>{'peer_account': _peer},
      },
      'operations': <String, dynamic>{},
      'downloads': <String, dynamic>{},
      'download_operations': <String, dynamic>{},
      'consumption': <String, int>{_peer: 2},
      'receipts': <String, dynamic>{
        for (final String session in sessions)
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
    root = await Directory.systemTemp.createTemp('bb-ambiguous-ack-');
    path = '${root.path}/ledger.json';
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<({ChatService chat, LocalAuthServer server, Uri origin})> start({
    required String token,
  }) async {
    final AuthSession session = AuthSession()
      ..establish(
        token: token,
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

  Future<Map<String, dynamic>> ack(
    Uri origin,
    String session,
    int through,
  ) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(
        origin.resolve('/chat/ack_messages'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, dynamic>{
          'account': _peer,
          'consumer_session': session,
          'through_position': through,
        }),
      );
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

  test('ambiguous legacy migration blocks every affected old ACK', () async {
    final String original = jsonEncode(_v1Document(<String>['s1', 's2']));
    await File(path).writeAsString(original, flush: true);

    final ChatLedger ledger = ChatLedger.atPath(path);
    final Map<String, dynamic> report =
        (await ledger.legacyMigrationReport())!;
    expect(report['requires_attention'], isTrue);
    final Map<String, dynamic> entry =
        (report['entries'] as List<dynamic>).single as Map<String, dynamic>;
    expect(entry['outcome'], migrationRequiredCode);
    expect(entry['reason'], 'ambiguous_consumers');
    final List<String> affected = (entry['consumer_ids'] as List<dynamic>)
        .cast<String>();
    expect(affected, hasLength(2));
    final String s1 = (await ledger.consumerIdForSession(_account, 's1'))!;
    final String s2 = (await ledger.consumerIdForSession(_account, 's2'))!;
    expect(affected.toSet(), <String>{s1, s2});

    final ({ChatService chat, LocalAuthServer server, Uri origin}) first =
        await start(token: 'synthetic-unused-local-only');
    try {
      for (final String session in <String>['s1', 's2']) {
        for (final int through in <int>[2, 1]) {
          final Map<String, dynamic> response = await ack(
            first.origin,
            session,
            through,
          );
          expect(response['status'], 409, reason: '$session/$through');
          expect(
            (response['body'] as Map<String, dynamic>)['error']['code'],
            migrationRequiredCode,
          );
          final String consumer = session == 's1' ? s1 : s2;
          expect(
            await first.chat.ledger.consumedThrough(
              _account,
              _peer,
              consumerId: consumer,
            ),
            0,
          );
        }
      }
      // The "idempotent" branch (through == consumed == 0) is blocked too.
      final Map<String, dynamic> zero = await ack(first.origin, 's1', 0);
      expect(zero['status'], 409);
      expect(
        (zero['body'] as Map<String, dynamic>)['error']['code'],
        migrationRequiredCode,
      );
    } finally {
      await first.server.close();
      await first.chat.dispose();
    }

    // Cold reopen: the premature advance must not exist, and the preserved
    // evidence/backup are byte-identical.
    final ({ChatService chat, LocalAuthServer server, Uri origin}) cold =
        await start(token: 'synthetic-unused-cold-process');
    try {
      final Map<String, dynamic> response = await ack(cold.origin, 's1', 2);
      expect(response['status'], 409);
      // A cold process has a new synthetic auth generation; identity fencing
      // may answer before migration diagnosis. Either way the legacy ACK is
      // rejected and nothing advances (the frozen probe accepts both).
      expect(
        (response['body'] as Map<String, dynamic>)['error']['code'],
        isIn(<String>[migrationRequiredCode, staleIdentityCode]),
      );
      expect(
        await cold.chat.ledger.consumedThrough(
          _account,
          _peer,
          consumerId: s1,
        ),
        0,
      );
      final Map<String, dynamic> reloaded =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      final Map<String, dynamic> accountState =
          (reloaded['accounts'] as Map<String, dynamic>)[_account]
              as Map<String, dynamic>;
      expect(accountState['legacy_consumption'], <String, dynamic>{_peer: 2});
      expect(
        (accountState['consumption_by_consumer'] as Map<String, dynamic>),
        isEmpty,
      );
      expect(await File('$path.v1-backup').readAsString(), original);
    } finally {
      await cold.server.close();
      await cold.chat.dispose();
    }
  });

  test('scope-limited: an unrelated verified consumer still ACKs', () async {
    await File(
      path,
    ).writeAsString(jsonEncode(_v1Document(<String>['s1', 's2'])), flush: true);
    final ({ChatService chat, LocalAuthServer server, Uri origin}) running =
        await start(token: 'synthetic-unused-local-only');
    try {
      final ExpectedIdentity fresh = await running.chat.identityFor('fresh');
      final PresentationReceipt receipt = await running.chat.ledger
          .prepareReceipt(
            account: _account,
            consumerId: fresh.consumerId,
            consumerSession: 'fresh',
            peerAccount: _peer,
            messageId: 'fresh-1',
            position: 1,
            contentDigest: 'fresh-1',
          );
      await running.chat.ledger.confirmPresentationAttempt(
        account: _account,
        consumerId: fresh.consumerId,
        consumerSession: 'fresh',
        attemptId: 'fresh-attempt',
        requestDigest: 'fresh-digest',
        receiptIds: <String>[receipt.receiptId],
        expectedIdentity: fresh,
      );
      final Map<String, dynamic> response = await ack(
        running.origin,
        'fresh',
        1,
      );
      expect(response['status'], 200, reason: '${response['body']}');
      expect(
        (response['body'] as Map<String, dynamic>)['consumed_through'],
        1,
      );
    } finally {
      await running.server.close();
      await running.chat.dispose();
    }
  });

  test('a non-ambiguous migrated scope keeps its idempotent ACK', () async {
    await File(
      path,
    ).writeAsString(jsonEncode(_v1Document(<String>['s1'])), flush: true);
    final ({ChatService chat, LocalAuthServer server, Uri origin}) running =
        await start(token: 'synthetic-unused-local-only');
    try {
      final String s1 = (await running.chat.ledger.consumerIdForSession(
        _account,
        's1',
      ))!;
      expect(
        await running.chat.ledger.consumedThrough(
          _account,
          _peer,
          consumerId: s1,
        ),
        2,
      );
      final Map<String, dynamic> first = await ack(running.origin, 's1', 2);
      expect(first['status'], 200);
      expect(
        (first['body'] as Map<String, dynamic>)['consumed_through'],
        2,
      );
      final Map<String, dynamic> repeat = await ack(running.origin, 's1', 2);
      expect(repeat['status'], 200);
      expect(
        (repeat['body'] as Map<String, dynamic>)['consumed_through'],
        2,
      );
    } finally {
      await running.server.close();
      await running.chat.dispose();
    }
  });
}
