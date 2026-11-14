import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_media.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/media_save.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

ChatMediaItem _inlineImage(String mediaId) {
  final ChatMessage message = ChatMessage(
    id: 'm1',
    position: 1,
    senderAccount: _peer,
    targetAccount: _self.account,
    createdAt: DateTime.utc(2026, 11, 14, 10),
    kind: ChatMessageKind.body,
    parts: <MessagePart>[ImagePart(mediaId)],
  );
  return ChatMediaItem(
    message: message,
    kind: ChatMediaKind.image,
    mediaId: mediaId,
    senderLabel: 'bob',
    partIndex: 0,
  );
}

class _Gallery implements GallerySaver {
  _Gallery({this.supported = true});

  final bool supported;
  final List<String> names = <String>[];

  @override
  bool get isSupported => supported;

  @override
  Future<GallerySaveOutcome> save({
    required String path,
    required String filename,
    required String mimeType,
    required bool isVideo,
  }) async {
    names.add(filename);
    return GallerySaveOutcome(location: 'Pictures/BB/$filename');
  }
}

class _Stager {
  final List<String> names = <String>[];
  final List<String> cleaned = <String>[];

  Future<GalleryStagedFile> stage(Uint8List bytes, String filename) async {
    names.add(filename);
    return GalleryStagedFile(
      path: '/tmp/$filename',
      cleanup: () async => cleaned.add(filename),
    );
  }
}

void main() {
  late FakeChatService chat;
  late _Gallery gallery;
  late _Stager stager;

  setUp(() {
    chat = FakeChatService(self: _self, users: const <ChatUser>[]);
    chat.metadata = const Attachment(
      mediaId: 'metadata',
      kind: AttachmentKind.image,
      filename: 'inline.png',
      mimeType: 'image/png',
      byteSize: 40 * 1024,
    );
    gallery = _Gallery();
    stager = _Stager();
  });

  test('gallery save resolves a body image filename from metadata', () async {
    final MediaSaveService service = MediaSaveService(
      chat: chat,
      gallery: gallery,
      stageGalleryFile: stager.stage,
      pickSaveLocation: (String _) async => null,
    );

    final MediaSaveResult result = await service.save(_inlineImage('img-1'));

    expect(result.status, MediaSaveStatus.saved);
    expect(result.message, '已保存到相册 Pictures/BB/inline.png');
    expect(chat.metadataCalls, <String>['img-1']);
    expect(chat.originalCalls, <String>['img-1']);
    expect(gallery.names, <String>['inline.png']);
    expect(stager.names, <String>['inline.png']);
    expect(stager.cleaned, <String>['inline.png']);
  });

  test(
    'desktop save suggests the metadata filename and reports the path',
    () async {
      gallery = _Gallery(supported: false);
      String? suggested;
      final MediaSaveService service = MediaSaveService(
        chat: chat,
        gallery: gallery,
        pickSaveLocation: (String name) async {
          suggested = name;
          return '/tmp/out.png';
        },
      );

      final MediaSaveResult result = await service.save(_inlineImage('img-1'));

      expect(result.status, MediaSaveStatus.saved);
      expect(suggested, 'inline.png');
      expect(chat.savedPaths, <String>['/tmp/out.png']);
      expect(chat.originalCalls, isEmpty);
    },
  );
}
