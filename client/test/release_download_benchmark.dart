// Manual network benchmark. Run explicitly with `flutter test --no-pub
// --reporter expanded test/release_download_benchmark.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/updates/release_client.dart';
import 'package:bb_client/updates/release_policy.dart';
import 'package:bb_client/updates/update_contract.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _apiPath = '/repos/iiishop/BB/releases/assets/';
const _releasePath = '/iiishop/BB/releases/download/v0.2.3/';
const _packageName = 'bb-0.2.3-windows-x64.zip';
final _package = UpdateAsset(
  id: 778241747,
  name: _packageName,
  url: Uri.https('github.com', '$_releasePath$_packageName'),
  size: 32222014,
);
final _manifest = UpdateAsset(
  id: 778241758,
  name: 'SHA256SUMS',
  url: Uri.https('github.com', '${_releasePath}SHA256SUMS'),
  size: 941,
);

// Measure the public Release/CDN data path if the shared IP's anonymous REST
// quota is exhausted. Only the two frozen API URLs are mapped. The production
// client still follows and validates the actual HTTPS CDN redirects and bodies.
class _PublicReleaseTransport implements HttpClient {
  final _http = HttpClient();

  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    if (uri.host == 'api.github.com') {
      uri = switch (uri.path) {
        '${_apiPath}778241747' => _package.url,
        '${_apiPath}778241758' => _manifest.url,
        _ => throw StateError('Unexpected API path in the benchmark.'),
      };
    }
    return _http.getUrl(uri);
  }

  @override
  set autoUncompress(bool value) => _http.autoUncompress = value;

  @override
  set connectionTimeout(Duration? value) => _http.connectionTimeout = value;

  @override
  void close({bool force = false}) => _http.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'alternating single and eight lanes on the same public v0.2.3 asset',
    () async {
      final usePublicRoute =
          Platform.environment['BB_BENCH_PUBLIC_RELEASE'] == '1';
      final HttpClient Function()? transport = usePublicRoute
          ? _PublicReleaseTransport.new
          : null;
      final metadata = ReleaseClient(httpFactory: transport);
      late final String expected;
      try {
        expected = checksumFor(
          await metadata.checksums(_manifest),
          _package.name,
        );
      } finally {
        metadata.close();
      }
      final staging = await Directory.systemTemp.createTemp(
        'bb-download-bench-',
      );
      addTearDown(() => staging.delete(recursive: true));
      final failures = <String>[];
      // Balance which configuration goes first within each pair.
      const lanes = [1, 8, 8, 1, 1, 8, 8, 1];
      for (final (index, concurrency) in lanes.indexed) {
        final client = ReleaseClient(
          httpFactory: transport,
          downloadConcurrency: concurrency,
        );
        final file = File('${staging.path}/benchmark-$index.zip');
        final watch = Stopwatch()..start();
        DownloadReport? report;
        String? failure;
        try {
          report = await client.download(_package, file, (_) {});
          final actual = (await sha256.bind(file.openRead()).first).toString();
          expect(actual, expected);
        } catch (error) {
          failure = error.runtimeType.toString();
          failures.add('run ${index + 1}: $failure');
        } finally {
          watch.stop();
          client.close();
          // ignore: avoid_print
          print(
            jsonEncode({
              'run': index + 1,
              'route': usePublicRoute ? 'public' : 'api',
              'assetBytes': _package.size,
              'configured': concurrency,
              'peak': report?.peakRequests,
              'milliseconds': watch.elapsedMilliseconds,
              'fellBack': report?.fellBack,
              'verified': failure == null,
              'errorType': failure,
            }),
          );
          if (await file.exists()) await file.delete();
        }
      }
      expect(failures, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
