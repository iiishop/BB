import 'dart:async';

import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:bb_client/ui/chat/media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

ChatMediaItem _item({
  required int position,
  required String mediaId,
  int? byteSize,
  bool video = false,
  String? coverMediaId,
  String? filename,
  String? mimeType,
  String sender = _peer,
}) {
  final ChatMessage message = ChatMessage(
    id: 'm$position',
    position: position,
    senderAccount: sender,
    targetAccount: sender == _self.account ? _peer : _self.account,
    createdAt: DateTime.utc(2026, 11, 14, 10, position),
    kind: video ? ChatMessageKind.attachment : ChatMessageKind.body,
    parts: video ? const <MessagePart>[] : <MessagePart>[ImagePart(mediaId)],
    attachment: video
        ? Attachment(
            mediaId: mediaId,
            kind: AttachmentKind.video,
            filename: filename ?? 'clip.mp4',
            mimeType: mimeType ?? 'video/mp4',
            byteSize: byteSize ?? 4096,
            coverMediaId: coverMediaId ?? 'cover-$position',
          )
        : null,
  );
  return ChatMediaItem(
    message: message,
    kind: video ? ChatMediaKind.video : ChatMediaKind.image,
    mediaId: mediaId,
    senderLabel: sender == _self.account ? '我' : 'bob',
    partIndex: video ? null : 0,
    coverMediaId: video ? (coverMediaId ?? 'cover-$position') : null,
    byteSize: byteSize,
    filename: filename,
    mimeType: mimeType,
  );
}

class _FakeStager {
  final List<String> staged = <String>[];
  final List<String> cleaned = <String>[];

  Future<GalleryStagedFile> stage(Uint8List bytes, String filename) async {
    staged.add(filename);
    return GalleryStagedFile(
      path: '/tmp/bb-staged-$filename',
      cleanup: () async => cleaned.add(filename),
    );
  }
}

class _FakeGallery implements GallerySaver {
  bool supported = true;
  PlatformException? error;
  final List<String> saves = <String>[];
  String location = 'Pictures/BB/bb_20261114_100000_probe.jpg';

  @override
  bool get isSupported => supported;

  @override
  Future<GallerySaveOutcome> save({
    required String path,
    required String filename,
    required String mimeType,
    required bool isVideo,
  }) async {
    saves.add(filename);
    if (error != null) {
      throw error!;
    }
    return GallerySaveOutcome(location: location);
  }
}

Widget _viewerApp({
  required FakeChatService chat,
  required MediaSaveService saveService,
  required List<ChatMediaItem> items,
  int initialIndex = 0,
  bool sequenceComplete = true,
  MediaViewerReload? onReload,
  Future<void> Function(ChatMediaItem item)? onPlayVideo,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: MediaViewer(
      items: items,
      initialIndex: initialIndex,
      chat: chat,
      saveService: saveService,
      sequenceComplete: sequenceComplete,
      onReload: onReload,
      onPlayVideo: onPlayVideo,
    ),
  );
}

