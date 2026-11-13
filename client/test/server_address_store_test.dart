import 'dart:io';

import 'package:bb_client/config/client_config.dart';
import 'package:bb_client/services/server_address_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeServerAddress', () {
    test('a bare hostname becomes HTTPS', () {
      expect(
        normalizeServerAddress('bb.iiishop.top').toString(),
        'https://bb.iiishop.top',
      );
      expect(
        normalizeServerAddress('  bb.iiishop.top  ').toString(),
        'https://bb.iiishop.top',
      );
    });

    test('a LAN address stays on HTTP so a self-hosted server is reachable', () {
      expect(
        normalizeServerAddress('192.168.0.104:18980').toString(),
        'http://192.168.0.104:18980',
      );
      expect(
        normalizeServerAddress('127.0.0.1:8000').toString(),
        'http://127.0.0.1:8000',
      );
      expect(
        normalizeServerAddress('10.0.0.5').toString(),
        'http://10.0.0.5',
      );
      expect(
        normalizeServerAddress('localhost:3080').toString(),
        'http://localhost:3080',
      );
    });

    test('an explicit scheme always wins', () {
      expect(
        normalizeServerAddress('http://bb.example.com').toString(),
        'http://bb.example.com',
      );
      expect(
        normalizeServerAddress('https://192.168.0.104:18980').toString(),
        'https://192.168.0.104:18980',
      );
    });

    test('a path or trailing slash is preserved as typed', () {
      expect(
        normalizeServerAddress('https://bb.example.com/').toString(),
        'https://bb.example.com/',
      );
    });

    test('empty and non-URL input is rejected', () {
      expect(() => normalizeServerAddress(''), throwsArgumentError);
      expect(() => normalizeServerAddress('   '), throwsArgumentError);
      expect(() => normalizeServerAddress('ftp://bb.example.com'), throwsArgumentError);
    });
  });

  group('compiledServerAddress', () {
    test('is null when the build passed no BB_API_BASE_URL', () {
      // `flutter test` never defines it, so an installed build falls through to
      // the setup screen instead of silently using 127.0.0.1.
      expect(compiledServerAddress(), isNull);
    });
  });

  group('ServerAddressStore', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bb-server-address');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('round-trips the address and creates missing directories', () async {
      final File file = File('${root.path}/nested/server.json');
      final ServerAddressStore store = ServerAddressStore(file);

      expect(await store.read(), isNull);
      await store.write(Uri.parse('https://bb.iiishop.top'));
      expect(await file.exists(), isTrue);
      expect((await store.read()).toString(), 'https://bb.iiishop.top');
    });

    test('a corrupt file reads as not configured instead of failing startup', () async {
      final File file = File('${root.path}/server.json');
      await file.writeAsString('{"server_url": ');
      final ServerAddressStore store = ServerAddressStore(file);

      expect(await store.read(), isNull);
    });

    test('a file with the wrong shape or value reads as null', () async {
      final File wrongShape = File('${root.path}/a.json');
      await wrongShape.writeAsString('["https://bb.iiishop.top"]');
      expect(await ServerAddressStore(wrongShape).read(), isNull);

      final File emptyValue = File('${root.path}/b.json');
      await emptyValue.writeAsString('{"server_url": ""}');
      expect(await ServerAddressStore(emptyValue).read(), isNull);

      final File unsupported = File('${root.path}/c.json');
      await unsupported.writeAsString('{"server_url": "ftp://bb.example.com"}');
      expect(await ServerAddressStore(unsupported).read(), isNull);
    });
  });
}
