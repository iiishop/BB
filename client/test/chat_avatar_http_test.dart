import 'dart:io';

import 'package:bb_client/services/auth_api_client.dart';
import 'package:bb_client/services/auth_service.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_cache.dart';
import 'package:bb_client/services/profile_api_client.dart';
import 'package:bb_client/services/profile_service.dart';
import 'package:bb_client/services/session_store.dart';
import 'package:bb_client/ui/chat/chat_avatars.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/avatar_fixtures.dart';
import 'support/fake_auth_backend.dart';

/// Real loopback HTTP path for the chat avatar loader: the same
/// [ProfileService]/[AvatarCache] used by the Profile panel performs the
/// authenticated `/avatars/{account}.png` GETs and `If-None-Match`
/// revalidation.
const String _self = '10000001';
const String _peer = '10000002';

Future<({FakeAuthBackend backend, ProfileService service})> _startServer({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final FakeAuthBackend backend = await FakeAuthBackend.start();
  backend.validAccount = _self;
  backend.knownAccounts.add(_peer);
  backend.setAvatar(_self, selfIdenticon);
  backend.setAvatar(_peer, peerIdenticon);

  final Directory directory = await Directory.systemTemp.createTemp(
    'bb-chat-avatar-http-',
  );
  final AuthSession session = AuthSession();
  final AuthService auth = AuthService(
    api: AuthApiClient(baseUri: backend.baseUri),
    session: session,
    store: SessionStore.atPath('${directory.path}/session.json'),
  );
  final ProfileService service = ProfileService(
    api: ProfileApiClient(baseUri: backend.baseUri, timeout: timeout),
    auth: auth,
    cache: AvatarCache(),
  );
  await auth.login(account: _self, password: backend.validPassword);
  addTearDown(() async {
    try {
      await backend.close();
    } on Object {
      // Already closed by the offline case.
    }
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });
  return (backend: backend, service: service);
}

Future<void> _settle(ChatAvatarController controller) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    if (!controller.isLoading(_self) && !controller.isLoading(_peer)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('avatar requests did not reach a terminal state');
}

int _requests(FakeAuthBackend backend, String account) => backend.log
    .where(
      (({String method, String path, String? authorization}) request) =>
          request.path == '/avatars/$account.png',
    )
    .length;

void main() {
  test('30 rebuilds ask each account once and re-entry revalidates one image', () async {
    final ({FakeAuthBackend backend, ProfileService service}) env =
        await _startServer();
    final FakeAuthBackend backend = env.backend;

    ChatAvatarController controller = ChatAvatarController(
      profile: env.service,
      accounts: <String>[_self, _peer],
    );
    await _settle(controller);
    expect(_requests(backend, _self), 1);
    expect(_requests(backend, _peer), 1);
    expect(controller.bytesFor(_self), orderedEquals(selfIdenticon));
    expect(controller.bytesFor(_peer), orderedEquals(peerIdenticon));
    expect(controller.hasFailed(_self), isFalse);
    expect(controller.hasFailed(_peer), isFalse);

    // One controller serve any number of bubbles: no further transport calls.
    await Future.wait(<Future<void>>[
      for (int i = 0; i < 30; i++) controller.ensureLoaded(_self),
      for (int i = 0; i < 30; i++) controller.ensureLoaded(_peer),
    ]);
    expect(_requests(backend, _self), 1);
    expect(_requests(backend, _peer), 1);

    final String selfVersion = backend.avatarVersionsByAccount[_self]!;
    final String peerVersion = backend.avatarVersionsByAccount[_peer]!;

    // Leaving and re-entering builds a fresh controller: exactly one
    // revalidation request per account, 304 keeps the cached bytes.
    controller = ChatAvatarController(
      profile: env.service,
      accounts: <String>[_self, _peer],
    );
    await _settle(controller);
    expect(_requests(backend, _self), 2);
    expect(_requests(backend, _peer), 2);
    expect(backend.avatarIfNoneMatchByAccount[_self]!.last, '"$selfVersion"');
    expect(backend.avatarIfNoneMatchByAccount[_peer]!.last, '"$peerVersion"');
    expect(controller.bytesFor(_peer), orderedEquals(peerIdenticon));

    // The peer uploads a new avatar. The next visit gets 200 + new bytes while
    // the unchanged self avatar is still reused from its 304 cache.
    backend.setAvatar(_peer, peerReplacedAvatar);
    controller = ChatAvatarController(
      profile: env.service,
      accounts: <String>[_self, _peer],
    );
    await _settle(controller);
    expect(_requests(backend, _self), 3);
    expect(_requests(backend, _peer), 3);
    expect(controller.bytesFor(_peer), orderedEquals(peerReplacedAvatar));
    expect(controller.bytesFor(_self), orderedEquals(selfIdenticon));
  });

  test(
    'offline and timeout are terminal per account without retry loops',
    () async {
      final ({FakeAuthBackend backend, ProfileService service}) offlineEnv =
          await _startServer();
      await offlineEnv.backend.close();

      final ChatAvatarController offline = ChatAvatarController(
        profile: offlineEnv.service,
        accounts: <String>[_self, _peer],
      );
      await _settle(offline);
      expect(offline.isLoading(_self), isFalse);
      expect(offline.isLoading(_peer), isFalse);
      expect(offline.hasFailed(_self), isTrue);
      expect(offline.hasFailed(_peer), isTrue);
      expect(offline.bytesFor(_self), isNull);
      expect(offline.bytesFor(_peer), isNull);

      final ({FakeAuthBackend backend, ProfileService service}) slowEnv =
          await _startServer(timeout: const Duration(milliseconds: 150));
      slowEnv.backend.delay = const Duration(milliseconds: 500);
      final ChatAvatarController timeout = ChatAvatarController(
        profile: slowEnv.service,
        accounts: <String>[_self, _peer],
      );
      await _settle(timeout);
      expect(timeout.isLoading(_self), isFalse);
      expect(timeout.isLoading(_peer), isFalse);
      expect(timeout.hasFailed(_self), isTrue);
      expect(timeout.hasFailed(_peer), isTrue);
      expect(timeout.bytesFor(_self), isNull);
      expect(timeout.bytesFor(_peer), isNull);

      // One attempt per account; waiting longer neither retries nor reopens the
      // spinner the UI would show while loading.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_requests(slowEnv.backend, _self), 1);
      expect(_requests(slowEnv.backend, _peer), 1);
      expect(timeout.isLoading(_self), isFalse);
      expect(timeout.isLoading(_peer), isFalse);
    },
  );
}
