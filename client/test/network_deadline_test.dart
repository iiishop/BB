import 'dart:io';

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
}
