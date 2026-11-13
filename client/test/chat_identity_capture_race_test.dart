import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/chat_v2.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

const String _accountA = '10000001';
const String _accountB = '10000002';

class _RecordingApi extends ChatApiClient {
  _RecordingApi() : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final List<String> tokens = <String>[];
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<UserPage> listUsers({
    required String token,
    String afterAccount = '',
    int limit = 50,
  }) async {
    tokens.add(token);
    if (entered != null) {
      entered!.complete();
      await release!.future;
    }
    return UserPage(
      items: const <ChatUser>[],
      nextCursor: 'private-result-for-$token',
    );
  }
}

void main() {
  late Directory root;
  late AuthSession session;
  late ChatLedger ledger;
  late ChatService chat;
  late _RecordingApi api;
  late String owner;
  late ConsumerBinding binding;

  AuthUser user(String account, String name) =>
      AuthUser(account: account, username: name);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-f1-switch-');
    session = AuthSession()
      ..establish(token: 'token-A', user: user(_accountA, 'alice'));
    api = _RecordingApi();
    ledger = ChatLedger.atPath('${root.path}/ledger.json');
    chat = ChatService(
      api: api,
      session: session,
      ledger: ledger,
      cacheRoot: Directory('${root.path}/cache'),
      webSocketHints: false,
    );
    owner = newOwnerKey();
    binding = await chat.enrollConsumer(
      ownerKeyHash: ownerKeyHash(owner),
      sessionId: 'session',
    );
  });

  tearDown(() async {
    await chat.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<({int status, Map<String, dynamic> body})> listUsers() {
    return ChatV2Router(session: session, chat: chat).handle(
      path: '/v2/chat/list_users',
      ownerKey: owner,
      body: <String, dynamic>{'expected_identity': binding.identity.toJson()},
    );
  }

  test('switching during requireIdentity never uses the new account token',
      () async {
    final Completer<void> entered = Completer<void>();
    final Completer<void> release = Completer<void>();
    final Future<void> holding = ledger.confirmPresentationAttempt(
      account: _accountA,
      consumerSession: 'session',
      consumerId: binding.consumerId,
      attemptId: 'hold-lock',
      requestDigest: 'digest',
      receiptIds: const <String>[],
      beforeCommit: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    final Future<({int status, Map<String, dynamic> body})> request =
        listUsers();
    await Future<void>.delayed(Duration.zero);
    session.establish(token: 'token-B', user: user(_accountB, 'bob'));
    release.complete();
    await holding;
    final ({int status, Map<String, dynamic> body}) response = await request;

    expect(
      response.status,
      409,
      reason:
          'stale request must not answer with A identity after switching: ${response.body}',
    );
    expect(api.tokens, isNot(contains('token-B')));
    expect(
      response.body.toString(),
      isNot(contains('private-result-for-token-B')),
    );
  });

  test('switching after identity capture returns stale before exposing',
      () async {
    api.entered = Completer<void>();
    api.release = Completer<void>();
    final Future<({int status, Map<String, dynamic> body})> request =
        listUsers();
    await api.entered!.future;
    session.establish(token: 'token-B', user: user(_accountB, 'bob'));
    api.release!.complete();
    final ({int status, Map<String, dynamic> body}) response = await request;

    expect(api.tokens, <String>['token-A']);
    expect(response.status, 409, reason: '${response.body}');
    expect(
      response.body.toString(),
      isNot(contains('private-result-for-token-B')),
    );
  });

  test('normal list_users still returns the captured identity result', () async {
    final ({int status, Map<String, dynamic> body}) response = await listUsers();
    expect(response.status, 200, reason: '${response.body}');
    expect(response.body['identity']['account'], _accountA);
    expect(response.body['result']['next_cursor'], 'private-result-for-token-A');
  });
}
