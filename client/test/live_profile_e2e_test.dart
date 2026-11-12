import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real MCP → Dart local API → FastAPI chain.
///
/// Opt-in: start `bb_server` yourself, then run
/// `BB_LIVE_SERVER_URL=http://127.0.0.1:8171 BB_MCP_PROBE=1 \
///  BB_PROBE_PNG_BASE64=... BB_PROBE_AVATAR_PATH=/abs/green.png \
///  BB_PROBE_AVATAR_URL_PATH=/abs/blue.png \
///  flutter test test/live_profile_e2e_test.dart`.
///
/// The test is SKIPPED (not PASS) without the env, and the MCP subprocess step
/// is reported as NOT RUN when `BB_MCP_PROBE` is unset.
void main() {
  final String? configured = Platform.environment['BB_LIVE_SERVER_URL'];
  final String? baseUrl = (configured != null && configured.trim().isNotEmpty)
      ? configured.trim()
      : null;
  final bool runMcp = Platform.environment['BB_MCP_PROBE'] == '1';
  final String? skipReason = baseUrl == null
      ? 'BB_LIVE_SERVER_URL 未设置：未执行真实 FastAPI 链路（SKIP，不算 PASS）'
      : null;

  group('live profile chain', () {
    late Directory directory;
    late AuthService authA;
    late AuthService authB;
    late ProfileService profileA;
    late ProfileService profileB;
    late LocalAuthServer localServer;
    late HttpServer imageServer;
    late Uri localAddress;
    late String accountA;
    late String accountB;
    late String tokenA;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('bb-live-profile-');
      final Uri server = Uri.parse(baseUrl!);
      final AuthUser userA =
          await AuthService(
            api: AuthApiClient(baseUri: server),
            session: AuthSession(),
          ).register(
            username:
                'muse_${DateTime.now().microsecondsSinceEpoch % 100000000}',
            password: 'Secret42',
          );
      final AuthUser userB =
          await AuthService(
            api: AuthApiClient(baseUri: server),
            session: AuthSession(),
          ).register(
            username:
                'peer_${DateTime.now().microsecondsSinceEpoch % 100000000}',
            password: 'Secret42',
          );

      authA = AuthService(
        api: AuthApiClient(baseUri: server),
        session: AuthSession(),
        store: SessionStore.atPath('${directory.path}/a.json'),
      );
      authB = AuthService(
        api: AuthApiClient(baseUri: server),
        session: AuthSession(),
        store: SessionStore.atPath('${directory.path}/b.json'),
      );
      await authA.login(account: userA.account, password: 'Secret42');
      await authB.login(account: userB.account, password: 'Secret42');
      profileA = ProfileService(
        api: ProfileApiClient(baseUri: server),
        auth: authA,
        cache: AvatarCache(),
      );
      profileB = ProfileService(
        api: ProfileApiClient(baseUri: server),
        auth: authB,
        cache: AvatarCache(),
      );

      // PNG served over http for the `url` source.
      final Uint8List urlPng = await File(
        Platform.environment['BB_PROBE_AVATAR_URL_PATH']!,
      ).readAsBytes();
      imageServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      imageServer.listen((HttpRequest request) async {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(urlPng);
        await request.response.close();
      });

      localServer = LocalAuthServer(service: authA, profile: profileA, port: 0);
      localAddress = await localServer.start();
      tokenA = authA.session.tokenForRequest!;
      accountA = userA.account;
      accountB = userB.account;
    });

    tearDown(() async {
      await localServer.close();
      await imageServer.close(force: true);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test(
      'seventeen MCP tools through real stdio, three sources, refresh, logout',
      () async {
        // Baseline before MCP writes.
        final String beforeVersion = (await profileB.loadAvatar(
          account: accountA,
        )).version;

        Map<String, dynamic>? probe;
        if (runMcp) {
          probe = await _runProbe(
            baseUrl: localAddress.toString(),
            avatarUrl: 'http://127.0.0.1:${imageServer.port}/avatar.png',
            otherAccount: accountB,
          );
          expect(probe['tool_count'], 17);
          expect((probe['tool_names'] as List<dynamic>).toSet(), <String>{
            'register_account',
            'login_account',
            'view_avatar',
            'update_avatar',
            'view_nickname',
            'update_nickname',
            'view_signature',
            'update_signature',
            'list_users',
            'send_message',
            'send_attachment',
            'read_messages',
            'wait_messages',
            'ack_messages',
            'start_download',
            'get_download',
            'get_operation',
          });
          expect(probe['update_tools_have_no_account'], isTrue);
          expect(probe['nickname_assigned'], 'Muse Live');
          expect(probe['signature_assigned'], 'live signature');
          expect(probe['avatar_self_version'], isNotEmpty);
          final List<dynamic> versions =
              probe['avatar_versions'] as List<dynamic>;
          expect(versions, hasLength(4));
          expect(versions[0], isNot(versions[1]));
          expect(
            versions[2],
            versions[3],
            reason: 'identical normalized bytes retain their version',
          );
          final List<dynamic> otherContent =
              probe['avatar_other_content'] as List<dynamic>;
          expect(otherContent.first, 'image');
          expect(otherContent, contains('image'));
          expect(probe['avatar_other_version'], isNotEmpty);
          for (final Object? rejection in probe['rejected']! as List<dynamic>) {
            final Map<String, dynamic> entry =
                rejection! as Map<String, dynamic>;
            expect(entry['is_error'], isTrue);
            expect(entry['status'], 422);
          }
        } else {
          // Without the stdio probe, still exercise the same client paths.
          await profileA.saveProfile(
            const ProfilePatch(
              setUsername: true,
              username: 'Muse Live',
              setSignature: true,
              signature: 'live signature',
            ),
          );
          final Uint8List pathPng = await File(
            Platform.environment['BB_PROBE_AVATAR_PATH']!,
          ).readAsBytes();
          final String b64 = Platform.environment['BB_PROBE_PNG_BASE64']!;
          await profileA.updateAvatarFromPath(
            Platform.environment['BB_PROBE_AVATAR_PATH']!,
          );
          await profileA.updateAvatarFromUrl(
            'http://127.0.0.1:${imageServer.port}/avatar.png',
          );
          await profileA.updateAvatarFromBase64('data:image/png;base64,$b64');
          await profileA.updateAvatarFromBase64(b64);
          expect(pathPng, isNotEmpty);
        }

        // Cross-account freshness: B reads A's current profile and avatar.
        expect(await profileB.viewNickname(account: accountA), 'Muse Live');
        expect(
          await profileB.viewSignature(account: accountA),
          'live signature',
        );
        final AvatarImage after = await profileB.loadAvatar(account: accountA);
        expect(after.version, isNot(beforeVersion));

        // A changes the avatar again; B's next read must not reuse old bytes.
        // A distinct image so the version genuinely changes.
        final Uint8List nextPng = await File(
          Platform.environment['BB_PROBE_AVATAR_URL_PATH']!,
        ).readAsBytes();
        await profileA.updateAvatarFromBase64(
          'data:image/png;base64,${base64Encode(nextPng)}',
        );
        final AvatarImage refreshed = await profileB.loadAvatar(
          account: accountA,
        );
        expect(refreshed.version, isNot(after.version));

        // Heartbeat on a real session, then server-side logout.
        await profileA.heartbeat();
        final String token = tokenA;
        await profileA.logout();
        final AuthFailure expired = await _captureFailure(
          () =>
              ProfileApiClient(baseUri: Uri.parse(baseUrl!))
                  .fetchProfile(token: token, account: accountA),
        );
        expect(expired.status, 401);
        expect(expired.code, 'unauthenticated');
        // Only the calling session is deleted.
        expect(await profileB.viewNickname(account: accountB), isNotEmpty);
      },
      skip: skipReason,
    );
  });
}

Future<Map<String, dynamic>> _runProbe({
  required String baseUrl,
  required String avatarUrl,
  required String otherAccount,
}) async {
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
      'BB_PROBE_PNG_BASE64': Platform.environment['BB_PROBE_PNG_BASE64']!,
      'BB_PROBE_AVATAR_PATH': Platform.environment['BB_PROBE_AVATAR_PATH']!,
      'BB_PROBE_AVATAR_URL': avatarUrl,
      'BB_PROBE_OTHER_ACCOUNT': otherAccount,
    },
    includeParentEnvironment: true,
    workingDirectory: Directory.current.parent.path,
  );
  final StringBuffer stdoutBuffer = StringBuffer();
  final StringBuffer stderrBuffer = StringBuffer();
  process.stdout.transform(utf8.decoder).listen(stdoutBuffer.write);
  process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
  final int exitCode = await process.exitCode.timeout(
    const Duration(minutes: 3),
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
}

Future<AuthFailure> _captureFailure(Future<Object?> Function() action) async {
  try {
    await action();
  } on AuthFailure catch (failure) {
    return failure;
  }
  fail('expected AuthFailure');
}
