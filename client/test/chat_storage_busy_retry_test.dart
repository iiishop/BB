import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _accountA = '10000001';
const String _accountB = '10000002';

class _RetryApi extends ChatApiClient {
  _RetryApi({
    required this.failures,
    required this.code,
    this.retryAfterSeconds,
  }) : super(baseUri: Uri.parse('http://127.0.0.1:1'));

  final int failures;
  final String code;
  final int? retryAfterSeconds;
  int attempts = 0;
  final List<String> nonces = <String>[];

  @override
  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    attempts += 1;
    nonces.add(clientNonce);
    if (attempts <= failures) {
      throw AuthFailure(
        status: 503,
        code: code,
        message: 'server storage failure',
        retryAfterSeconds: retryAfterSeconds,
      );
    }
    return ChatMessage(
      id: 'message-once',
      position: 1,
      senderAccount: _accountA,
      targetAccount: targetAccount,
      createdAt: DateTime.now().toUtc(),
      kind: ChatMessageKind.body,
      parts: content,
    );
  }
}

void main() {
  late AuthSession session;
  late ChatLedger ledger;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-storage-retry-');
    session = AuthSession()
      ..establish(
        token: 'token-a',
        user: const AuthUser(account: _accountA, username: 'alice'),
      );
    ledger = ChatLedger.atPath('${root.path}/ledger.json');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  ChatService service(ChatApiClient api) => ChatService(
    api: api,
    session: session,
    ledger: ledger,
    cacheRoot: root,
    webSocketHints: false,
  );

  test(
    'storage_busy retries with one nonce and creates exactly one message',
    () async {
      final _RetryApi api = _RetryApi(
        failures: 3,
        code: 'storage_busy',
        retryAfterSeconds: 0,
      );
      final ChatService chat = service(api);
      addTearDown(chat.dispose);
      final SendOutcome outcome = await chat.sendBody(
        targetAccount: _accountB,
        content: const <OutgoingPart>[OutgoingText('retry me')],
        operationId: 'op-busy',
      );
      expect(api.attempts, 4, reason: 'initial attempt + three retries');
      expect(api.nonces.toSet(), <String>{'op-busy'});
      expect(outcome.message!.id, 'message-once');
      final ChatOperationRecord? record = await ledger.operation(
        _accountA,
        'op-busy',
      );
      expect(record?.state, 'succeeded');
      expect(record?.message?.id, 'message-once');
    },
  );

  test('storage_busy beyond three retries is a hard error', () async {
    final _RetryApi api = _RetryApi(
      failures: 99,
      code: 'storage_busy',
      retryAfterSeconds: 0,
    );
    final ChatService chat = service(api);
    addTearDown(chat.dispose);
    await expectLater(
      chat.sendBody(
        targetAccount: _accountB,
        content: const <OutgoingPart>[OutgoingText('never')],
        operationId: 'op-exhausted',
      ),
      throwsA(
        isA<AuthFailure>()
            .having((AuthFailure f) => f.code, 'code', 'storage_busy')
            .having((AuthFailure f) => f.message, 'message', contains('存储繁忙')),
      ),
    );
    expect(api.attempts, 4);
    expect(api.nonces.toSet(), <String>{'op-exhausted'});
    final ChatOperationRecord? record = await ledger.operation(
      _accountA,
      'op-exhausted',
    );
    expect(record?.state, 'failed');
  });

  test(
    'storage_io_error never retries and reports a hard storage error',
    () async {
      final _RetryApi api = _RetryApi(failures: 1, code: 'storage_io_error');
      final ChatService chat = service(api);
      addTearDown(chat.dispose);
      await expectLater(
        chat.sendBody(
          targetAccount: _accountB,
          content: const <OutgoingPart>[OutgoingText('io')],
          operationId: 'op-io',
        ),
        throwsA(
          isA<AuthFailure>()
              .having((AuthFailure f) => f.code, 'code', 'storage_io_error')
              .having(
                (AuthFailure f) => f.message,
                'message',
                contains('存储写入失败'),
              ),
        ),
      );
      expect(api.attempts, 1);
      expect(api.nonces, <String>['op-io']);
    },
  );

  test('other 503 codes are not retried', () async {
    final _RetryApi api = _RetryApi(failures: 1, code: 'storage_unavailable');
    final ChatService chat = service(api);
    addTearDown(chat.dispose);
    await expectLater(
      chat.sendBody(
        targetAccount: _accountB,
        content: const <OutgoingPart>[OutgoingText('other')],
        operationId: 'op-other',
      ),
      throwsA(
        isA<AuthFailure>().having(
          (AuthFailure f) => f.code,
          'code',
          'storage_unavailable',
        ),
      ),
    );
    expect(api.attempts, 1);
  });

  test('ChatApiClient reads Retry-After seconds from a 503', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      request.response.statusCode = 503;
      request.response.headers.set('retry-after', '2');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"error":{"code":"storage_busy","message":"busy","fields":[]}}',
      );
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final ChatApiClient api = ChatApiClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    await expectLater(
      api.sendMessage(
        token: 'token-a',
        targetAccount: _accountB,
        clientNonce: 'op-header',
        content: const <MessagePart>[TextPart('header')],
      ),
      throwsA(
        isA<AuthFailure>()
            .having((AuthFailure f) => f.retryAfterSeconds, 'retryAfter', 2)
            .having((AuthFailure f) => f.code, 'code', 'storage_busy'),
      ),
    );
  });
}
