import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/http_transport.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression for DEA-487 items 1 and 2.
///
/// Both cases previously escaped as raw `dart:io` exceptions or returned a
/// business failure without any queryable safe diagnostic.
void main() {
  for (final probe in <bool>[false, true]) {
    test(
      '${probe ? 'probe' : 'fetch'} media with a malformed Content-Type stays a typed failure with one safe diagnostic',
      () async {
        final HttpServer server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => server.close(force: true));
        server.listen((HttpRequest request) async {
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/octet-stream; name="unterminated',
          );
          request.response.add(<int>[1]);
          await request.response.close();
        });
        final ChatApiClient api = ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final int before = HttpTransport.diagnostics.length;
        Object? caught;
        try {
          if (probe) {
            await api.probeMedia(token: 'synthetic', mediaId: 'synthetic');
          } else {
            await api.fetchMedia(token: 'synthetic', mediaId: 'synthetic');
          }
        } catch (error) {
          caught = error;
        }
        expect(
          caught,
          isA<AuthFailure>()
              .having((AuthFailure f) => f.code, 'code', 'upstream_unavailable')
              .having(
                (AuthFailure f) => f.message,
                'safe message',
                isNot(contains('parse header value')),
              ),
          reason:
              'a malformed network header must not escape as a raw exception',
        );
        expect(HttpTransport.diagnostics.length, before + 1);
        final NetworkDiagnostic diagnostic = HttpTransport.diagnostics.last;
        expect(diagnostic.service, 'chat');
        expect(diagnostic.phase, NetworkPhase.headers);
        expect(diagnostic.kind, NetworkErrorKind.http);
        expect(diagnostic.errorType, contains('Exception'));
        expect(diagnostic.status, 200);
      },
    );
  }

  test(
    'a rejected 302 leaves one queryable diagnostic and is never followed',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      int requests = 0;
      server.listen((HttpRequest request) async {
        requests++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/redirected');
        await request.response.close();
      });
      final AuthApiClient api = AuthApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final int before = HttpTransport.diagnostics.length;
      await expectLater(
        api.fetchSession('synthetic'),
        throwsA(isA<AuthFailure>()),
      );
      expect(requests, 1, reason: 'credentials must not follow a redirect');
      expect(HttpTransport.diagnostics.length, before + 1);
      final NetworkDiagnostic diagnostic = HttpTransport.diagnostics.last;
      expect(diagnostic.service, 'auth');
      expect(diagnostic.kind, NetworkErrorKind.response);
      expect(diagnostic.errorType, 'HttpStatus');
      expect(diagnostic.status, HttpStatus.found);
    },
  );

  test(
    'the legitimate profile 304 is not recorded as a rejected response',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.notModified;
        request.response.headers.set(HttpHeaders.etagHeader, '"avatar-v1"');
        await request.response.close();
      });
      final ProfileApiClient api = ProfileApiClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        timeout: const Duration(seconds: 2),
      );
      final int before = HttpTransport.diagnostics.length;
      final AvatarFetch fetch = await api.fetchAvatar(
        token: 'synthetic',
        account: 'synthetic',
        ifNoneMatch: 'avatar-v1',
      );
      expect(fetch.notModified, isTrue);
      expect(HttpTransport.diagnostics.length, before);
    },
  );

  test('a media response with a valid Content-Type keeps working', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'image/png; charset=binary',
      );
      request.response.add(<int>[1, 2, 3]);
      await request.response.close();
    });
    final ChatApiClient api = ChatApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    final int before = HttpTransport.diagnostics.length;
    final MediaResponse response = await api.fetchMedia(
      token: 'synthetic',
      mediaId: 'synthetic',
    );
    expect(response.mimeType, 'image/png');
    expect(response.bytes, <int>[1, 2, 3]);
    expect(HttpTransport.diagnostics.length, before);
  });
}
