import 'dart:convert';
import 'dart:io';

import 'package:bb_client/services/session_store.dart' as store_lib;

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late store_lib.SessionStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bb-session-test-');
    store = store_lib.SessionStore.atPath(
      '${directory.path}/nested/session.json',
    );
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('writes, reads and clears a session', () async {
    const store_lib.PersistedSession session = store_lib.PersistedSession(
      account: '40218765',
      username: 'muse',
      token: 'token-abc',
    );

    expect(await store.read(), isNull);
    await store.write(session);

    final store_lib.PersistedSession? restored = await store.read();
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
        const store_lib.PersistedSession(
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

  test('a failed replacement keeps the previous credential', () async {
    await store.write(
      const store_lib.PersistedSession(
        account: '40218765',
        username: 'muse',
        token: 'old-token',
      ),
    );

    final store_lib.SessionStore failing = store_lib.SessionStore.atPath(
      store.file.path,
      replace: (File temporary, File target) async {
        throw FileSystemException('injected replace failure', temporary.path);
      },
    );

    await expectLater(
      failing.write(
        const store_lib.PersistedSession(
          account: '51284370',
          username: 'muse2',
          token: 'new-token',
        ),
      ),
      throwsA(isA<store_lib.SessionStorageException>()),
    );

    final store_lib.PersistedSession? kept = await store.read();
    expect(kept?.account, '40218765', reason: 'old credential preserved');
    expect(kept?.token, 'old-token');
    final List<String> leftovers = await directory
        .list(recursive: true)
        .where((FileSystemEntity entity) => entity.path.endsWith('.tmp'))
        .map((FileSystemEntity entity) => entity.path)
        .toList();
    expect(leftovers, isEmpty, reason: 'temporary file cleaned up');
    expect(await File('${store.file.path}.bak').exists(), isFalse);
  });

  test('concurrent writes never corrupt the stored credential', () async {
    final store_lib.PersistedSession first = store_lib.PersistedSession(
      account: '40218765',
      username: 'muse',
      token: 'token-one-${'a' * 32}',
    );
    final store_lib.PersistedSession second = store_lib.PersistedSession(
      account: '51284370',
      username: 'muse2',
      token: 'token-two-${'b' * 32}',
    );

    await Future.wait(<Future<void>>[store.write(first), store.write(second)]);

    final store_lib.PersistedSession? stored = await store.read();
    expect(stored, isNotNull);
    expect(
      <String>{stored!.token},
      anyOf(equals(<String>{first.token}), equals(<String>{second.token})),
      reason: 'one complete record wins, never a mix',
    );
    final List<String> leftovers = await directory
        .list(recursive: true)
        .where((FileSystemEntity entity) => entity.path.endsWith('.tmp'))
        .map((FileSystemEntity entity) => entity.path)
        .toList();
    expect(leftovers, isEmpty);
  });

  test('clear reports a delete failure instead of pretending', () async {
    await store.write(
      const store_lib.PersistedSession(
        account: '40218765',
        username: 'muse',
        token: 'token',
      ),
    );

    if (Platform.isWindows) {
      return;
    }
    final String parent = store.file.parent.path;
    await Process.run('chmod', <String>['500', parent]);
    addTearDown(() => Process.run('chmod', <String>['700', parent]));

    await expectLater(
      store.clear(),
      throwsA(isA<store_lib.SessionStorageException>()),
    );
    expect(
      await store.read(),
      isNotNull,
      reason: 'the credential is still there, so logout must not claim success',
    );
  });

  test('rewriting replaces the previous credential', () async {
    await store.write(
      const store_lib.PersistedSession(
        account: '40218765',
        username: 'muse',
        token: 'old',
      ),
    );
    await store.write(
      const store_lib.PersistedSession(
        account: '51284370',
        username: 'muse2',
        token: 'new',
      ),
    );

    final store_lib.PersistedSession? restored = await store.read();
    expect(restored?.account, '51284370');
    expect(restored?.token, 'new');
    expect(await File('${store.file.path}.tmp').exists(), isFalse);
  });
}
