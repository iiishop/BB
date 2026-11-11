import 'dart:convert';
import 'dart:io';

import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late SessionStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bb-session-test-');
    store = SessionStore.atPath('${directory.path}/nested/session.json');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('writes, reads and clears a session', () async {
    const PersistedSession session = PersistedSession(
      account: '40218765',
      username: 'muse',
      token: 'token-abc',
    );

    expect(await store.read(), isNull);
    await store.write(session);

    final PersistedSession? restored = await store.read();
    expect(restored?.account, '40218765');
    expect(restored?.username, 'muse');
    expect(restored?.token, 'token-abc');

    await store.clear();
    expect(await store.read(), isNull);
    expect(await store.file.exists(), isFalse);
  });

  test(
    'stores no password and restricts the file to the current user',
    () async {
      await store.write(
        const PersistedSession(
          account: '40218765',
          username: 'muse',
          token: 'token-abc',
        ),
      );

      final String raw = await store.file.readAsString();
      final Map<String, dynamic> decoded =
          jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded.keys.toSet(), <String>{'account', 'username', 'token'});
      expect(raw.contains('password'), isFalse);

      if (!Platform.isWindows) {
        final FileStat stat = await store.file.stat();
        expect(
          stat.mode & 0x1FF,
          0x180,
          reason: 'session file must be 0600 (owner read/write only)',
        );
        final FileStat dirStat = await store.file.parent.stat();
        expect(dirStat.mode & 0x1FF, 0x1C0, reason: 'parent directory 0700');
      }
    },
  );

  test('a corrupt file is ignored and removed', () async {
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('{not json');

    expect(await store.read(), isNull);
    expect(await store.file.exists(), isFalse);
  });

  test('an incomplete record is treated as absent', () async {
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString(
      jsonEncode(<String, String>{'account': '40218765'}),
    );

    expect(await store.read(), isNull);
    expect(await store.file.exists(), isFalse);
  });

  test('rewriting replaces the previous credential', () async {
    await store.write(
      const PersistedSession(
        account: '40218765',
        username: 'muse',
        token: 'old',
      ),
    );
    await store.write(
      const PersistedSession(
        account: '51284370',
        username: 'muse2',
        token: 'new',
      ),
    );

    final PersistedSession? restored = await store.read();
    expect(restored?.account, '51284370');
    expect(restored?.token, 'new');
    expect(await File('${store.file.path}.tmp').exists(), isFalse);
  });
}
