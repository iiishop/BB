import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/updates/release_client.dart';
import 'package:bb_client/updates/release_update_controller.dart';
import 'package:bb_client/updates/update_contract.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/release_test_support.dart';

const _size = 6 * 1024 * 1024 + 29;
const _etag = '"version-1"';
const _cdn = 'https://release-assets.githubusercontent.com/fixture';
final _bytes = _fixtureBytes();

Uint8List _fixtureBytes() {
  final bytes = Uint8List(_size);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = (index ^ (index >> 4) ^ (index >> 19)) & 255;
  }
  return bytes;
}

final _asset = UpdateAsset(
  id: 7,
  name: 'bb-1.10.0-windows-x64.zip',
  url: Uri.parse(
    'https://github.com/iiishop/BB/releases/download/v1.10.0/bb.zip',
  ),
  size: _size,
);

Future<void> _partial(
  HttpRequest request,
  int start,
  int end, {
  String etag = _etag,
  String? contentRange,
  int? shortLength,
}) async {
  final response = request.response;
  response.statusCode = 206;
  response.headers.set(HttpHeaders.etagHeader, etag);
  response.headers.set(
    HttpHeaders.contentRangeHeader,
    contentRange ?? 'bytes $start-$end/$_size',
  );
  final length = shortLength ?? end - start + 1;
  if (shortLength == null) response.contentLength = length;
  response.add(Uint8List.sublistView(_bytes, start, start + length));
  await response.close();
}

Future<void> _full(HttpRequest request) async {
  // Deliberately omit Content-Length to exercise counted single-stream writes.
  request.response.add(_bytes);
  await request.response.close();
}

typedef _RangeHandler = Future<void> Function(HttpRequest, int, int);

