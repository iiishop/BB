import 'dart:async';
import 'dart:io';

import 'package:bb_client/config/client_config.dart';
import 'package:bb_client/config/session_path.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/heartbeat_controller.dart';
import 'package:bb_client/services/local_auth_server.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';

/// Standalone Dart entry for the client's local control API.
///
/// Runs without Flutter: `dart run bb_client_api`.
///
/// Configuration (flags win over environment):
///   --port          local control-API port   (env BB_LOCAL_API_PORT, default
///                                             8787)
///   --host          must be 127.0.0.1        (env BB_CLIENT_HOST)
///   --server-url    FastAPI base URL         (env BB_API_BASE_URL, default
///                                             http://127.0.0.1:8000)
///   --session-file  persisted session file   (env BB_SESSION_FILE, default
///                                             platform data directory)
///   --heartbeat-interval-seconds  beat period (env
///                                             BB_HEARTBEAT_INTERVAL_SECONDS,
///                                             default 30)
///
/// Startup reads the persisted credential from the same store the Flutter UI
/// uses and verifies it with `GET /auth/session`. An MCP/local `POST /auth/login`
/// starts the same 30-second heartbeat; a genuine 401 clears the in-memory and
/// on-disk credential. Nothing about the token is printed or exposed to local
/// API callers.
Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args, Platform.environment);
  } on ArgumentError catch (error) {
    stderr.writeln('配置错误: ${error.message}');
    exit(64);
  } on StateError catch (error) {
    stderr.writeln('配置错误: ${error.message}');
    exit(64);
  }

  final AuthApiClient api = AuthApiClient(baseUri: options.serverBaseUri);
  final AuthService service = AuthService(
    api: api,
    session: AuthSession(),
    store: SessionStore(options.sessionFile),
  );
  final ProfileService profile = ProfileService(
    api: ProfileApiClient(baseUri: options.serverBaseUri),
    auth: service,
    cache: AvatarCache(directory: options.avatarCacheDirectory),
  );
  final HeartbeatController heartbeat = HeartbeatController(
    auth: service,
    interval: options.heartbeatInterval,
  );
  final ChatService chat = ChatService(
    api: ChatApiClient(baseUri: options.serverBaseUri),
    session: service.session,
    ledger: ChatLedger.atPath(options.chatLedgerPath),
    cacheRoot: options.chatCacheDirectory,
  );
  chat.start();
  bool expiring = false;

  /// A genuine 401 is a revoked/expired session: clear both copies of the
  /// credential and stop the timer. Network failures never reach this path.
  Future<void> expireSession() async {
    if (expiring) {
      return;
    }
    expiring = true;
    heartbeat.stop();
    try {
      await service.signOut();
      stdout.writeln('本地会话已失效，已清除凭据');
    } on AuthFailure catch (failure) {
      // signOut keeps the in-memory session when the file cannot be removed;
      // clear it anyway so the revoked token is never used again.
      service.session.clear();
      if (failure.code == sessionStorageUnavailable.code) {
        stderr.writeln('本地会话已失效，但凭据文件删除失败，请手动检查会话目录');
      } else {
        stderr.writeln('本地会话已失效，清除凭据失败（${failure.code}）');
      }
    } catch (_) {
      service.session.clear();
      stderr.writeln('本地会话已失效，清除凭据失败');
    } finally {
      expiring = false;
    }
  }

  heartbeat.addListener(() {
    if (heartbeat.phase == HeartbeatPhase.unauthorized) {
      unawaited(expireSession());
    }
  });

  // Restore before listening: a second launch re-validates the stored credential
  // with the shared session store. Status only — never account, token or body.
  bool restored = false;
  try {
    restored = await service.restoreSession() != null;
    stdout.writeln(restored ? '已恢复本地会话' : '本地无有效会话');
    if (restored) {
      heartbeat.start();
    }
  } on AuthFailure catch (failure) {
    if (failure.status == 401) {
      stdout.writeln('本地会话已失效，已清除凭据');
    } else if (failure.code == sessionStorageUnavailable.code) {
      stdout.writeln('会话存储不可用，无法验证本地会话');
    } else {
      stdout.writeln('暂时无法验证本地会话（${failure.code}），凭据已保留');
    }
  }

  if (restored) {
    unawaited(chat.downloads.resumePending());
  }

  final LocalAuthServer server = LocalAuthServer(
    service: service,
    profile: profile,
    chat: chat,
    host: options.host,
    port: options.port,
    onSessionEstablished: () {
      heartbeat.start();
      unawaited(chat.resumeForCurrentSession());
      stdout.writeln('本地控制接口会话已建立，心跳已启动');
    },
    onUnauthorized: expireSession,
  );

  final Uri address;
  try {
    address = await server.start();
  } on ArgumentError catch (error) {
    stderr.writeln('配置错误: ${error.message}');
    exit(64);
  } on SocketException catch (error) {
    stderr.writeln('无法监听 ${options.host}:${options.port}: ${error.message}');
    exit(1);
  }

  // Only the bound address is printed; no credentials, bodies or tokens.
  stdout.writeln('BB local control API listening on $address');
  stdout.writeln('Upstream server: ${options.serverBaseUri}');

  Future<void> stop() async {
    heartbeat.stop();
    await server.close();
    await chat.dispose();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => stop());
  ProcessSignal.sigterm.watch().listen((_) => stop());
  await Completer<void>().future;
}

