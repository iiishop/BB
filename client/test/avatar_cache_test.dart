import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/services/avatar_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int seed) => Uint8List.fromList(<int>[seed, seed, seed]);

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bb-avatar-cache-');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('memory cache returns the stored bytes and version', () async {
    final AvatarCache cache = AvatarCache();
    await cache.write('12345678', _bytes(1), 'v1');
    final CachedAvatar? cached = await cache.read('12345678');
    expect(cached?.version, 'v1');
    expect(cached?.bytes, _bytes(1));
  });

  test('invalidate removes both memory and disk entries', () async {
    final AvatarCache cache = AvatarCache(directory: directory);
    await cache.write('12345678', _bytes(1), 'v1');
    await cache.invalidate('12345678');
    expect(await cache.read('12345678'), isNull);
    expect(
      File('${directory.path}${Platform.pathSeparator}12345678.png')
          .existsSync(),
      isFalse,
    );
  });

  test('disk cache survives a new cache instance', () async {
    final AvatarCache first = AvatarCache(directory: directory);
    await first.write('12345678', _bytes(7), 'v7');
    final AvatarCache second = AvatarCache(directory: directory);
    final CachedAvatar? cached = await second.read('12345678');
    expect(cached?.bytes, _bytes(7));
    expect(cached?.version, 'v7');
  });

  test('missing or empty version disk files are ignored', () async {
    final AvatarCache cache = AvatarCache(directory: directory);
    await directory.create(recursive: true);
    await File('${directory.path}${Platform.pathSeparator}12345678.png')
        .writeAsBytes(_bytes(3));
    expect(await cache.read('12345678'), isNull);
  });

  test('memory cache is bounded (LRU)', () async {
    final AvatarCache cache = AvatarCache(maxEntries: 2);
    await cache.write('11111111', _bytes(1), 'v1');
    await cache.write('22222222', _bytes(2), 'v2');
    // Touch the first entry so the second becomes the eviction candidate.
    expect(await cache.read('11111111'), isNotNull);
    await cache.write('33333333', _bytes(3), 'v3');
    expect(await cache.read('22222222'), isNull);
    expect(await cache.read('11111111'), isNotNull);
    expect(await cache.read('33333333'), isNotNull);
  });
}
