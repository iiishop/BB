import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/media_stream_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

void main() {
  test(
    'playback stream is opened on demand and forwards Range to the server',
    () async {
      final FakeChatBackend backend = await FakeChatBackend.start(
        users: <String, String>{'10000001': 'alice', '10000002': 'bob'},
      );
      final Uint8List video = Uint8List.fromList(
        utf8.encode('0123456789abcdef'),
      );
      final String mediaId = await backend.addMedia(
        owner: '10000002',
        peer: '10000001',
        bytes: video,
        mime: 'video/mp4',
        kind: 'video',
        filename: 'clip.mp4',
        coverId: 'cover-1',
      );
      final AuthSession session = AuthSession()
        ..establish(
          token: backend.tokenFor('10000001'),
          user: const AuthUser(account: '10000001', username: 'alice'),
        );
      final ChatService chat = ChatService(
        api: ChatApiClient(baseUri: backend.baseUri),
        session: session,
        ledger: ChatLedger.inMemory(),
        cacheRoot: Directory.systemTemp,
        webSocketHints: false,
      );
      addTearDown(chat.dispose);
      addTearDown(backend.close);

      expect(backend.lastMediaRange, isNull, reason: 'no prefetch on arrival');
      final MediaStreamHandle handle = await chat.openMediaStream(mediaId);
      expect(handle.uri.host, '127.0.0.1');
      expect(handle.uri.path, startsWith('/stream/'));

      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest request = await client.getUrl(handle.uri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-3');
        final HttpClientResponse response = await request.close();
        final Uint8List body = await response
            .fold<List<int>>(<int>[], (List<int> acc, List<int> chunk) {
              acc.addAll(chunk);
              return acc;
            })
            .then(Uint8List.fromList);
        expect(response.statusCode, 206);
        expect(body, video.sublist(0, 4));
        expect(backend.lastMediaRange, 'bytes=0-3');
      } finally {
        client.close(force: true);
        await handle.close();
      }
    },
  );
}
