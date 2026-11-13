// Synthetic legacy disk records, actual BB migration and actual v1 HTTP ACK.
// No backend double: these local-only calls do not contact a business server.
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/local_auth_server.dart';

const account = '10000001', peer = '10000002';
Map<String, dynamic> document(String mode) {
  final receipts = <String, dynamic>{};
  final sessions = mode == 'ambiguous' ? ['s1', 's2'] : ['s1'];
  for (final session in sessions) {
    for (
      int position = 1;
      position <= (mode == 'incomplete' ? 1 : 2);
      position++
    ) {
      final id = '$session-$position';
      receipts[id] = {
        'receipt_id': id,
        'account': account,
        'consumer_session': session,
        'peer_account': peer,
        'message_id': 'synthetic-$position',
        'position': position,
        'content_digest': 'synthetic-$position',
        'confirmed': true,
        'attempt_id': null,
      };
    }
  }
  return {
    'version': 1,
    'accounts': {
      account: {
        'server_event_cursor': 0,
        'subscriptions': {
          for (final s in sessions) s: {'peer_account': peer},
        },
        'operations': <String, dynamic>{},
        'downloads': <String, dynamic>{},
        'download_operations': <String, dynamic>{},
        'consumption': {peer: 2},
        'receipts': receipts,
        'events': <String, dynamic>{},
        'confirmations': <String, dynamic>{},
        'pending_events': <String, dynamic>{},
      },
    },
  };
}

Future<void> main(List<String> args) async {
  final root = Directory(args[0]), phase = args[1];
  await root.create(recursive: true);
  final results = <Map<String, dynamic>>[];
  for (final mode in [
    'complete',
    'incomplete',
    'ambiguous',
    'backup-blocked',
  ]) {
    final file = File('${root.path}/$mode.json');
    final original = jsonEncode(document(mode));
    if (phase == 'prepare') await file.writeAsString(original, flush: true);
    if (mode == 'backup-blocked' && phase == 'prepare') {
      final obstacle = Directory('${file.path}.v1-backup');
      await obstacle.create();
      bool failed = false;
      try {
        await ChatLedger.atPath(file.path).legacyMigrationReport();
      } on FileSystemException {
        failed = true;
      }
      final unchanged = await file.readAsString() == original;
      await obstacle.rename('${file.path}.blocked-fixture');
      results.add({
        'name': 'migration-backup-failure',
        'passed': failed && unchanged,
        'write_failed': failed,
        'original_unchanged': unchanged,
      });
      continue;
    }
    final before = await file.readAsString();
    final wasV2 = (jsonDecode(before) as Map<String, dynamic>)['version'] == 2;
    final ledger = ChatLedger.atPath(file.path);
    final report = (await ledger.legacyMigrationReport())!;
    final id = (await ledger.consumerIdForSession(account, 's1'))!;
    final initial = await ledger.consumedThrough(account, peer, consumerId: id);
    final expected = mode == 'complete' || mode == 'backup-blocked' ? 2 : 0;
    final coldNoRewrite = !wasV2 || await file.readAsString() == before;
    final backupSame =
        await File('${file.path}.v1-backup').readAsString() == original;
    final session = AuthSession()
      ..establish(
        token: 'synthetic-unused-local-only',
        user: const AuthUser(account: account, username: 'Synthetic'),
      );
    final unused = Uri.parse('http://127.0.0.1:1');
    final chat = ChatService(
      api: ChatApiClient(baseUri: unused),
      session: session,
      ledger: ledger,
      cacheRoot: Directory('${root.path}/cache-$mode'),
      webSocketHints: false,
    );
    final server = LocalAuthServer(
      service: AuthService(
        api: AuthApiClient(baseUri: unused),
        session: session,
      ),
      chat: chat,
      port: 0,
    );
    final origin = await server.start();
    final http = HttpClient();
    int status;
    String? code;
    try {
      final request = await http.postUrl(origin.resolve('/chat/ack_messages'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'account': peer,
          'consumer_session': 's1',
          'through_position': 2,
        }),
      );
      final response = await request.close();
      status = response.statusCode;
      final body = jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>;
      code = (body['error'] as Map<String, dynamic>?)?['code'] as String?;
    } finally {
      http.close(force: true);
      await server.close();
      await chat.dispose();
    }
    final after = await ledger.consumedThrough(account, peer, consumerId: id);
    // On cold reopen, the synthetic auth generation also changes. Identity
    // fencing correctly takes precedence over diagnosing legacy evidence.
    final unprovenBlocked =
        expected == 2 ||
        (status == 409 &&
            (code == 'migration_required' ||
                (phase == 'recover' &&
                    (code == 'stale_identity' || code == 'stale_binding'))) &&
            after == 0);
    results.add({
      'name': 'migration-$mode-$phase',
      'passed':
          initial == expected &&
          after == expected &&
          coldNoRewrite &&
          backupSame &&
          unprovenBlocked,
      'migration_attention': report['requires_attention'],
      'initial_watermark': initial,
      'legacy_ack_status': status,
      'legacy_ack_code': code,
      'after_watermark': after,
      'cold_no_rewrite': coldNoRewrite,
      'original_backup_equal': backupSame,
    });
  }
  stdout.writeln(jsonEncode(results));
  exitCode = results.every((result) => result['passed'] == true) ? 0 : 1;
}
