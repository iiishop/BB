import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// Legacy v1 (account+peer watermark) consumption migration.
const String _account = '10000001';
const String _peer = '10000002';

Map<String, dynamic> _receipt({
  required String consumerSession,
  required int position,
  bool confirmed = true,
}) => <String, dynamic>{
  'receipt_id': 'r-$consumerSession-$position',
  'account': _account,
  'consumer_session': consumerSession,
  'peer_account': _peer,
  'message_id': 'm-$consumerSession-$position',
  'position': position,
  'content_digest': 'digest-$consumerSession-$position',
  'confirmed': confirmed,
  'attempt_id': null,
};

Map<String, dynamic> _v1Document({
  required Map<String, int> consumption,
  required List<Map<String, dynamic>> receipts,
  List<String> sessions = const <String>[],
}) {
  final Set<String> allSessions = <String>{
    ...sessions,
    for (final Map<String, dynamic> receipt in receipts)
      receipt['consumer_session'] as String,
  };
  return <String, dynamic>{
    'version': 1,
    'accounts': <String, dynamic>{
      _account: <String, dynamic>{
        'server_event_cursor': 0,
        'subscriptions': <String, dynamic>{
          for (final String session in allSessions)
            session: <String, dynamic>{'peer_account': _peer},
        },
        'operations': <String, dynamic>{},
        'downloads': <String, dynamic>{},
        'download_operations': <String, dynamic>{},
        'consumption': consumption,
        'receipts': <String, dynamic>{
          for (final Map<String, dynamic> receipt in receipts)
            receipt['receipt_id'] as String: receipt,
        },
        'events': <String, dynamic>{},
        'confirmations': <String, dynamic>{},
        'pending_events': <String, dynamic>{},
      },
    },
  };
}

