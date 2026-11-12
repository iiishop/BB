import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/media_source.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/media_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');

class _FakeClipboard implements ClipboardMediaReader {
  _FakeClipboard(this.media);

  final PickedMedia? media;
  int calls = 0;

  @override
  Future<PickedMedia?> read() async {
    calls += 1;
    return media;
  }
}

void main() {
  late Directory root;
  late Uint8List videoBytes;
  late String videoPath;
  late ResolvedMedia realCover;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('bb-media-input-');
    videoPath = '${root.path}/clip.mp4';
    final ProcessResult result = await Process.run('ffmpeg', <String>[
      '-y',
      '-f',
      'lavfi',
      '-i',
      'color=c=orange:s=64x64:d=1',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      videoPath,
    ]);
    expect(result.exitCode, 0, reason: 'ffmpeg fixture: ${result.stderr}');
    videoBytes = await File(videoPath).readAsBytes();
    final ResolvedMedia? cover = await MediaActions.extractVideoCover(
      path: videoPath,
      bytes: videoBytes,
      filename: 'clip.mp4',
    );
    expect(cover, isNotNull);
    realCover = cover!;
  });

  tearDownAll(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'video cover accepts a real path and a bytes-only clipboard source',
    () async {
      final ResolvedMedia? fromPath = await MediaActions.extractVideoCover(
        path: videoPath,
        bytes: videoBytes,
        filename: 'clip.mp4',
      );
      expect(fromPath, isNotNull);
      expect(fromPath!.mimeType, 'image/png');
      expect(fromPath.bytes, isNotEmpty);

      final ResolvedMedia? fromBytes = await MediaActions.extractVideoCover(
        bytes: videoBytes,
        filename: 'clip.mp4',
      );
      expect(
        fromBytes,
        isNotNull,
        reason: 'bytes-only paste stages a temp file',
      );
      expect(fromBytes!.mimeType, 'image/png');
      expect(fromBytes.bytes, isNotEmpty);
    },
  );

  test('clipboard URI parser accepts local files only', () {
    expect(parseClipboardMediaUri('file:///tmp/a.png')?.scheme, 'file');
    expect(parseClipboardMediaUri('/tmp/a.mp4')?.path, '/tmp/a.mp4');
    expect(parseClipboardMediaUri('https://example.com/a.mp4'), isNull);
    expect(parseClipboardMediaUri('not a uri'), isNull);
  });

  testWidgets('pasted image enters the ordered body draft', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[],
    );
    final _FakeClipboard clipboard = _FakeClipboard(
      PickedMedia(
        bytes: base64Png,
        filename: 'paste.png',
        mimeType: 'image/png',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            chat: chat,
            peerAccount: '10000002',
            clipboard: clipboard,
            onSent: (List<ChatMessage> _) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(ChatComposer.pasteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pumpAndSettle();
    expect(clipboard.calls, 1);
    expect(chat.lastSentBody, hasLength(1));
    expect(chat.lastSentBody.single, isA<OutgoingImage>());
    expect(chat.lastSentAttachments, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('pasted video enters the attachment draft with a real cover', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = FakeChatService(
      self: _self,
      users: const <ChatUser>[],
    );
    String? seenPath;
    final _FakeClipboard clipboard = _FakeClipboard(
      PickedMedia(
        bytes: videoBytes,
        filename: 'clip.mp4',
        mimeType: 'video/mp4',
        path: videoPath,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            chat: chat,
            peerAccount: '10000002',
            clipboard: clipboard,
            coverExtractor:
                ({
                  String? path,
                  required Uint8List bytes,
                  required String filename,
                }) async {
                  seenPath = path;
                  return realCover;
                },
            onSent: (List<ChatMessage> _) {},
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(ChatComposer.inputKey), '混排正文');
    await tester.tap(find.byKey(ChatComposer.pasteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChatComposer.sendKey));
    await tester.pumpAndSettle();
    expect(clipboard.calls, 1);
    expect(chat.lastSentBody, hasLength(1));
    expect(chat.lastSentAttachments, hasLength(1));
    final OutgoingAttachment attachment = chat.lastSentAttachments.single;
    expect(seenPath, videoPath);
    expect(attachment.source.mimeType, 'video/mp4');
    expect(attachment.cover, isNotNull, reason: 'real cover was extracted');
    expect(attachment.cover!.mimeType, 'image/png');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

final Uint8List base64Png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x02,
  0x00,
  0x00,
  0x00,
  0x02,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x72,
  0xB6,
  0x0D,
  0x24,
  0x00,
  0x00,
  0x00,
  0x14,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xFC,
  0xCF,
  0xC0,
  0xF0,
  0x9F,
  0x81,
  0x81,
  0x81,
  0x81,
  0x09,
  0x00,
  0x0A,
  0x00,
  0x1F,
  0x17,
  0x02,
  0x02,
  0x4F,
  0x94,
  0xCE,
  0xBE,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);
