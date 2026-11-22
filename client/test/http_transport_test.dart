import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
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

/// Hold only openUrl completion; the underlying request/socket are real.
class _DelayedOpenClient implements HttpClient {
  final inner = HttpClient();
  final opened = Completer<void>();
  final release = Completer<void>();
  @override
  set connectionTimeout(Duration? value) {
    inner.connectionTimeout = value;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await inner.openUrl(method, url);
    if (!opened.isCompleted) opened.complete();
    await release.future;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('cancelling one active body preserves concurrent request and its pooled socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final fastOpened = Completer<void>();
    final releaseFast = Completer<void>();
    final ports = <String, int>{};
    server.listen((request) async {
      ports[request.uri.path] = request.connectionInfo!.remotePort;
      try {
        if (request.uri.path == '/slow') {
          request.response.bufferOutput = false;
          request.response.contentLength = 100;
          request.response.write('x');
          await request.response.flush();
          return;
        }
        if (request.uri.path == '/fast') {
          fastOpened.complete();
          await releaseFast.future;
        }
        request.response.write('ok');
        await request.response.close();
      } catch (_) {}
    });
    final transport = HttpTransport();
    addTearDown(() => transport.client.close(force: true));
    final received = Completer<void>();
    final cancel = RequestCancellation();
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final slow = transport.send(
      'GET',
      base.resolve('/slow'),
      service: 'chat',
      timeout: const Duration(seconds: 2),
      maxBytes: 1000,
      cancellation: cancel,
      onProgress: (_, _) {
        if (!received.isCompleted) received.complete();
      },
    );
    final failure = expectLater(slow, throwsA(isA<AuthFailure>()));
    await received.future;
    final fast = transport.send(
      'GET',
      base.resolve('/fast'),
      service: 'chat',
      timeout: const Duration(seconds: 2),
      maxBytes: 1000,
    );
    await fastOpened.future;
    cancel.cancel();
    await failure;
    releaseFast.complete();
    expect(utf8.decode((await fast).bytes), 'ok');
    await transport.send(
      'GET',
      base.resolve('/next'),
      service: 'chat',
      timeout: const Duration(seconds: 2),
      maxBytes: 1000,
    );
    expect(ports['/slow'], isNot(ports['/fast']));
    expect(ports['/next'], ports['/fast']);
  });
  for (final cancelExplicitly in [false, true]) {
    test(
      'late open completion never writes after ${cancelExplicitly ? 'cancel' : 'deadline'}',
      () async {
        final server = await _CountingServer.start();
        addTearDown(server.stop);
        final delayed = _DelayedOpenClient();
        addTearDown(() => delayed.inner.close(force: true));
        final transport = HttpTransport(factory: () => delayed);
        final cancel = RequestCancellation();
        final pending = transport.send(
          'POST',
          Uri.parse('http://127.0.0.1:${server.port}/write'),
          service: 'auth',
          timeout: Duration(milliseconds: cancelExplicitly ? 1000 : 100),
          maxBytes: 100,
          body: utf8.encode('private'),
          cancellation: cancel,
        );
        final assertion = expectLater(pending, throwsA(isA<AuthFailure>()));
        await delayed.opened.future;
        if (cancelExplicitly) cancel.cancel();
        await assertion;
        expect(HttpTransport.diagnostics.last.phase, NetworkPhase.opening);
        delayed.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          server.requests,
          0,
          reason: 'no late credentials or POST payload',
        );
        final response = await transport.send(
          'GET',
          Uri.parse('http://127.0.0.1:${server.port}/next'),
          service: 'auth',
          timeout: const Duration(seconds: 1),
          maxBytes: 100,
        );
        expect(response.status, 200);
        expect(server.requests, 1);
      },
    );
  }
  test('deadline aborts a stalled upload and records sending phase', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {}, onError: (Object _) {}).pause();
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    final transport = HttpTransport();
    addTearDown(() => transport.client.close(force: true));
    await expectLater(
      transport.send(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}/upload'),
        service: 'chat',
        timeout: const Duration(milliseconds: 200),
        maxBytes: 100,
        body: Uint8List(16 * 1024 * 1024),
      ),
      throwsA(
        isA<AuthFailure>().having((e) => e.code, 'code', 'upstream_timeout'),
      ),
    );
    expect(HttpTransport.diagnostics.last.phase, NetworkPhase.sending);
    expect(sockets.length, 1);
  });
  test('send path preserves keep-alive and can recover after cancelling a response', () async {
    final server = await _CountingServer.start();
    addTearDown(server.stop);
    final transport = HttpTransport();
    addTearDown(() => transport.client.close(force: true));
    for (int i = 0; i < 3; i++) {
      final response = await transport.send(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/probe'),
        service: 'chat',
        timeout: const Duration(seconds: 1),
        maxBytes: 100,
      );
      expect(utf8.decode(response.bytes), 'ok');
    }
    expect(server.accepts, 1);
    final cancel = RequestCancellation()..cancel();
    await expectLater(
      transport.send(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}/write'),
        service: 'chat',
        timeout: const Duration(seconds: 1),
        maxBytes: 100,
        cancellation: cancel,
      ),
      throwsA(isA<AuthFailure>()),
    );
    expect(server.requests, 3);
    await transport.send(
      'GET',
      Uri.parse('http://127.0.0.1:${server.port}/probe'),
      service: 'chat',
      timeout: const Duration(seconds: 1),
      maxBytes: 100,
    );
    expect(server.requests, 4);
    expect(server.accepts, 1);
  });

  for (final tls in [false, true]) {
    test(
      'diagnostics retain ${tls ? 'TLS handshake' : 'HTTP body truncation'} category',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        server.listen((socket) {
          sockets.add(socket);
          socket.listen((_) async {
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx');
            await socket.flush();
            await socket.close();
          }, onError: (Object _) {});
        });
        addTearDown(() async {
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        final transport = HttpTransport();
        addTearDown(() => transport.client.close(force: true));
        await expectLater(
          transport.send(
            'GET',
            Uri.parse(
              '${tls ? 'https' : 'http'}://127.0.0.1:${server.port}/private?secret=private',
            ),
            service: 'chat',
            timeout: const Duration(seconds: 2),
            maxBytes: 1000,
          ),
          throwsA(
            isA<AuthFailure>().having(
              (e) => e.code,
              'code',
              'upstream_unavailable',
            ),
          ),
        );
        final diagnostic = HttpTransport.diagnostics.last;
        expect(
          diagnostic.kind,
          tls ? NetworkErrorKind.tls : NetworkErrorKind.http,
        );
        expect(
          diagnostic.phase,
          tls ? NetworkPhase.opening : NetworkPhase.body,
        );
      },
    );
  }
  for (final bodyStarted in [false, true]) {
    for (final explicitCancel in [false, true]) {
      test(
        'wire socket closes on ${explicitCancel ? 'cancel' : 'deadline'} during ${bodyStarted ? 'body' : 'headers'}',
        () async {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final seen = Completer<void>();
          final closed = Completer<void>();
          final sockets = <Socket>[];
          int requests = 0;
          server.listen((socket) {
            sockets.add(socket);
            bool sent = false;
            socket.listen(
              (bytes) {
                if (sent) return;
                sent = true;
                requests++;
                if (bodyStarted) {
                  socket.add(
                    latin1.encode(
                      'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx',
                    ),
                  );
                }
                if (!seen.isCompleted) seen.complete();
              },
              onDone: () {
                if (!closed.isCompleted) closed.complete();
              },
              onError: (Object _) {
                if (!closed.isCompleted) closed.complete();
              },
            );
          });
          addTearDown(() async {
            for (final socket in sockets) {
              socket.destroy();
            }
            await server.close();
          });
          final cancel = RequestCancellation();
          final transport = HttpTransport();
          final pending = transport.send(
            'POST',
            Uri.parse('http://127.0.0.1:${server.port}/secret?token=private'),
            service: 'auth',
            timeout: Duration(milliseconds: explicitCancel ? 2000 : 200),
            maxBytes: 1000,
            body: utf8.encode('private password'),
            cancellation: cancel,
          );
          final assertion = expectLater(
            pending,
            throwsA(
              isA<AuthFailure>().having(
                (e) => e.code,
                'code',
                explicitCancel ? 'upstream_unavailable' : 'upstream_timeout',
              ),
            ),
          );
          await seen.future.timeout(const Duration(seconds: 1));
          if (explicitCancel) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            cancel.cancel();
          }
          await assertion;
          await closed.future.timeout(const Duration(seconds: 1));
          expect(requests, 1, reason: 'POST is not replayed');
          final diagnostic = HttpTransport.diagnostics.last;
          expect(
            diagnostic.phase,
            bodyStarted ? NetworkPhase.body : NetworkPhase.headers,
          );
          expect(
            diagnostic.kind,
            explicitCancel
                ? NetworkErrorKind.cancelled
                : NetworkErrorKind.deadline,
          );
          // A cancelled request must not poison the shared connection pool.
          transport.client.close(force: true);
        },
      );
    }
  }
  test('同一 transport 的连续请求复用一条 TCP 连接', () async {
    final _CountingServer server = await _CountingServer.start();
    addTearDown(server.stop);
    final HttpTransport transport = HttpTransport();

    for (int i = 0; i < 5; i++) {
      await _get(transport.client, server.port);
    }

    expect(server.requests, 5);
    expect(server.accepts, 1, reason: '每个请求重建 HttpClient 的旧写法会得到 5 条连接');
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
