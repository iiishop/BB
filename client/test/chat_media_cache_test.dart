import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMediaApi extends ChatApiClient {
  _FakeMediaApi(Uri base) : super(baseUri: base);

  final List<String?> variants = <String?>[];
  final List<String> metadataCalls = <String>[];
  int originalCalls = 0;
  int thumbCalls = 0;
  bool failThumb = false;

  @override
  Future<MediaResponse> fetchMedia({
    required String token,
    required String mediaId,
    String? range,
    String? variant,
    void Function(int received, int? total)? onProgress,
  }) async {
    variants.add(variant);
    if (variant == 'thumb') {
      thumbCalls += 1;
      if (failThumb) {
        throw const AuthFailure(
          status: 503,
          code: 'thumbnail_unavailable',
          message: '缩略图暂不可用',
        );
      }
      final Uint8List bytes = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0x00]);
      return MediaResponse(
        status: 200,
        bytes: bytes,
        mimeType: 'image/jpeg',
        byteSize: bytes.length,
      );
    }
    originalCalls += 1;
    return MediaResponse(
      status: 200,
      bytes: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1]),
      mimeType: 'image/png',
      byteSize: 5,
    );
  }

  @override
  Future<Attachment> fetchMediaMetadata({
    required String token,
    required String mediaId,
  }) async {
    metadataCalls.add(mediaId);
    return Attachment(
      mediaId: mediaId,
      kind: AttachmentKind.image,
      filename: 'big.png',
      mimeType: 'image/png',
      byteSize: 3 * 1024 * 1024,
    );
  }
}

ChatService _chat(_FakeMediaApi api, AuthSession session) {
  return ChatService(
    api: api,
    session: session,
    ledger: ChatLedger.inMemory(),
    cacheRoot: Directory.systemTemp,
    webSocketHints: false,
  );
}

void main() {
  test(
    'media cache is isolated by server, account, media and variant',
    () async {
      final AuthSession session = AuthSession()
        ..establish(
          token: 'token-a',
          user: const AuthUser(account: '10000001', username: 'alice'),
        );
      final _FakeMediaApi api = _FakeMediaApi(Uri.parse('http://127.0.0.1:1'));
      final ChatService chat = _chat(api, session);
      addTearDown(chat.dispose);

      await chat.mediaBytes('media-1');
      await chat.mediaBytes('media-1');
      expect(api.originalCalls, 1);
      expect(api.thumbCalls, 0);

      await chat.loadThumbnail('media-1');
      await chat.loadThumbnail('media-1');
      expect(api.thumbCalls, 1);
      expect(
        api.originalCalls,
        1,
        reason: 'variant bytes use a separate cache',
      );

      await chat.loadMediaMetadata('media-1');
      await chat.loadMediaMetadata('media-1');
      expect(api.metadataCalls, <String>['media-1']);

      // Another account on the same server must not reuse A's cached bytes.
      session.establish(
        token: 'token-b',
        user: const AuthUser(account: '10000002', username: 'bob'),
      );
      await chat.mediaBytes('media-1');
      expect(api.originalCalls, 2);

      // Another server must not reuse the previous server's cache either.
      final _FakeMediaApi otherApi = _FakeMediaApi(
        Uri.parse('http://127.0.0.1:2'),
      );
      final ChatService other = _chat(otherApi, session);
      addTearDown(other.dispose);
      await other.mediaBytes('media-1');
      expect(otherApi.originalCalls, 1);
    },
  );

  test(
    'thumbnail failure never silently fetches the remote original',
    () async {
      final AuthSession session = AuthSession()
        ..establish(
          token: 'token-a',
          user: const AuthUser(account: '10000001', username: 'alice'),
        );
      final _FakeMediaApi api = _FakeMediaApi(Uri.parse('http://127.0.0.1:3'))
        ..failThumb = true;
      final ChatService chat = _chat(api, session);
      addTearDown(chat.dispose);

      await expectLater(
        chat.loadListPreview('media-big'),
        throwsA(isA<AuthFailure>()),
      );
      expect(api.thumbCalls, 1);
      expect(
        api.originalCalls,
        0,
        reason: 'a failed thumbnail must not fall back to the remote original',
      );
    },
  );
}
