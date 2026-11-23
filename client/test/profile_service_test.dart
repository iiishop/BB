import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_backend.dart';

final Uint8List _png1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
final Uint8List _png2 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  late FakeAuthBackend backend;
  late Directory directory;
  late SessionStore store;
  late AuthSession session;
  late AuthService auth;
  late ProfileService service;

  setUp(() async {
    backend = await FakeAuthBackend.start();
    directory = await Directory.systemTemp.createTemp('bb-profile-service-');
    store = SessionStore.atPath('${directory.path}/session.json');
    session = AuthSession();
    auth = AuthService(
      api: AuthApiClient(baseUri: backend.baseUri),
      session: session,
      store: store,
    );
    service = ProfileService(
      api: ProfileApiClient(baseUri: backend.baseUri),
      auth: auth,
      cache: AvatarCache(),
    );
    await auth.login(
      account: backend.validAccount,
      password: backend.validPassword,
    );
  });

  tearDown(() async {
    await backend.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('loadProfile returns the server profile and current version', () async {
    backend.signature = '签名';
    final Profile profile = await service.loadProfile();
    expect(profile.account, backend.validAccount);
    expect(profile.username, backend.username);
    expect(profile.signature, '签名');
    expect(profile.avatarVersion, backend.avatarVersion);
  });

  test(
    'loadAvatar revalidates: first 200, then 304 with cached bytes',
    () async {
      final AvatarImage first = await service.loadAvatar();
      expect(first.bytes, _png1);
      expect(backend.avatarIfNoneMatch.first, isNull);

      final AvatarImage second = await service.loadAvatar();
      expect(second.bytes, _png1);
      expect(backend.avatarIfNoneMatch, hasLength(2));
      expect(backend.avatarIfNoneMatch[1], '"${first.version}"');
    },
  );

  test('a changed server avatar replaces the cached bytes', () async {
    final AvatarImage first = await service.loadAvatar();
    backend.replaceAvatar(_png2);
    final AvatarImage second = await service.loadAvatar();
    expect(second.bytes, _png2);
    expect(second.version, isNot(first.version));
  });

  test('updateAvatarFromBase64 uploads and invalidates the cache', () async {
    await service.loadAvatar();
    final AvatarInfo info = await service.updateAvatarFromBase64(
      'data:image/png;base64,${base64Encode(_png2)}',
    );
    expect(info.avatarVersion, isNot('identicon-v1-fake'));
    expect(backend.requests.last.keys, contains('file'));

    final AvatarImage after = await service.loadAvatar();
    expect(after.bytes, _png2);
  });

  test('updateAvatarFromPath reads the file and uploads it', () async {
    final File file = File('${directory.path}/a.png');
    await file.writeAsBytes(_png2);
    final AvatarInfo info = await service.updateAvatarFromPath(file.path);
    expect(info.avatarVersion, isNotEmpty);
    expect((await service.loadAvatar()).bytes, _png2);
  });

  test('updateNickname trims, persists the session name and store', () async {
    final String name = await service.updateNickname('  Alice  ');
    expect(name, 'Alice');
    expect(session.user?.username, 'Alice');
    expect((await store.read())?.username, 'Alice');
  });

  test('updateSignature clears with null and reads back null', () async {
    await service.updateSignature('Hello');
    expect(await service.viewSignature(), 'Hello');
    expect(await service.updateSignature(null), isNull);
    expect(await service.viewSignature(), isNull);
  });

  test('viewNickname of an unknown account maps 404', () async {
    final AuthFailure failure = await _captureFailure(
      () => service.viewNickname(account: '12340000'),
    );
    expect(failure.status, 404);
    expect(failure.code, 'not_found');
  });

  test('invalid token is unauthenticated and never cached', () async {
    backend.tokenValid = false;
    final AuthFailure failure = await _captureFailure(service.loadAvatar);
    expect(failure.status, 401);
    expect(failure.code, 'unauthenticated');
  });

  test('logout deletes the server session and the local credential', () async {
    await service.logout();
    expect(backend.tokenValid, isFalse);
    expect(session.hasToken, isFalse);
    expect(await store.read(), isNull);
  });

  test('heartbeat succeeds online and surfaces a 503 failure', () async {
    await service.heartbeat();
    expect(backend.heartbeatCalls, 1);
    backend.heartbeatStatus = 503;
    final AuthFailure failure = await _captureFailure(service.heartbeat);
    expect(failure.status, 503);
    expect(session.hasToken, isTrue);
  });
  test(
    'loadCover revalidates: default first, then 304 with cached bytes',
    () async {
      final CoverImage first = await service.loadCover();
      expect(first.isDefault, isTrue);
      expect(first.mimeType, 'image/png');
      expect(backend.coverIfNoneMatch.first, isNull);

      final CoverImage second = await service.loadCover();
      expect(second.bytes, first.bytes);
      expect(second.version, first.version);
      expect(second.isDefault, isTrue);
      expect(backend.coverIfNoneMatch, hasLength(2));
      expect(backend.coverIfNoneMatch[1], '"${first.version}"');
    },
  );

  test('a replaced server cover replaces the cached bytes', () async {
    final CoverImage first = await service.loadCover();
    backend.replaceCover(_png2);
    final CoverImage second = await service.loadCover();
    expect(second.bytes, _png2);
    expect(second.version, isNot(first.version));
    expect(second.isDefault, isFalse);
  });

  test(
    'updateCoverFromBytes uploads a multipart file then reads it back',
    () async {
      final CoverInfo info = await service.updateCoverFromBytes(_png2);
      expect(backend.coverUploadSizes, hasLength(1));
      expect(info.coverUrl, '/covers/${backend.validAccount}');
      expect(info.coverVersion, backend.coverVersion);

      final CoverImage displayed = await service.loadCover();
      expect(displayed.bytes, _png2);
      expect(displayed.isDefault, isFalse);
      // The upload invalidated the cache, so the next read cannot be a 304.
      expect(backend.coverIfNoneMatch.last, isNull);
    },
  );

  test('an oversize cover is rejected before any upload request', () async {
    final Uint8List tooLarge = Uint8List(8 * 1024 * 1024 + 1)..[0] = 0x89;
    await expectLater(
      service.updateCoverFromBytes(tooLarge),
      throwsA(
        isA<AuthFailure>()
            .having((AuthFailure f) => f.status, 'status', 413)
            .having((AuthFailure f) => f.code, 'code', 'payload_too_large'),
      ),
    );
    expect(backend.coverUploadSizes, isEmpty);
  });

  test('a failed upload keeps the previous server cover', () async {
    backend.replaceCover(_png1);
    backend.coverUploadStatus = 503;
    await expectLater(
      service.updateCoverFromBytes(_png2),
      throwsA(isA<AuthFailure>()),
    );
    final CoverImage displayed = await service.loadCover();
    expect(displayed.bytes, _png1);
  });
}

Future<AuthFailure> _captureFailure(Future<Object?> Function() action) async {
  try {
    await action();
  } on AuthFailure catch (failure) {
    return failure;
  }
  fail('expected AuthFailure');
}
