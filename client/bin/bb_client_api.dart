import 'dart:async';
import 'dart:io';

import 'package:bb_client/config/client_config.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/local_auth_server.dart';

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
///
/// The session is memory-only, so stopping this process leaves no login state
/// behind for the MCP plugin to reuse.
Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args, Platform.environment);
  } on ArgumentError catch (error) {
    stderr.writeln('配置错误: ${error.message}');
    exit(64);
  }

  final AuthApiClient api = AuthApiClient(baseUri: options.serverBaseUri);
  final AuthService service = AuthService(api: api, session: AuthSession());
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
  });

  final Uri serverBaseUri;
  final String host;
  final int port;

  factory _Options.parse(List<String> args, Map<String, String> env) {
    String? serverUrl = env['BB_API_BASE_URL'];
    String host = env['BB_CLIENT_HOST'] ?? loopbackHost;
    String? port = env['BB_LOCAL_API_PORT'];

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
        case '--help' || '-h':
          stdout.writeln(
            '用法: dart run bb_client_api '
            '[--server-url URL] [--host 127.0.0.1] [--port 8787]',
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

    return _Options(
      serverBaseUri: parseServerBaseUrl(serverUrl ?? defaultServerBaseUrl),
      host: host,
      port: parsedPort,
    );
  }
}
