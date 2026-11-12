import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_backend.dart';

const String _accountA = '10000001';
const String _accountB = '10000002';

class _DelayedChatApi extends ChatApiClient {
  _DelayedChatApi() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final Completer<void> gate = Completer<void>();

  @override
  Future<MessagePage> conversation({
    required String token,
    required String account,
    int afterPosition = 0,
    int limit = 50,
  }) async {
    await gate.future;
    return MessagePage(
      items: <ChatMessage>[
        ChatMessage(
          id: 'a-message',
          position: 1,
          senderAccount: _accountA,
          targetAccount: _accountB,
          createdAt: DateTime.now().toUtc(),
          kind: ChatMessageKind.body,
          parts: const <MessagePart>[TextPart('A only')],
        ),
      ],
      nextPosition: 1,
      hasMore: false,
    );
  }
}

void main() {
  late FakeChatBackend backend;
  late Directory root;
  late AuthSession session;
  late ChatService service;

  AuthUser user(String account) => AuthUser(
    account: account,
    username: account == _accountA ? 'alice' : 'bob',
  );

  ChatService build(AuthSession auth, {ChatApiClient? api}) {
    return ChatService(
      api: api ?? ChatApiClient(baseUri: backend.baseUri),
      session: auth,
      ledger: ChatLedger.atPath('${root.path}/ledger.json'),
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
  }

  setUp(() async {
    backend = await FakeChatBackend.start(
      users: <String, String>{_accountA: 'alice', _accountB: 'bob'},
    );
    root = await Directory.systemTemp.createTemp('bb-identity-');
    session = AuthSession()
      ..establish(token: backend.tokenFor(_accountA), user: user(_accountA));
    service = build(session);
  });

  tearDown(() async {
    await service.dispose();
    await backend.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> switchTo(String account) async {
    session.establish(token: backend.tokenFor(account), user: user(account));
  }

  test(
    'in-flight A wait is cancelled on B login and leaks no B event',
    () async {
      await service.subscribeEvents(
        consumerSession: 'qa-switch',
        peerAccount: _accountB,
      );
      final Future<LocalEventPage> waiting = service.waitEvents(
        consumerSession: 'qa-switch',
        afterCursor: 0,
        timeoutSeconds: 30,
      );
      await switchTo(_accountB);
      await service.subscribeEvents(
        consumerSession: 'qa-switch',
        peerAccount: _accountA,
      );
      await backend.seedMessage(
        sender: _accountA,
        target: _accountB,
        text: 'B only',
      );
      await service.eventFeed.pollOnce();
      final LocalEventPage bFeed = await service.readEvents(
        consumerSession: 'qa-switch',
        afterCursor: 0,
      );
      expect(bFeed.items, hasLength(1));
      final LocalEventPage result = await waiting;
      expect(result.items, isEmpty);
      expect(result.nextCursor, 0);
      expect(result.reason, 'cancelled');
      expect(session.user!.account, _accountB);
      expect(
        session.hasToken,
        isTrue,
        reason: 'B login survives A request end',
      );
      await service.dispose();
      service = build(session);
    },
  );

  test('same-account re-login and A→B→A cancel the old wait', () async {
    await service.subscribeEvents(
      consumerSession: 'relogin',
      peerAccount: _accountB,
    );
    final Future<LocalEventPage> sameAccount = service.waitEvents(
      consumerSession: 'relogin',
      afterCursor: 0,
      timeoutSeconds: 30,
    );
    await switchTo(_accountA);
    expect((await sameAccount).reason, 'cancelled');

    final Future<LocalEventPage> roundTrip = service.waitEvents(
      consumerSession: 'relogin',
      afterCursor: 0,
      timeoutSeconds: 30,
    );
    await switchTo(_accountB);
    await switchTo(_accountA);
    final LocalEventPage result = await roundTrip;
    expect(result.items, isEmpty);
    expect(result.nextCursor, 0);
    expect(result.reason, 'cancelled');
  });

  test('logout cancels the wait with logout and keeps the cursor', () async {
    await service.subscribeEvents(
      consumerSession: 'logout',
      peerAccount: _accountB,
    );
    final Future<LocalEventPage> waiting = service.waitEvents(
      consumerSession: 'logout',
      afterCursor: 0,
      timeoutSeconds: 30,
    );
    session.clear();
    final LocalEventPage result = await waiting;
    expect(result.items, isEmpty);
    expect(result.nextCursor, 0);
    expect(result.reason, 'logout');
  });

  test('Profile nickname refresh does not cancel the same login', () async {
    await backend.seedMessage(
      sender: _accountB,
      target: _accountA,
      text: 'still A',
    );
    await service.subscribeEvents(
      consumerSession: 'nickname',
      peerAccount: _accountB,
    );
    session.updateUser(const AuthUser(account: _accountA, username: 'alice2'));
    final LocalEventPage result = await service.waitEvents(
      consumerSession: 'nickname',
      afterCursor: 0,
      timeoutSeconds: 30,
    );
    expect(result.reason, 'events');
    expect(result.items, isNotEmpty);
  });

  test('in-flight read does not apply a later B session', () async {
    final _DelayedChatApi delayed = _DelayedChatApi();
    final AuthSession auth = AuthSession()
      ..establish(token: 'token-a', user: user(_accountA));
    final ChatService delayedService = ChatService(
      api: delayed,
      session: auth,
      ledger: ChatLedger.inMemory(),
      cacheRoot: Directory.systemTemp,
      webSocketHints: false,
    );
    addTearDown(delayedService.dispose);
    final Future<VisibleMessagePage> reading = delayedService.readMessages(
      peerAccount: _accountB,
      consumerSession: 'read-switch',
    );
    auth.establish(token: 'token-b', user: user(_accountB));
    delayed.gate.complete();
    await expectLater(
      reading,
      throwsA(
        isA<AuthFailure>().having((AuthFailure f) => f.status, 'status', 401),
      ),
    );
  });

  test('media stream opened by A cannot serve B', () async {
    final String mediaId = await backend.addMedia(
      owner: _accountB,
      peer: _accountA,
      bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      mime: 'video/mp4',
      kind: 'video',
      filename: 'clip.mp4',
      coverId: 'cover-1',
    );
    final handle = await service.openMediaStream(mediaId);
    await switchTo(_accountB);
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(handle.uri);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
    } finally {
      client.close(force: true);
      await handle.close();
    }
  });
}
