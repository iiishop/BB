import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real MCP → **standalone Dart subprocess** → FastAPI.
///
/// Opt-in: start `bb_server` yourself and run
/// `BB_LIVE_SERVER_URL=http://127.0.0.1:8171 BB_LIVE_DB_PATH=/abs/live.db \
///  BB_PROBE_PNG_BASE64=... BB_PROBE_AVATAR_PATH=/abs/a.png \
///  BB_PROBE_AVATAR_URL_PATH=/abs/b.png \
///  flutter test test/live_standalone_mcp_e2e_test.dart`.
///
/// Unlike `live_profile_e2e_test.dart`, the local control API here is a real
/// `dart run bin/bb_client_api.dart` child process with its own heartbeat,
/// credential file and 401 cleanup.
void main() {
  final String? configured = Platform.environment['BB_LIVE_SERVER_URL'];
  final String? baseUrl = (configured != null && configured.trim().isNotEmpty)
      ? configured.trim()
      : null;
  final String? dbPath = Platform.environment['BB_LIVE_DB_PATH'];
  final String? pngBase64 = Platform.environment['BB_PROBE_PNG_BASE64'];
  final String? avatarPath = Platform.environment['BB_PROBE_AVATAR_PATH'];
  final String? avatarUrlPath =
      Platform.environment['BB_PROBE_AVATAR_URL_PATH'];
  final String? skipReason =
      (baseUrl == null ||
          dbPath == null ||
          pngBase64 == null ||
          avatarPath == null ||
          avatarUrlPath == null)
      ? '真实独立入口链路缺少 BB_LIVE_SERVER_URL/BB_LIVE_DB_PATH/BB_PROBE_*（SKIP，不算 PASS）'
      : null;

  test(
    'real MCP drives the standalone Dart entry; login arms 30s heartbeat and 401 clears files',
    () async {
      final Uri server = Uri.parse(baseUrl!);
      final Directory directory = await Directory.systemTemp.createTemp(
        'bb-live-standalone-',
      );
      final File sessionFile = File('${directory.path}/session.json');
      final Directory cacheDirectory = Directory(
        '${directory.path}/avatar-cache',
      );
      Process? process;
      try {
        final AuthService registration = AuthService(
          api: AuthApiClient(baseUri: server),
          session: AuthSession(),
        );
        final AuthUser user = await registration.register(
          username: 'muse_${DateTime.now().microsecondsSinceEpoch % 100000000}',
          password: 'Secret42',
        );

        process = await Process.start(
          Platform.environment['DART_EXECUTABLE'] ?? 'dart',
          <String>[
            'run',
            'bin/bb_client_api.dart',
            '--server-url',
            server.toString(),
            '--port',
            '0',
            '--session-file',
            sessionFile.path,
            '--avatar-cache-dir',
            cacheDirectory.path,
            // Deliberately no interval override: prove the shipped 30s default.
          ],
          workingDirectory: Directory.current.path,
        );
        final StringBuffer stdoutBuffer = StringBuffer();
        final StringBuffer stderrBuffer = StringBuffer();
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
        expect(sessionFile.existsSync(), isFalse);

        // Session established through the real MCP auth tool, from an entry
        // that started with an empty session file.
        final Map<String, dynamic> probe = await _runProbe(
          baseUrl: localAddress.toString(),
          otherAccount: user.account,
          pngBase64: pngBase64!,
          avatarPath: avatarPath!,
          avatarUrlPath: avatarUrlPath!,
          loginAccount: user.account,
          loginPassword: 'Secret42',
        );
        expect(probe['tool_count'], 8);
        expect(probe['login_via_mcp'], isTrue);
        expect(probe['update_tools_have_no_account'], isTrue);
        expect(probe['nickname_assigned'], 'Muse Live');
        expect(probe['avatar_versions'], hasLength(4));
        expect(sessionFile.existsSync(), isTrue);
        final Map<String, dynamic> session = jsonDecode(
          await sessionFile.readAsString(),
        ) as Map<String, dynamic>;
        final String token = session['token']! as String;

        // The login came from MCP, not from startup: the shipped 30s heartbeat
        // must still have been armed and produce a new last_seen_at.
        final double before = await _lastSeenAt(dbPath!);
        await Future<void>.delayed(const Duration(seconds: 32));
        final double after = await _lastSeenAt(dbPath);
        expect(
          after,
          greaterThan(before),
          reason: 'standalone entry must heartbeat 30s after MCP login',
        );

        // Server-side logout of the very session the standalone process holds.
        // The next local call gets a genuine 401, which must clear both copies.
        await _logout(server, token);
        final _Response expired = await _post(
          localAddress.resolve('/profile/view_nickname'),
          <String, dynamic>{},
        );
        expect(expired.status, 401);
        expect(
          (expired.body['error'] as Map<String, dynamic>)['code'],
          'unauthenticated',
        );
        await _waitFor(
          () => !sessionFile.existsSync(),
          const Duration(seconds: 10),
          'standalone credential file removed after revoked session',
        );
        expect(
          stdoutBuffer.toString(),
          isNot(contains(token)),
          reason: 'the standalone entry must not log the token',
        );
        expect(stderrBuffer.toString(), isNot(contains(token)));
      } finally {
        if (process != null) {
          process.kill(ProcessSignal.sigterm);
          try {
            await process.exitCode.timeout(const Duration(seconds: 10));
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
          }
        }
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<double> _lastSeenAt(String databasePath) async {
  final ProcessResult result = await Process.run('python3', <String>[
    '-c',
    'import sqlite3,sys;'
        'c=sqlite3.connect(sys.argv[1]);'
        "r=c.execute('select last_seen_at from sessions order by rowid desc limit 1').fetchone();"
        'print(r[0] if r else 0)',
    databasePath,
  ]);
  if (result.exitCode != 0) {
    fail('无法读取会话时间: ${result.stderr}');
  }
  return double.parse((result.stdout as String).trim());
}

Future<void> _logout(Uri server, String token) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(
      server.resolve('/auth/logout'),
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final HttpClientResponse response = await request.close();
    final String body = await utf8.decoder.bind(response).join();
    if (response.statusCode != 204) {
      fail('logout failed: ${response.statusCode} $body');
    }
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _runProbe({
  required String baseUrl,
  required String otherAccount,
  required String pngBase64,
  required String avatarPath,
  required String avatarUrlPath,
  required String loginAccount,
  required String loginPassword,
}) async {
  // Serve the third source over a tiny local HTTP server owned by this test.
  final HttpServer imageServer = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final Uint8List urlPng = await File(avatarUrlPath).readAsBytes();
  imageServer.listen((HttpRequest request) async {
    request.response.headers.contentType = ContentType('image', 'png');
    request.response.add(urlPng);
    await request.response.close();
  });
  try {
    final Process process = await Process.start(
      'uv',
      <String>[
        'run',
        '--project',
        'dsh-plugin',
        '--locked',
        'python',
        'scripts/mcp_profile_probe.py',
      ],
      environment: <String, String>{
        'BB_CLIENT_BASE_URL': baseUrl,
        'BB_PROBE_PNG_BASE64': pngBase64,
        'BB_PROBE_AVATAR_PATH': avatarPath,
        'BB_PROBE_AVATAR_URL':
            'http://127.0.0.1:${imageServer.port}/avatar.png',
        'BB_PROBE_OTHER_ACCOUNT': otherAccount,
        'BB_PROBE_LOGIN_ACCOUNT': loginAccount,
        'BB_PROBE_LOGIN_PASSWORD': loginPassword,
      },
      includeParentEnvironment: true,
      workingDirectory: Directory.current.parent.path,
    );
    final StringBuffer stdoutBuffer = StringBuffer();
    final StringBuffer stderrBuffer = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(stdoutBuffer.write);
    process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
    final int exitCode = await process.exitCode.timeout(
      const Duration(minutes: 2),
    );
    if (exitCode != 0) {
      fail('MCP probe exit=$exitCode\n$stdoutBuffer\n$stderrBuffer');
    }
    final List<String> lines = stdoutBuffer
        .toString()
        .trim()
        .split('\n')
        .where((String line) => line.trim().startsWith('{'))
        .toList();
    if (lines.isEmpty) {
      fail('MCP probe printed no JSON\n$stdoutBuffer\n$stderrBuffer');
    }
    return jsonDecode(lines.last) as Map<String, dynamic>;
  } finally {
    await imageServer.close(force: true);
  }
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