void main() {
  late FakeChatService chat;
  late _FakeGallery gallery;
  late _FakeStager stager;
  late MediaSaveService saveService;

  setUp(() {
    chat = FakeChatService(self: _self, users: const <ChatUser>[]);
    gallery = _FakeGallery();
    stager = _FakeStager();
    saveService = MediaSaveService(
      chat: chat,
      gallery: gallery,
      pickSaveLocation: (String _) async => null,
      stageGalleryFile: stager.stage,
    );
  });

  testWidgets('opens at the tapped item and swipes across the sequence', (
    WidgetTester tester,
  ) async {
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(position: 1, mediaId: 'img-1'),
      _item(position: 2, mediaId: 'img-2'),
      _item(position: 3, mediaId: 'img-3'),
    ];
    await tester.pumpWidget(
      _viewerApp(
        chat: chat,
        saveService: saveService,
        items: items,
        initialIndex: 1,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('第 2 / 共 3'), findsOneWidget);
    expect(find.textContaining('bob ·'), findsOneWidget);
    expect(find.byKey(MediaViewer.saveKey), findsOneWidget);

    await tester.drag(
      find.byKey(MediaViewer.pageViewKey),
      const Offset(420, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 共 3'), findsOneWidget);

    await tester.drag(
      find.byKey(MediaViewer.pageViewKey),
      const Offset(-420, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 共 3'), findsOneWidget);
  });

  testWidgets(
    'large derivative image offers size, progress and then original',
    (WidgetTester tester) async {
      chat.originalGate = Completer<void>();
      final List<ChatMediaItem> items = <ChatMediaItem>[
        _item(position: 1, mediaId: 'img-large', byteSize: 3 * 1024 * 1024),
      ];
      await tester.pumpWidget(
        _viewerApp(chat: chat, saveService: saveService, items: items),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(chat.previewCalls, <String>['img-large']);
      expect(chat.originalCalls, isEmpty);
      expect(find.text('原图 3.0 MB'), findsOneWidget);

      await tester.tap(find.byKey(const Key('media-viewer-original')));
      await tester.pump();
      expect(chat.originalCalls, <String>['img-large']);
      expect(find.textContaining('原图下载中'), findsOneWidget);
      expect(
        find.byKey(const Key('media-viewer-original-progress')),
        findsOneWidget,
      );

      chat.originalGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-viewer-original')), findsNothing);
      expect(chat.originalProgress, isNotEmpty);
    },
  );

  testWidgets('small image never shows the original action', (
    WidgetTester tester,
  ) async {
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(position: 1, mediaId: 'img-small', byteSize: 40 * 1024),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media-viewer-original')), findsNothing);
    expect(chat.originalCalls, isEmpty);
    expect(find.byKey(MediaViewer.saveKey), findsOneWidget);
  });

  testWidgets('failed original download returns to a retry button', (
    WidgetTester tester,
  ) async {
    chat.originalFailure = StateError('network down');
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(position: 1, mediaId: 'img-large', byteSize: 3 * 1024 * 1024),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('media-viewer-original')));
    await tester.pumpAndSettle();
    expect(find.text('重试 原图 3.0 MB'), findsOneWidget);
    expect(
      find.byKey(const Key('media-viewer-original-progress')),
      findsNothing,
    );

    chat.originalFailure = null;
    await tester.tap(find.byKey(const Key('media-viewer-original')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-viewer-original')), findsNothing);
    expect(chat.originalCalls.length, 2);
  });

  testWidgets('a late original result does not replace the page now shown', (
    WidgetTester tester,
  ) async {
    chat.originalGate = Completer<void>();
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(position: 1, mediaId: 'img-1a', byteSize: 3 * 1024 * 1024),
      _item(position: 2, mediaId: 'img-2b', byteSize: 3 * 1024 * 1024),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('media-viewer-original')));
    await tester.pump();
    await tester.drag(
      find.byKey(MediaViewer.pageViewKey),
      const Offset(-420, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 共 2'), findsOneWidget);

    chat.originalGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('第 2 / 共 2'), findsOneWidget);
    expect(find.byKey(const Key('media-viewer-original')), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save reports the gallery location on Android', (
    WidgetTester tester,
  ) async {
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(
        position: 1,
        mediaId: 'img-save',
        byteSize: 3 * 1024 * 1024,
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
      ),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MediaViewer.saveKey));
    await tester.pumpAndSettle();
    expect(gallery.saves, <String>['photo.jpg']);
    expect(stager.staged, <String>['photo.jpg']);
    expect(stager.cleaned, <String>['photo.jpg']);
    expect(
      find.text('已保存到相册 Pictures/BB/bb_20261114_100000_probe.jpg'),
      findsOneWidget,
    );
    expect(chat.originalCalls, <String>['img-save']);
  });

  testWidgets('gallery permission denial is reported without crashing', (
    WidgetTester tester,
  ) async {
    gallery.error = PlatformException(
      code: 'permission_denied',
      message: 'denied',
    );
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(
        position: 1,
        mediaId: 'img-save',
        byteSize: 3 * 1024 * 1024,
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
      ),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MediaViewer.saveKey));
    await tester.pumpAndSettle();
    expect(find.text('保存失败：没有相册写入权限'), findsOneWidget);
  });

  testWidgets('desktop save uses the chosen path and reports it', (
    WidgetTester tester,
  ) async {
    gallery.supported = false;
    String? picked;
    saveService = MediaSaveService(
      chat: chat,
      gallery: gallery,
      pickSaveLocation: (String suggested) async {
        picked = suggested;
        return '/tmp/bb-out.jpg';
      },
      stageGalleryFile: stager.stage,
    );
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(
        position: 1,
        mediaId: 'img-save',
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
      ),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MediaViewer.saveKey));
    await tester.pumpAndSettle();
    expect(picked, 'photo.jpg');
    expect(chat.savedPaths, <String>['/tmp/bb-out.jpg']);
    expect(find.text('已保存到 /tmp/bb-out.jpg'), findsOneWidget);
  });

  testWidgets('cancelled save dialog stays silent', (
    WidgetTester tester,
  ) async {
    gallery.supported = false;
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(
        position: 1,
        mediaId: 'img-save',
        filename: 'photo.jpg',
        mimeType: 'image/jpeg',
      ),
    ];
    await tester.pumpWidget(
      _viewerApp(chat: chat, saveService: saveService, items: items),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(MediaViewer.saveKey));
    await tester.pumpAndSettle();
    expect(chat.savedPaths, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('partial history shows a boundary and reloads on request', (
    WidgetTester tester,
  ) async {
    final ChatMediaItem first = _item(position: 1, mediaId: 'img-1');
    final ChatMediaItem second = _item(position: 2, mediaId: 'img-2');
    var complete = false;
    await tester.pumpWidget(
      _viewerApp(
        chat: chat,
        saveService: saveService,
        items: <ChatMediaItem>[first],
        sequenceComplete: complete,
        onReload: () async {
          complete = true;
          return (items: <ChatMediaItem>[first, second], complete: true);
        },
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(MediaViewer.boundaryKey), findsOneWidget);

    await tester.tap(find.byKey(MediaViewer.reloadKey));
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 共 2'), findsOneWidget);
    expect(find.byKey(MediaViewer.boundaryKey), findsNothing);
  });

  testWidgets('swipe down closes the viewer', (WidgetTester tester) async {
    final List<ChatMediaItem> items = <ChatMediaItem>[
      _item(position: 1, mediaId: 'img-1'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => MediaViewer(
                      items: items,
                      initialIndex: 0,
                      chat: chat,
                      saveService: saveService,
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byKey(MediaViewer.closeKey), findsOneWidget);

    await tester.drag(
      find.byKey(MediaViewer.pageViewKey),
      const Offset(0, 220),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(MediaViewer.closeKey), findsNothing);
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets(
    'video cover opens the viewer and play reuses the stream action',
    (WidgetTester tester) async {
      final List<ChatMediaItem> items = <ChatMediaItem>[
        _item(position: 1, mediaId: 'img-1'),
        _item(
          position: 2,
          mediaId: 'video-2',
          video: true,
          coverMediaId: 'cover-2',
        ),
      ];
      ChatMediaItem? played;
      await tester.pumpWidget(
        _viewerApp(
          chat: chat,
          saveService: saveService,
          items: items,
          initialIndex: 1,
          onPlayVideo: (ChatMediaItem item) async {
            played = item;
          },
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 共 2'), findsOneWidget);
      expect(chat.mediaBytesCalls, contains('cover-2'));
      expect(chat.mediaBytesCalls, isNot(contains('video-2')));

      await tester.tap(
        find.byKey(const ValueKey<String>('media-viewer-play-video-2')),
      );
      await tester.pump();
      expect(played?.mediaId, 'video-2');
    },
  );
}
