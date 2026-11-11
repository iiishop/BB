import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

/// Regression for QA-465-01: the standalone Dart entry must compile and run
/// without Flutter/dart:ui, and MCP login/401 must own the heartbeat lifecycle.
///
/// These tests deliberately spawn `dart run bin/bb_client_api.dart` as a
/// separate process. An in-process Flutter test server would never catch an
/// accidental `package:flutter` import in the shared services.
void main() {
  final String dartExecutable =
      Platform.environment['DART_EXECUTABLE'] ?? 'dart';
  final String clientRoot = Directory.current.path;

  group('standalone bb_client_api', () {
    test('--help compiles and exits 0 without Flutter', () async {
      final ProcessResult result = await Process.run(dartExecutable, <String>[
        'run',
        'bin/bb_client_api.dart',
        '--help',
      ], workingDirectory: clientRoot);
      expect(
        result.exitCode,
        0,
        reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout, contains('用法: dart run bb_client_api'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'local login starts heartbeat and a 401 clears memory + disk credentials',
      () async {
        final FakeAuthBackend backend = await FakeAuthBackend.start();
        final Directory directory = await Directory.systemTemp.createTemp(
          'bb-standalone-',
        );
        final File sessionFile = File('${directory.path}/session.json');
        final Directory cacheDirectory = Directory(
          '${directory.path}/avatar-cache',
        );
        Process? process;
        try {
          process = await Process.start(dartExecutable, <String>[
            'run',
            'bin/bb_client_api.dart',
            '--server-url',
            backend.baseUri.toString(),
            '--port',
            '0',
            '--session-file',
            sessionFile.path,
            '--avatar-cache-dir',
            cacheDirectory.path,
            // Test-only acceleration; the default stays 30s and is asserted
            // in heartbeat_controller_test.
            '--heartbeat-interval-seconds',
            '1',
          ], workingDirectory: clientRoot);
          final StringBuffer stderrBuffer = StringBuffer();
          final StringBuffer stdoutBuffer = StringBuffer();
          final Completer<Uri> address = Completer<Uri>();
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((String line) {
                stdoutBuffer.writeln(line);
                final RegExpMatch? match = RegExp(
                  r'listening on (http://127\.0\.0\.1:\d+)',
                ).firstMatch(line);
                if (match != null && !address.isCompleted) {
                  address.complete(Uri.parse(match.group(1)!));
                }
              });
          process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
          final Uri localAddress = await address.future.timeout(
            const Duration(seconds: 30),
          );

          // Empty-session startup: no heartbeat before a session exists.
          expect(sessionFile.existsSync(), isFalse);
          expect(backend.heartbeatCalls, 0);

          final _Response login = await _post(
            localAddress.resolve('/auth/login'),
            <String, dynamic>{
              'account': backend.validAccount,
              'password': backend.validPassword,
            },
          );
          expect(
            login.status,
            200,
            reason: '${login.raw}\n$stderrBuffer\n$stdoutBuffer',
          );
          expect(sessionFile.existsSync(), isTrue);

          // MCP/local login must arm the periodic heartbeat without a restart.
          await _waitFor(
            () => backend.heartbeatCalls >= 1,
            const Duration(seconds: 6),
            'standalone heartbeat after local login',
          );

          // A genuine 401 must clear both the memory session and the file.
          backend.heartbeatStatus = 401;
          await _waitFor(
            () => !sessionFile.existsSync(),
            const Duration(seconds: 8),
            'credential file removed after heartbeat 401',
          );

          final _Response afterExpiry = await _post(
            localAddress.resolve('/profile/view_nickname'),
            <String, dynamic>{},
          );
          expect(afterExpiry.status, 401);
          final Map<String, dynamic> error =
              afterExpiry.body['error'] as Map<String, dynamic>;
          expect(error['code'], 'unauthenticated');

          expect(
            stdoutBuffer.toString(),
            isNot(contains(backend.issuedToken)),
            reason: 'token must never be logged',
          );
          expect(stderrBuffer.toString(), isNot(contains(backend.issuedToken)));
        } finally {
          if (process != null) {
            process.kill(ProcessSignal.sigterm);
            try {
              await process.exitCode.timeout(const Duration(seconds: 10));
            } on TimeoutException {
              process.kill(ProcessSignal.sigkill);
            }
          }
          await backend.close();
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

Future<void> _waitFor(
  bool Function() condition,
  Duration timeout,
  String description,
) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $description');
}

class _Response {
  const _Response(this.status, this.body, this.raw);

  final int status;
  final Map<String, dynamic> body;
  final String raw;
}

Future<_Response> _post(Uri uri, Map<String, dynamic> payload) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    final List<int> bytes = utf8.encode(jsonEncode(payload));
    request.contentLength = bytes.length;
    request.add(bytes);
    final HttpClientResponse response = await request.close();
    final String raw = await utf8.decoder.bind(response).join();
    return _Response(
      response.statusCode,
      jsonDecode(raw) as Map<String, dynamic>,
      raw,
    );
  } finally {
    client.close(force: true);
  }
}
