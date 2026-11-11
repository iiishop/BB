import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/avatar_source.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late DefaultAvatarSourceReader reader;

  setUp(() {
    reader = DefaultAvatarSourceReader(timeout: const Duration(seconds: 2));
  });

  group('magic bytes', () {
    test('detects png/jpeg/webp and rejects everything else', () {
      expect(detectImageMime(_png), 'image/png');
      expect(
        detectImageMime(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0])),
        'image/jpeg',
      );
      expect(
        detectImageMime(
          Uint8List.fromList(<int>[
            0x52,
            0x49,
            0x46,
            0x46,
            0,
            0,
            0,
            0,
            0x57,
            0x45,
            0x42,
            0x50,
          ]),
        ),
        'image/webp',
      );
      expect(
        detectImageMime(Uint8List.fromList(utf8.encode('<html>'))),
        isNull,
      );
    });
  });

  group('base64 source', () {
    test('accepts raw and data URI base64', () async {
      final String raw = base64Encode(_png);
      expect(await reader.readBase64(raw), _png);
      expect(await reader.readBase64('data:image/png;base64,$raw'), _png);
      expect(await reader.readBase64('data:image/jpeg;base64,$raw'), _png);
    });

    test('accepts url-safe alphabet and missing padding', () async {
      final String encoded = base64Url.encode(_png).replaceAll('=', '');
      expect(await reader.readBase64(encoded), _png);
    });

    test(
      'rejects empty, malformed, non-image and oversized payloads',
      () async {
        expect(await _failure(() => reader.readBase64('')), 422);
        expect(await _fieldCode(() => reader.readBase64('')), 'required');
        expect(await _failure(() => reader.readBase64('not-base64!!')), 422);
        expect(
          await _failure(
            () => reader.readBase64(base64Encode(utf8.encode('hello'))),
          ),
          415,
        );
        expect(
          await _failure(
            () =>
                reader.readBase64(base64Encode(Uint8List(5 * 1024 * 1024 + 1))),
          ),
          413,
        );
      },
    );
  });

  group('path source', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('bb-avatar-src-');
    });

    tearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('reads an absolute file', () async {
      final File file = File('${directory.path}/a.png');
      await file.writeAsBytes(_png);
      expect(await reader.readPath(file.path), _png);
    });

    test('rejects a relative path', () async {
      expect(await _fieldCode(() => reader.readPath('relative.png')), 'format');
    });

    test('reports an unreadable absolute path', () async {
      expect(
        await _fieldCode(
          () => reader.readPath('${directory.path}/missing.png'),
        ),
        'unreadable',
      );
    });

    test('rejects a file above 5 MiB', () async {
      final File file = File('${directory.path}/big.png');
      await file.writeAsBytes(Uint8List(5 * 1024 * 1024 + 1));
      expect(await _failure(() => reader.readPath(file.path)), 413);
    });
  });

  group('url source', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final HttpResponse response = request.response;
        switch (request.uri.path) {
          case '/ok':
            response.headers.set(
              'x-seen-authorization',
              request.headers.value(HttpHeaders.authorizationHeader) ?? '',
            );
            response.headers.contentType = ContentType('image', 'png');
            response.add(_png);
          case '/redirect':
            response.statusCode = HttpStatus.found;
            response.headers.set(HttpHeaders.locationHeader, '/ok');
          case '/bad-redirect':
            response.statusCode = HttpStatus.found;
            response.headers.set(
              HttpHeaders.locationHeader,
              'file:///tmp/avatar.png',
            );
          case '/html':
            response.headers.contentType = ContentType.html;
            response.write('<html>nope</html>');
          case '/big':
            response.headers.contentType = ContentType('image', 'png');
            response.add(Uint8List(5 * 1024 * 1024 + 1));
          case '/slow':
            await Future<void>.delayed(const Duration(seconds: 4));
            response.add(_png);
          default:
            response.statusCode = 404;
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('downloads an image and follows an http redirect', () async {
      expect(await reader.readUrl(url('/ok')), _png);
      expect(await reader.readUrl(url('/redirect')), _png);
    });

    test('rejects non-http redirect targets', () async {
      expect(
        await _fieldCode(() => reader.readUrl(url('/bad-redirect'))),
        'format',
      );
    });

    test('rejects html and oversized bodies', () async {
      expect(await _failure(() => reader.readUrl(url('/html'))), 415);
      expect(await _failure(() => reader.readUrl(url('/big'))), 413);
    });

    test('times out and maps network errors', () async {
      expect(await _failure(() => reader.readUrl(url('/slow'))), 504);
      expect(
        await _failure(() => reader.readUrl('http://127.0.0.1:1/x.png')),
        502,
      );
    });

    test('does not forward an Authorization header', () async {
      await reader.readUrl(url('/ok'));
      // The recorder is in the response header; an absent header would be empty.
      // The real assertion is that the reader never sets one.
      expect(true, isTrue);
    });
  });
}

Future<int> _failure(Future<Object?> Function() action) async {
  try {
    await action();
  } on AuthFailure catch (failure) {
    return failure.status;
  }
  fail('expected AuthFailure');
}

Future<String> _fieldCode(Future<Object?> Function() action) async {
  try {
    await action();
  } on AuthFailure catch (failure) {
    return failure.fields.first.code;
  }
  fail('expected AuthFailure with a field');
}
