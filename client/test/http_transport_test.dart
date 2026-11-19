import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/services/http_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计数用的极简 HTTP/1.1 服务器：只数字收到了几条 TCP 连接。
///
/// 用裸 Socket 而不是 HttpServer，因为要的是 accept 次数——`HttpServer` 不暴露它。
class _CountingServer {
  _CountingServer(this._server) {
    _server.listen(_onSocket);
  }

  static Future<_CountingServer> start() async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _CountingServer(socket);
  }

  final ServerSocket _server;
  int accepts = 0;
  int requests = 0;

  /// 每次应答后隔这么久静默销毁连接，模拟 keep-alive 超时（服务端不打招呼）。
  Duration? killIdleAfter;

  int get port => _server.port;

  void _onSocket(Socket socket) {
    accepts++;
    final List<int> buffer = <int>[];
    socket.listen(
      (List<int> data) {
        buffer.addAll(data);
        String text = latin1.decode(buffer, allowInvalid: true);
        while (text.contains('\r\n\r\n')) {
          buffer.removeRange(0, text.indexOf('\r\n\r\n') + 4);
          text = latin1.decode(buffer, allowInvalid: true);
          requests++;
          socket.add(
            latin1.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'),
          );
          final Duration? idle = killIdleAfter;
          if (idle != null) {
            Timer(idle, () {
              socket.flush().then((_) => socket.destroy()).catchError((_) {});
            });
          }
        }
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  Future<void> stop() async {
    await _server.close();
  }
}

Future<void> _get(HttpClient client, int port) async {
  final HttpClientRequest request = await client.getUrl(
    Uri.parse('http://127.0.0.1:$port/probe'),
  );
  final HttpClientResponse response = await request.close();
  await response.drain<void>();
  expect(response.statusCode, 200);
}

void main() {
  test('同一 transport 的连续请求复用一条 TCP 连接', () async {
    final _CountingServer server = await _CountingServer.start();
    addTearDown(server.stop);
    final HttpTransport transport = HttpTransport();

    for (int i = 0; i < 5; i++) {
      await _get(transport.client, server.port);
    }

    expect(server.requests, 5);
    expect(
      server.accepts,
      1,
      reason: '每个请求重建 HttpClient 的旧写法会得到 5 条连接',
    );
  });

  test('服务端关掉连接后，下一次请求自动新建连接而不是失败', () async {
    final _CountingServer server = await _CountingServer.start();
    addTearDown(server.stop);
    server.killIdleAfter = const Duration(milliseconds: 50);
    final HttpTransport transport = HttpTransport();

    await _get(transport.client, server.port);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _get(transport.client, server.port);

    expect(server.requests, 2);
    expect(server.accepts, 2);
  });
}