void main() {
  late HttpServer server;
  late ReleaseClient client;
  late Directory temp;
  late File file;
  late _RangeHandler onProbe;
  late _RangeHandler onRange;
  late List<int> progress;
  late List<({String? range, String? ifRange})> cdnRequests;
  late int apiDownloads;
  late int active;
  late int peak;
  late bool badChecksum;

  setUp(() async {
    onProbe = _partial;
    onRange = _partial;
    progress = [];
    cdnRequests = [];
    apiDownloads = 0;
    active = 0;
    peak = 0;
    badChecksum = false;
    temp = await Directory.systemTemp.createTemp('bb-ranges-test-');
    file = File('${temp.path}/asset.zip');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        switch (request.uri.path) {
          case '/repos/iiishop/BB/releases':
            request.response.write(jsonEncode([release(size: _size)]));
          case '/repos/iiishop/BB/releases/assets/8':
            request.response.write(sums(wrong: badChecksum, bytes: _bytes));
          case '/repos/iiishop/BB/releases/assets/7':
            apiDownloads++;
            final response = request.response;
            response.statusCode = 302;
            response.headers.set(HttpHeaders.locationHeader, _cdn);
          case '/fixture':
            final range = request.headers.value(HttpHeaders.rangeHeader);
            final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
            cdnRequests.add((range: range, ifRange: ifRange));
            if (range == null) {
              await _full(request);
            } else if (range == 'bytes=0-0') {
              await onProbe(request, 0, 0);
            } else {
              final [start, end] = range
                  .substring(6)
                  .split('-')
                  .map(int.parse)
                  .toList();
              active++;
              if (active > peak) peak = active;
              try {
                await onRange(request, start, end);
              } finally {
                active--;
              }
            }
            return;
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      } on SocketException {
        // Terminated requests are expected in cancellation and fallback tests.
      } on HttpException {
        // The server may surface a force-closed response as an HTTP error.
      }
    });
    client = ReleaseClient(
      downloadConcurrency: 3,
      httpFactory: () => LoopbackClient(server.port),
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  Future<void> expectExactDownload() async {
    expect(listEquals(await file.readAsBytes(), _bytes), isTrue);
    expect(progress.last, _size);
  }

  test(
    'real requests overlap up to the configured cap and finish out of order',
    () async {
      final allInFlight = Completer<void>();
      final nonzeroFinished = Completer<void>();
      final completionOrder = <int>[];
      onRange = (request, start, end) async {
        if (active == 3 && !allInFlight.isCompleted) allInFlight.complete();
        await allInFlight.future;
        if (start == 0) await nonzeroFinished.future;
        await _partial(request, start, end);
        completionOrder.add(start);
        if (start != 0 && !nonzeroFinished.isCompleted) {
          nonzeroFinished.complete();
        }
      };
      final report = await client.download(_asset, file, progress.add);
      expect(peak, 3);
      expect(report.peakRequests, 3);
      expect(report.fellBack, isFalse);
      expect(completionOrder.first, isNot(0));
      expect(apiDownloads, 1);
      expect(cdnRequests.length, 4);
      expect(cdnRequests.skip(1).map((r) => r.ifRange), everyElement(_etag));
      await expectExactDownload();
    },
  );

  test(
    'retries a transient HTTP failure and resumes a short segment once',
    () async {
      const shortLength = 777;
      final failedStart = _size ~/ 3;
      var fail = true;
      onRange = (request, start, end) async {
        if (start == 0) {
          await _partial(request, start, end, shortLength: shortLength);
        } else if (start == failedStart && fail) {
          fail = false;
          request.response.statusCode = 502;
          await request.response.close();
        } else {
          await _partial(request, start, end);
        }
      };
      final report = await client.download(_asset, file, progress.add);
      final ranges = cdnRequests.map((r) => r.range);
      expect(ranges, contains('bytes=$shortLength-${failedStart - 1}'));
      expect(
        ranges
            .where((range) => range!.startsWith('bytes=$failedStart-'))
            .length,
        2,
      );
      expect(cdnRequests.length, 6);
      expect(report.fellBack, isFalse);
      expect(progress, orderedEquals([...progress]..sort()));
      await expectExactDownload();
    },
  );

  test('reuses an ignored Range response as one full stream', () async {
    onProbe = (request, _, _) => _full(request);
    final report = await client.download(_asset, file, progress.add);
    expect(report.fellBack, isTrue);
    expect(report.peakRequests, 1);
    expect(cdnRequests.map((r) => r.range), ['bytes=0-0']);
    await expectExactDownload();
  });

  test('unknown total and weak validators both select a full stream', () async {
    final probes = <_RangeHandler>[
      (request, start, end) =>
          _partial(request, start, end, contentRange: 'bytes 0-0/*'),
      (request, start, end) => _partial(request, start, end, etag: 'W/$_etag'),
    ];
    for (final probe in probes) {
      onProbe = probe;
      cdnRequests.clear();
      final report = await client.download(_asset, file, progress.add);
      expect(report.fellBack, isTrue);
      expect(report.peakRequests, 1);
      expect(cdnRequests.map((r) => r.range), ['bytes=0-0', null]);
      await expectExactDownload();
    }
  });

  test(
    'wrong Content-Range falls back without treating it as file data',
    () async {
      onRange = (request, start, end) => _partial(
        request,
        start,
        end,
        contentRange: 'bytes $start-$end/${_size + 1}',
      );
      final report = await client.download(_asset, file, progress.add);
      expect(report.fellBack, isTrue);
      expect(cdnRequests.where((r) => r.range == null).length, 1);
      await expectExactDownload();
    },
  );

  test('an If-Range response of 200 restarts from byte zero', () async {
    onRange = (request, start, end) async {
      if (start == 0) return _full(request);
      return _partial(request, start, end);
    };
    final report = await client.download(_asset, file, progress.add);
    expect(report.fellBack, isTrue);
    expect(cdnRequests.where((r) => r.range == null).length, 1);
    expect(progress.every((received) => received <= _size), isTrue);
    await expectExactDownload();
  });

  test(
    'changed version discards committed partial bytes before full fallback',
    () async {
      final wroteFirst = Completer<void>();
      onRange = (request, start, end) async {
        if (start == 0) return _partial(request, start, end);
        await wroteFirst.future;
        // Retaining 206 with a changed validator is also rejected.
        await _partial(request, start, end, etag: '"version-2"');
      };
      final report = await client.download(_asset, file, (received) {
        progress.add(received);
        if (received > 0 && !wroteFirst.isCompleted) wroteFirst.complete();
      });
      expect(report.fellBack, isTrue);
      final reset = progress.indexOf(0);
      expect(reset, greaterThan(0));
      expect(
        progress.skip(reset),
        orderedEquals(progress.skip(reset).toList()..sort()),
      );
      await expectExactDownload();
    },
  );

  test(
    'a rate-limited range stops the whole batch without a full retry',
    () async {
      final allInFlight = Completer<void>();
      final sent = Completer<void>();
      onRange = (request, start, end) async {
        if (active == 3 && !allInFlight.isCompleted) allInFlight.complete();
        await allInFlight.future;
        if (start == 0) {
          request.response.statusCode = 429;
          request.response.headers.set(HttpHeaders.retryAfterHeader, '120');
          await request.response.close();
          sent.complete();
        } else {
          await sent.future;
          await _partial(request, start, end);
        }
      };
      final now = DateTime.now();
      await expectLater(
        client.download(_asset, file, progress.add),
        throwsA(
          isA<ReleaseRateLimit>().having(
            (error) => error.retryAt!.difference(now).inSeconds,
            'retry delay in seconds',
            greaterThanOrEqualTo(120),
          ),
        ),
      );
      expect(cdnRequests.length, 4);
      expect(cdnRequests.any((r) => r.range == null), isFalse);
    },
  );

  test(
    'cancellation closes all live range sockets before completing',
    () async {
      final sockets = <Socket>[];
      final allStarted = Completer<void>();
      final allClosed = Completer<void>();
      var disconnected = 0;
      onRange = (request, start, end) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        void closed() {
          disconnected++;
          socket.destroy();
          if (disconnected == 3) allClosed.complete();
        }

        socket.listen(
          (_) {},
          onDone: closed,
          onError: (_) => closed(),
          cancelOnError: true,
        );
        socket.write(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Range: bytes $start-$end/$_size\r\n'
          'Content-Length: ${end - start + 1}\r\n'
          'ETag: $_etag\r\n\r\n',
        );
        socket.add([_bytes[start]]);
        await socket.flush();
        if (sockets.length == 3 && !allStarted.isCompleted) {
          allStarted.complete();
        }
      };
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final downloading = expectLater(
        client.download(_asset, file, progress.add),
        throwsException,
      );
      await allStarted.future.timeout(const Duration(seconds: 5));
      client.close();
      await downloading.timeout(const Duration(seconds: 5));
      await allClosed.future.timeout(const Duration(seconds: 5));
      expect(cdnRequests.length, 4);
    },
  );

  test(
    'a segmented package must pass the manifest before native handoff',
    () async {
      final installer = Installer();
      final controller = ReleaseUpdateController(
        installer: installer,
        cacheDirectory: temp,
        safetyGate: InstallSafetyGate(),
        clientFactory: () => ReleaseClient(
          downloadConcurrency: 3,
          httpFactory: () => LoopbackClient(server.port),
        ),
      );
      addTearDown(controller.dispose);
      await controller.checkOnce();
      expect(controller.snapshot.phase, UpdatePhase.available);
      expect(cdnRequests, isEmpty);
      badChecksum = true;
      await controller.download();
      expect(cdnRequests.length, 4);
      expect(controller.snapshot.phase, UpdatePhase.failed);
      expect(controller.snapshot.message, contains('SHA-256'));
      expect(await temp.list().isEmpty, isTrue);
      await controller.install();
      expect(installer.installs, 0);

      badChecksum = false;
      await controller.download();
      expect(controller.snapshot.phase, UpdatePhase.ready);
      expect(installer.installs, 0);
      await controller.install();
      expect(installer.installs, 1);
    },
  );
}
