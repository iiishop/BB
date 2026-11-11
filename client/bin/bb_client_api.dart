import 'dart:async';
import 'dart:io';

import 'package:bb_client/config/client_config.dart';
import 'package:bb_client/config/session_path.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/local_auth_server.dart';
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
///
/// Startup reads the persisted credential from the same store the Flutter UI
/// uses and verifies it with `GET /auth/session`. Nothing about the token is
/// printed or exposed to the local API callers.
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

  // Restore before listening: a second launch re-validates the stored credential
  // with the shared session store. Status only — never account, token or body.
  try {
    final bool restored = await service.restoreSession() != null;
    stdout.writeln(restored ? '已恢复本地会话' : '本地无有效会话');
  } on AuthFailure catch (failure) {
    if (failure.status == 401) {
      stdout.writeln('本地会话已失效，已清除凭据');
    } else {
      stdout.writeln('暂时无法验证本地会话（${failure.code}），凭据已保留');
    }
  }

  final LocalAuthServer server = LocalAuthServer(
    service: service,
    host: options.host,
    port: options.port,
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
    await server.close();
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
  });

  final Uri serverBaseUri;
  final String host;
  final int port;
  final File sessionFile;

  factory _Options.parse(List<String> args, Map<String, String> env) {
    String? serverUrl = env['BB_API_BASE_URL'];
    String host = env['BB_CLIENT_HOST'] ?? loopbackHost;
    String? port = env['BB_LOCAL_API_PORT'];
    String? sessionFile = env[sessionFileEnvironmentVariable];

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
        case '--help' || '-h':
          stdout.writeln(
            '用法: dart run bb_client_api '
            '[--server-url URL] [--host 127.0.0.1] [--port 8787] '
            '[--session-file PATH]',
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

    final File session = (sessionFile != null && sessionFile.trim().isNotEmpty)
        ? File(sessionFile.trim())
        : resolveSessionFile(environment: env);

    return _Options(
      serverBaseUri: parseServerBaseUrl(serverUrl ?? defaultServerBaseUrl),
      host: host,
      port: parsedPort,
      sessionFile: session,
    );
  }
}
