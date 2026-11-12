// Actual migration; debugger observes/stops the OS rename, never edits Dart code.
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/services/chat_ledger.dart';

import 'migration_probe.dart' as fixture;

Future<void> main(List<String> args) async {
  final f = File(args[0]);
  if (args[1] == 'seed') {
    await f.writeAsString(
      jsonEncode(fixture.document('complete')),
      flush: true,
    );
    return;
  }
  final ledger = ChatLedger.atPath(f.path);
  await ledger.legacyMigrationReport();
  final id = (await ledger.consumerIdForSession(fixture.account, 's1'))!;
  stdout.writeln(
    jsonEncode({
      'version': (jsonDecode(await f.readAsString()) as Map)['version'],
      'watermark': await ledger.consumedThrough(
        fixture.account,
        fixture.peer,
        consumerId: id,
      ),
    }),
  );
}
