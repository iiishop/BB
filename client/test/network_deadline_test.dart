import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/http_transport.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'media probe deadline includes draining an ignored range response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.add([1]);
        try {
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await request.response.close();
        } catch (_) {}
      });
      final api = ChatApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        api.probeMedia(token: 'private', mediaId: 'private'),
        throwsA(
          isA<AuthFailure>().having((e) => e.code, 'code', 'upstream_timeout'),
        ),
      );
    },
  );
  test('chat media has one full-body deadline using its own budget', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.bufferOutput = false;
      try {
        for (int i = 0; i < 16; i++) {
          request.response.add([1]);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await request.response.close();
      } catch (_) {}
    });
    final api = ChatApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      mediaTimeout: const Duration(milliseconds: 100),
    );
    expect(api.mediaTimeout, const Duration(milliseconds: 100));
    expect(
      ChatApiClient(baseUri: api.baseUri).mediaTimeout,
      const Duration(seconds: 120),
    );
    await expectLater(
      api.fetchMedia(token: 'private', mediaId: 'private'),
      throwsA(
        isA<AuthFailure>().having((e) => e.code, 'code', 'upstream_timeout'),
      ),
    );
    expect(HttpTransport.diagnostics.last.phase, NetworkPhase.body);
  });
  for (final service in ['auth', 'chat', 'space', 'profile']) {
    test(
      '$service exposes safe socket failure diagnostics through shared transport',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final uri = Uri.parse('http://127.0.0.1:${server.port}');
        await server.close(force: true);
        final Future<Object?> Function() call = switch (service) {
          'auth' => () => AuthApiClient(
            baseUri: uri,
          ).fetchSession('private-token'),
          'chat' => () => ChatApiClient(
            baseUri: uri,
          ).listUsers(token: 'private-token'),
          'space' => () => SpaceApiClient(
            baseUri: uri,
          ).call('overview', {}, token: 'private-token'),
          _ => () => ProfileApiClient(
            baseUri: uri,
          ).fetchProfile(token: 'private-token', account: 'private-account'),
        };
        final before = HttpTransport.diagnostics.length;
        await expectLater(
          call(),
          throwsA(
            isA<AuthFailure>()
                .having((e) => e.code, 'code', 'upstream_unavailable')
                .having(
                  (e) => e.message,
                  'safe message',
                  isNot(contains('private')),
                ),
          ),
        );
        expect(HttpTransport.diagnostics.length, before + 1);
        final diagnostic = HttpTransport.diagnostics.last;
        expect(diagnostic.service, service);
        expect(diagnostic.kind, NetworkErrorKind.socket);
        expect(diagnostic.phase, NetworkPhase.opening);
        expect(diagnostic.errorType, contains('SocketException'));
      },
    );
  }
  test(
    'auth deadline bounds a continuously arriving body, not just idle time',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      int requests = 0;
      server.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType.json;
        try {
          for (int i = 0; i < 12; i++) {
            request.response.write(' ');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          request.response.write(
            '{"account":"a","username":"a","token":"secret"}',
          );
          await request.response.close();
        } catch (_) {
          /* Client aborted the response. */
        }
      });
      final api = AuthApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        api.login(account: 'a', password: 'secret'),
        throwsA(
          isA<AuthFailure>().having((e) => e.code, 'code', 'upstream_timeout'),
        ),
      );
      expect(requests, 1, reason: 'writes must never be automatically retried');
    },
  );

  for (final explicitCancel in <bool>[false, true]) {
    test(
      '${explicitCancel ? 'cancel' : 'deadline'} of a blocked upload actually closes the socket',
      () async {
        final ServerSocket server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final Completer<StreamSubscription<List<int>>> accepted =
            Completer<StreamSubscription<List<int>>>();
        final Completer<void> closed = Completer<void>();
        final List<Socket> sockets = <Socket>[];
        int received = 0;
        server.listen((Socket socket) {
          sockets.add(socket);
          final StreamSubscription<List<int>> subscription = socket.listen(
            (List<int> data) => received += data.length,
            onDone: () {
              if (!closed.isCompleted) closed.complete();
            },
            onError: (Object _) {
              if (!closed.isCompleted) closed.complete();
            },
          );
          // Stop reading so the 16 MiB upload blocks on the wire.
          subscription.pause();
          accepted.complete(subscription);
        });
        addTearDown(() async {
          for (final Socket socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        final HttpTransport transport = HttpTransport();
        addTearDown(() => transport.client.close(force: true));
        final RequestCancellation cancellation = RequestCancellation();
        final Future<TransportResponse> pending = transport.send(
          'POST',
          Uri.parse('http://127.0.0.1:${server.port}/upload'),
          service: 'chat',
          timeout: Duration(milliseconds: explicitCancel ? 2000 : 200),
          maxBytes: 100,
          body: Uint8List(16 * 1024 * 1024),
          cancellation: explicitCancel ? cancellation : null,
        );
        final Future<void> assertion = expectLater(
          pending,
          throwsA(
            isA<AuthFailure>().having(
              (AuthFailure f) => f.code,
              'code',
              explicitCancel ? 'upstream_unavailable' : 'upstream_timeout',
            ),
          ),
        );
        final StreamSubscription<List<int>> subscription =
            await accepted.future;
        if (explicitCancel) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          cancellation.cancel();
        }
        await assertion;
        expect(HttpTransport.diagnostics.last.phase, NetworkPhase.sending);
        subscription.resume();
        await closed.future.timeout(const Duration(seconds: 3));
        expect(
          received,
          lessThan(16 * 1024 * 1024),
          reason: 'the client must stop sending, not just return early',
        );
        expect(sockets, hasLength(1), reason: 'a write is never replayed');
      },
    );
  }
}
