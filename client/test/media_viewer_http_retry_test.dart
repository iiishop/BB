import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> png(int size) async {
  final random = Random(471);
  final pixels = Uint8List(size * size * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = random.nextInt(256);
    pixels[i + 1] = random.nextInt(256);
    pixels[i + 2] = random.nextInt(256);
    pixels[i + 3] = 255;
  }
  final ready = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    size,
    size,
    ui.PixelFormat.rgba8888,
    ready.complete,
  );
  final image = await ready.future;
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
      .asUint8List();
  image.dispose();
  return bytes;
}

class _RealHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'S471-T2 viewer retries real truncated HTTP original without displaying partial bytes',
    (tester) async {
      // Remove only flutter_test's fake HTTP client. All requests use dart:io TCP.
      await HttpOverrides.runWithHttpOverrides(() async {
        late Uint8List thumb, original;
        late HttpServer server;
        late Directory cache;
        await tester.runAsync(() async {
          thumb = await png(16);
          original = await png(256);
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          cache = await Directory.systemTemp.createTemp('sentinel-ui-http-');
        });
        expect(original.length, greaterThan(100 * 1024));
        final cut = Completer<void>();
        final partialSent = Completer<void>();
        final requestLog = <String>[];
        var originals = 0;
        Socket? partialSocket;
        final tasks = <Future<void>>[];
        Future<void> serve(HttpRequest request) async {
          requestLog.add(request.uri.toString());
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer synthetic-token',
          );
          expect(request.uri.path, '/media/image-1');
          final isThumb = request.uri.queryParameters['variant'] == 'thumb';
          final bytes = isThumb ? thumb : original;
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.contentLength = bytes.length;
          if (!isThumb && ++originals == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            partialSocket = socket;
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ${bytes.length}\r\nConnection: close\r\n\r\n',
            );
            socket.add(bytes.sublist(0, 8192));
            await socket.flush();
            partialSent.complete();
            await cut.future;
            socket.destroy();
          } else {
            request.response.add(bytes);
            await request.response.close();
          }
        }

        // Register handlers in the real async zone so socket-close futures
        // also finish during teardown, outside the fake widget clock.
        await tester.runAsync(() async {
          server.listen((request) {
            tasks.add(serve(request));
          });
        });
        final chat = ChatService(
          api: ChatApiClient(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
            mediaTimeout: const Duration(seconds: 2),
          ),
          session: AuthSession()
            ..establish(
              token: 'synthetic-token',
              user: const AuthUser(account: '10000001', username: 'alice'),
            ),
          ledger: ChatLedger.inMemory(),
          cacheRoot: cache,
          webSocketHints: false,
        );
        final item = ChatMediaItem(
          message: ChatMessage(
            id: 'm1',
            position: 1,
            senderAccount: '10000002',
            targetAccount: '10000001',
            createdAt: DateTime.utc(2026, 11, 14),
            kind: ChatMessageKind.body,
            parts: const [ImagePart('image-1')],
          ),
          kind: ChatMediaKind.image,
          mediaId: 'image-1',
          senderLabel: 'bob',
          partIndex: 0,
          byteSize: original.length,
        );
        const button = Key('media-viewer-original');
        const progress = Key('media-viewer-original-progress');
        Future<void> until(bool Function() predicate) async {
          for (var i = 0; i < 150; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump();
            if (predicate()) return;
          }
          fail('UI did not reach expected state within 3 seconds');
        }

        void imageIs(Uint8List bytes, int size) {
          final provider =
              tester.widget<Image>(find.byType(Image)).image as MemoryImage;
          expect(provider.bytes, orderedEquals(bytes));
          final decoded = tester.widget<RawImage>(find.byType(RawImage)).image;
          expect(decoded, isNotNull);
          expect(decoded!.width, size);
          expect(decoded.height, size);
          expect(find.text('图片无法显示'), findsNothing);
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              home: MediaViewer(
                items: [item],
                initialIndex: 0,
                chat: chat,
                saveService: MediaSaveService(chat: chat),
              ),
            ),
          );
          await until(
            () =>
                find.byType(RawImage).evaluate().isNotEmpty &&
                tester.widget<RawImage>(find.byType(RawImage)).image != null,
          );
          imageIs(thumb, 16);
          expect(originals, 0);
          await tester.tap(find.byKey(button));
          await until(
            () =>
                partialSent.isCompleted &&
                find.byKey(progress).evaluate().isNotEmpty &&
                (tester
                            .widget<LinearProgressIndicator>(
                              find.byKey(progress),
                            )
                            .value ??
                        0) >
                    0,
          );
          final fraction = tester
              .widget<LinearProgressIndicator>(find.byKey(progress))
              .value!;
          expect(fraction, closeTo(8192 / original.length, 0.000001));
          expect(fraction, lessThan(1));
          imageIs(thumb, 16);
          expect(
            tester.widget<OutlinedButton>(find.byKey(button)).onPressed,
            isNull,
          );
          cut.complete();
          await until(() => find.textContaining('重试 原图').evaluate().isNotEmpty);
          expect(find.byKey(progress), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          imageIs(thumb, 16);
          expect(
            tester.widget<OutlinedButton>(find.byKey(button)).onPressed,
            isNotNull,
          );
          expect(originals, 1);
          await tester.tap(find.byKey(button));
          await until(
            () =>
                find.byKey(button).evaluate().isEmpty &&
                tester.widget<RawImage>(find.byType(RawImage)).image?.width ==
                    256,
          );
          imageIs(original, 256);
          expect(find.byKey(progress), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(requestLog, [
            '/media/image-1?variant=thumb',
            '/media/image-1',
            '/media/image-1',
          ]);
          expect(tester.takeException(), isNull);
          debugPrint(
            'T2: thumbnail=${thumb.length} original=${original.length} partial=8192; requests=$requestLog; decoded 16x16 -> retained on failure -> 256x256',
          );
        } finally {
          if (!cut.isCompleted) cut.complete();
          partialSocket?.destroy();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await chat.dispose();
            await server.close(force: true);
            await Future.wait(tasks);
            await cache.delete(recursive: true);
          });
        }
      }, _RealHttp());
    },
  );
}