class _Options {
  const _Options({
    required this.serverBaseUri,
    required this.host,
    required this.port,
    required this.sessionFile,
    required this.avatarCacheDirectory,
    required this.chatLedgerPath,
    required this.chatCacheDirectory,
    required this.heartbeatInterval,
  });

  final Uri serverBaseUri;
  final String host;
  final int port;
  final File sessionFile;
  final Directory avatarCacheDirectory;
  final String chatLedgerPath;
  final Directory chatCacheDirectory;
  final Duration heartbeatInterval;

  factory _Options.parse(List<String> args, Map<String, String> env) {
    String? serverUrl = env['BB_API_BASE_URL'];
    String host = env['BB_CLIENT_HOST'] ?? loopbackHost;
    String? port = env['BB_LOCAL_API_PORT'];
    String? sessionFile = env[sessionFileEnvironmentVariable];
    String? avatarCacheDir = env['BB_AVATAR_CACHE_DIR'];
    String? heartbeatSeconds = env['BB_HEARTBEAT_INTERVAL_SECONDS'];

    for (int i = 0; i < args.length; i++) {
      final String arg = args[i];
      String next() {
        if (i + 1 >= args.length) {
          throw ArgumentError('参数 $arg 缺少取值');
        }
        i += 1;
        return args[i];
      }

      switch (arg) {
        case '--server-url':
          serverUrl = next();
        case '--host':
          host = next();
        case '--port':
          port = next();
        case '--session-file':
          sessionFile = next();
        case '--avatar-cache-dir':
          avatarCacheDir = next();
        case '--heartbeat-interval-seconds':
          heartbeatSeconds = next();
        case '--help' || '-h':
          stdout.writeln(
            '用法: dart run bb_client_api '
            '[--server-url URL] [--host 127.0.0.1] [--port 8787] '
            '[--session-file PATH] [--avatar-cache-dir DIR] '
            '[--heartbeat-interval-seconds 30]',
          );
          exit(0);
        default:
          throw ArgumentError('未知参数: $arg');
      }
    }

    final int parsedPort;
    if (port == null) {
      parsedPort = defaultLocalPort;
    } else {
      final int? value = int.tryParse(port);
      if (value == null || value < 0 || value > 65535) {
        throw ArgumentError.value(port, '--port', '端口必须是 0–65535 的整数');
      }
      parsedPort = value;
    }
    if (host != loopbackHost) {
      throw ArgumentError.value(
        host,
        '--host',
        '本地控制接口只允许监听 $loopbackHost，拒绝非回环地址',
      );
    }

    final File session =
        ((sessionFile != null && sessionFile.trim().isNotEmpty)
                ? File(sessionFile.trim())
                : resolveSessionFile(environment: env))
            .absolute;

    final Directory cacheDirectory =
        (avatarCacheDir != null && avatarCacheDir.trim().isNotEmpty)
        ? Directory(avatarCacheDir.trim())
        : Directory(
            '${session.parent.path}${Platform.pathSeparator}avatar-cache',
          );
    final Directory absoluteCache = cacheDirectory.absolute;

    final double intervalSeconds = heartbeatSeconds == null
        ? 30
        : double.tryParse(heartbeatSeconds) ?? -1;
    if (!intervalSeconds.isFinite || intervalSeconds <= 0) {
      throw ArgumentError.value(
        heartbeatSeconds,
        '--heartbeat-interval-seconds',
        '心跳间隔必须是正数秒',
      );
    }

    final Directory chatCache = Directory(
      '${session.parent.path}${Platform.pathSeparator}chat-cache',
    );

    return _Options(
      serverBaseUri: parseServerBaseUrl(serverUrl ?? defaultServerBaseUrl),
      host: host,
      port: parsedPort,
      sessionFile: session,
      avatarCacheDirectory: absoluteCache,
      chatLedgerPath:
          '${session.parent.path}${Platform.pathSeparator}chat-ledger.json',
      chatCacheDirectory: chatCache,
      heartbeatInterval: Duration(
        microseconds: (intervalSeconds * Duration.microsecondsPerSecond)
            .round(),
      ),
    );
  }
}