void main() {
  late Directory root;
  late String path;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-ledger-migration-');
    path = '${root.path}/ledger.json';
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> writeV1(Map<String, dynamic> document) async {
    await File(path).writeAsString(jsonEncode(document), flush: true);
  }

  test('only a provable continuous range is migrated, with a backup', () async {
    final Map<String, dynamic> document = _v1Document(
      consumption: <String, int>{_peer: 2},
      receipts: <Map<String, dynamic>>[
        _receipt(consumerSession: 's1', position: 1),
        _receipt(consumerSession: 's1', position: 2),
      ],
    );
    final String original = jsonEncode(document);
    await writeV1(document);

    final ChatLedger ledger = ChatLedger.atPath(path);
    final Map<String, dynamic>? report = await ledger.legacyMigrationReport();
    expect(report, isNotNull);
    expect(report!['requires_attention'], isFalse);
    final List<dynamic> entries = report['entries'] as List<dynamic>;
    expect(entries, hasLength(1));
    expect(entries.single['outcome'], 'migrated');
    expect(entries.single['legacy_watermark'], 2);

    final String? consumerId = await ledger.consumerIdForSession(
      _account,
      's1',
    );
    expect(consumerId, isNotNull);
    expect(
      await ledger.consumedThrough(_account, _peer, consumerId: consumerId!),
      2,
    );
    // No other consumer inherits the migrated watermark.
    expect(
      await ledger.consumedThrough(
        _account,
        _peer,
        consumerId: 'c-unrelated',
      ),
      0,
    );

    final File backup = File('$path.v1-backup');
    expect(await backup.exists(), isTrue);
    expect(await backup.readAsString(), original);

    final Map<String, dynamic> reloaded =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(reloaded['version'], 2);
    expect(
      (reloaded['consumers'] as Map<String, dynamic>).containsKey(consumerId),
      isTrue,
    );
    final Map<String, dynamic> account =
        (reloaded['accounts'] as Map<String, dynamic>)[_account]
            as Map<String, dynamic>;
    expect(account['legacy_consumption'], <String, dynamic>{_peer: 2});
    expect(account['consumption_by_consumer'], isNotNull);
  });

  test('an incomplete legacy range is preserved and needs migration', () async {
    await writeV1(
      _v1Document(
        consumption: <String, int>{_peer: 2},
        receipts: <Map<String, dynamic>>[
          _receipt(consumerSession: 's1', position: 1),
        ],
      ),
    );
    final ChatLedger ledger = ChatLedger.atPath(path);
    final Map<String, dynamic> report = (await ledger.legacyMigrationReport())!;
    expect(report['requires_attention'], isTrue);
    final Map<String, dynamic> entry =
        (report['entries'] as List<dynamic>).single as Map<String, dynamic>;
    expect(entry['outcome'], migrationRequiredCode);
    expect(entry['reason'], 'no_consumer_has_continuous_receipts');

    final String consumerId = (await ledger.consumerIdForSession(
      _account,
      's1',
    ))!;
    expect(
      await ledger.consumedThrough(_account, _peer, consumerId: consumerId),
      0,
      reason: 'the unprovable legacy watermark is never copied',
    );
  });

  test('two qualifying consumers make the legacy watermark ambiguous', () async {
    await writeV1(
      _v1Document(
        consumption: <String, int>{_peer: 2},
        receipts: <Map<String, dynamic>>[
          _receipt(consumerSession: 's1', position: 1),
          _receipt(consumerSession: 's1', position: 2),
          _receipt(consumerSession: 's2', position: 1),
          _receipt(consumerSession: 's2', position: 2),
        ],
      ),
    );
    final ChatLedger ledger = ChatLedger.atPath(path);
    final Map<String, dynamic> report = (await ledger.legacyMigrationReport())!;
    final Map<String, dynamic> entry =
        (report['entries'] as List<dynamic>).single as Map<String, dynamic>;
    expect(entry['outcome'], migrationRequiredCode);
    expect(entry['reason'], 'ambiguous_consumers');
    for (final String session in <String>['s1', 's2']) {
      final String consumerId = (await ledger.consumerIdForSession(
        _account,
        session,
      ))!;
      expect(
        await ledger.consumedThrough(_account, _peer, consumerId: consumerId),
        0,
      );
    }
  });

  test('re-running the migration is an idempotent no-op', () async {
    await writeV1(
      _v1Document(
        consumption: <String, int>{_peer: 2},
        receipts: <Map<String, dynamic>>[
          _receipt(consumerSession: 's1', position: 1),
          _receipt(consumerSession: 's1', position: 2),
        ],
      ),
    );
    final ChatLedger first = ChatLedger.atPath(path);
    final Map<String, dynamic> report =
        (await first.legacyMigrationReport())!;
    final String consumerId = (await first.consumerIdForSession(
      _account,
      's1',
    ))!;
    final int migrated = await first.consumedThrough(
      _account,
      _peer,
      consumerId: consumerId,
    );
    final String v2AfterFirst = await File(path).readAsString();
    final String backupAfterFirst = await File('$path.v1-backup').readAsString();

    // A second open (process restart) must not re-run or reorder anything.
    final ChatLedger second = ChatLedger.atPath(path);
    final Map<String, dynamic> again = (await second.legacyMigrationReport())!;
    expect(again['migrated_at'], report['migrated_at']);
    expect(again['entries'], report['entries']);
    expect(
      await second.consumedThrough(_account, _peer, consumerId: consumerId),
      migrated,
    );
    expect(await File(path).readAsString(), v2AfterFirst);
    expect(await File('$path.v1-backup').readAsString(), backupAfterFirst);

    // A later v2 write keeps the document v2 and the migration facts intact.
    await second.saveOperation(
      _account,
      const ChatOperationRecord(
        operationId: 'op-after-migration',
        kind: 'message',
        targetAccount: _peer,
        state: 'prepared',
        sourceDigest: 'digest',
        parts: <Map<String, dynamic>>[],
      ),
    );
    final Map<String, dynamic> doc =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(doc['version'], 2);
    expect(doc['legacy_migration'], isNotNull);
  });

  test('a legacy watermark cannot bypass the ACK gap check', () async {
    await writeV1(
      _v1Document(
        consumption: <String, int>{_peer: 2},
        receipts: <Map<String, dynamic>>[
          _receipt(consumerSession: 's1', position: 1),
        ],
      ),
    );
    final ChatLedger ledger = ChatLedger.atPath(path);
    final AuthSession session = AuthSession()
      ..establish(
        token: 'token',
        user: const AuthUser(account: _account, username: 'alice'),
      );
    final ChatService service = ChatService(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: ledger,
      cacheRoot: Directory.systemTemp,
      webSocketHints: false,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.ackMessages(
        peerAccount: _peer,
        consumerSession: 's1',
        throughPosition: 2,
      ),
      throwsA(
        isA<AuthFailure>()
            .having((AuthFailure f) => f.status, 'status', 409)
            .having(
              (AuthFailure f) => f.code,
              'code',
              migrationRequiredCode,
            ),
      ),
    );
    final String consumerId = (await ledger.consumerIdForSession(
      _account,
      's1',
    ))!;
    expect(
      await ledger.consumedThrough(_account, _peer, consumerId: consumerId),
      0,
    );
  });
}
