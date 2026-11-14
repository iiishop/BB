import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real FastAPI chain for the DEA-471 media contract.
///
/// Opt-in: start a server with the DEA-471 contract (Forge branch), then run
/// `BB_LIVE_SERVER_URL=http://127.0.0.1:8171 flutter test test/live_media_contract_test.dart`.
/// Without the environment variable the group is SKIPPED, never PASS.
void main() {
  final String? configured = Platform.environment['BB_LIVE_SERVER_URL'];
  final String? rawBase = (configured != null && configured.trim().isNotEmpty)
      ? configured.trim()
      : null;

  group(
    'live media contract',
    skip: rawBase == null
        ? 'BB_LIVE_SERVER_URL 未设置：未执行真实 DEA-471 媒体链路（SKIP，不算 PASS）'
        : null,
    () {
      final Uri baseUri = Uri.parse(rawBase ?? 'http://127.0.0.1:8171');
      late Directory root;
      late AuthService authA;
      late AuthService authB;
      late AuthService authC;
      late ChatService chatA;
      late ChatService chatB;
      late ChatService chatC;
      late AuthUser userB;

      Future<AuthUser> createAccount(AuthService service, String label) async {
        final String username =
            '${label}_${DateTime.now().microsecondsSinceEpoch % 100000000}';
        final AuthUser registered = await service.register(
          username: username,
          password: 'Secret42',
        );
        await service.login(account: registered.account, password: 'Secret42');
        return registered;
      }

      AuthService newAuth(String label) {
        return AuthService(
          api: AuthApiClient(baseUri: baseUri),
          session: AuthSession(),
          store: SessionStore.atPath('${root.path}/session-$label.json'),
        );
      }

      ChatService newChat(AuthService auth, String label) {
        return ChatService(
          api: ChatApiClient(baseUri: baseUri),
          session: auth.session,
          ledger: ChatLedger.atPath('${root.path}/ledger-$label.json'),
          cacheRoot: Directory('${root.path}/cache-$label'),
          webSocketHints: false,
        );
      }

      setUpAll(() async {
        root = await Directory.systemTemp.createTemp('bb-live-media-');
        authA = newAuth('a');
        authB = newAuth('b');
        authC = newAuth('c');
        await createAccount(authA, 'media_a');
        userB = await createAccount(authB, 'media_b');
        await createAccount(authC, 'media_c');
        chatA = newChat(authA, 'a');
        chatB = newChat(authB, 'b');
        chatC = newChat(authC, 'c');
      });

      tearDownAll(() async {
        await chatA.dispose();
        await chatB.dispose();
        await chatC.dispose();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      test(
        'metadata, bounded thumbnail, original bytes and isolation',
        () async {
          final Uint8List large = _largePng(320, 320);
          expect(large.length, greaterThan(100 * 1024));
          final Attachment uploaded = await chatA.api.uploadMedia(
            token: authA.session.identity!.token,
            targetAccount: userB.account,
            bytes: large,
            filename: 'large.png',
            mimeType: 'image/png',
          );
          expect(uploaded.byteSize, large.length);

          final Attachment metadata = await chatB.loadMediaMetadata(
            uploaded.mediaId,
          );
          expect(metadata.byteSize, large.length);
          expect(metadata.mimeType, 'image/png');
          expect(metadata.filename, 'large.png');

          final Uint8List thumb = await chatB.loadThumbnail(uploaded.mediaId);
          expect(thumb.length, lessThanOrEqualTo(64 * 1024));
          expect(
            thumb.length >= 3 &&
                thumb[0] == 0xFF &&
                thumb[1] == 0xD8 &&
                thumb[2] == 0xFF,
            isTrue,
            reason: 'thumbnail must be JPEG',
          );

          // The list picks the thumbnail for a >100 KiB image...
          final Uint8List listPreview = await chatB.loadListPreview(
            uploaded.mediaId,
          );
          expect(listPreview.length, thumb.length);
          // ...and the viewer marks it as a derivative, not the original.
          final preview = await chatB.loadMediaPreview(
            uploaded.mediaId,
            thumbnail: true,
          );
          expect(preview.isDerivative, isTrue);

          final original = await chatB.fetchOriginalMedia(uploaded.mediaId);
          expect(original.bytes, large);
          expect(original.mimeType, 'image/png');

          // Range stays available for the original endpoint.
          final ranged = await ChatApiClient(baseUri: baseUri).fetchMedia(
            token: authB.session.identity!.token,
            mediaId: uploaded.mediaId,
            range: 'bytes=0-0',
          );
          expect(ranged.status, 206);
          expect(ranged.bytes.length, 1);
          expect(ranged.byteSize, large.length);

          // A small image uses the original directly in the list.
          final Uint8List small = base64Decode(_smallPngBase64);
          final Attachment smallUpload = await chatA.api.uploadMedia(
            token: authA.session.identity!.token,
            targetAccount: userB.account,
            bytes: small,
            filename: 'small.png',
            mimeType: 'image/png',
          );
          expect(smallUpload.byteSize, small.length);
          final Uint8List smallPreview = await chatB.loadListPreview(
            smallUpload.mediaId,
          );
          expect(smallPreview, small);

          // A third account cannot read the pair's media metadata or bytes.
          await expectLater(
            chatC.loadMediaMetadata(uploaded.mediaId),
            throwsA(
              isA<AuthFailure>().having(
                (AuthFailure failure) => failure.status,
                'status',
                404,
              ),
            ),
          );
          await expectLater(
            chatC.loadThumbnail(uploaded.mediaId),
            throwsA(
              isA<AuthFailure>().having(
                (AuthFailure failure) => failure.status,
                'status',
                404,
              ),
            ),
          );
        },
      );
    },
  );
}

const String _smallPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=';

/// Deterministic noisy PNG: valid RGB pixels and >100 KiB after deflate.
Uint8List _largePng(int width, int height) {
  final Random random = Random(471);
  final BytesBuilder raw = BytesBuilder();
  for (int y = 0; y < height; y += 1) {
    raw.addByte(0);
    final Uint8List row = Uint8List(width * 3);
    for (int i = 0; i < row.length; i += 1) {
      row[i] = random.nextInt(256);
    }
    raw.add(row);
  }
  final List<int> compressed = ZLibCodec(level: 6).encode(raw.takeBytes());
  final List<int> header = <int>[
    ..._be32(width),
    ..._be32(height),
    8, // bit depth
    2, // truecolour
    0,
    0,
    0,
  ];
  final BytesBuilder out = BytesBuilder();
  out.add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _writeChunk(out, 'IHDR', header);
  _writeChunk(out, 'IDAT', compressed);
  _writeChunk(out, 'IEND', const <int>[]);
  return out.takeBytes();
}

void _writeChunk(BytesBuilder out, String type, List<int> data) {
  final List<int> typeBytes = ascii.encode(type);
  out.add(_be32(data.length));
  out.add(typeBytes);
  out.add(data);
  out.add(_be32(_crc32(<int>[...typeBytes, ...data])));
}

List<int> _be32(int value) {
  return <int>[
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
}

int _crc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final int byte in data) {
    crc ^= byte;
    for (int bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
