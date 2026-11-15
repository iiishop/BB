import 'dart:async';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:flutter_test/flutter_test.dart';

const account = '10000001';
const peer = '10000002';
final committed = ChatMessage(
  id: 'committed',
  position: 1,
  senderAccount: account,
  targetAccount: peer,
  createdAt: DateTime.utc(2026),
  kind: ChatMessageKind.body,
  parts: const [TextPart('same')],
);

ChatOperationRecord plan({String id = 'op', ExpectedIdentity? identity}) =>
    ChatOperationRecord(
      operationId: id,
      kind: 'message',
      targetAccount: peer,
      state: 'prepared',
      sourceDigest: 'digest',
      parts: const [],
      expectedIdentity: identity,
    );

// Only transport completion is controlled. Service, ledger and file writes are real.
class PausedQuery extends ChatApiClient {
  PausedQuery() : super(baseUri: Uri.parse('http://127.0.0.1:1'));
  final entered = Completer<void>();
  final response = Completer<OperationResult?>();
  @override
  Future<OperationResult?> getOperation({
    required String token,
    required String operationId,
  }) {
    entered.complete();
    return response.future;
  }
}

class PausedSend extends ChatApiClient {
  PausedSend() : super(baseUri: Uri.parse('http://127.0.0.1:1'));
  final entered = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<ChatMessage> sendMessage({
    required String token,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    if (++calls == 1) {
      entered.complete();
      await release.future;
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'old rejection',
      );
    }
    return committed;
  }
}

void main() {
  late Directory root;
  late String path;
  late ChatLedger ledger;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-operation-merge-');
    path = '${root.path}/ledger.json';
    ledger = ChatLedger.atPath(path);
    await ledger.saveOperation(account, plan());
  });
  tearDown(() async => root.delete(recursive: true));

  for (final state in ['prepared', 'uncertain', 'failed']) {
    test(
      'late $state cannot replace committed operation in memory or cold open',
      () async {
        final old = plan();
        await ledger.saveOperation(
          account,
          old.copyWith(state: 'succeeded', message: committed),
        );
        await ledger.saveOperation(account, old.copyWith(state: state));
        for (final source in [ledger, ChatLedger.atPath(path)]) {
          final result = (await source.operation(account, 'op'))!;
          expect(result.state, 'succeeded');
          expect(result.message!.id, committed.id);
          expect(result.message!.operationId, 'op');
        }
      },
    );
  }

  for (final consumer in [false, true]) {
    for (final status in OperationStatus.values) {
      test(
        '${consumer ? 'consumer' : 'account'} late $status cannot undo success',
        () async {
          final api = PausedQuery();
          final session = AuthSession()
            ..establish(
              token: 'synthetic',
              user: const AuthUser(account: account, username: 'a'),
            );
          final service = ChatService(
            api: api,
            session: session,
            ledger: ledger,
            cacheRoot: Directory('${root.path}/cache'),
            webSocketHints: false,
          );
          addTearDown(service.dispose);
          final identity = await service.identityFor('probe');
          final original = plan(id: 'scoped', identity: identity);
          await ledger.saveOperation(account, original);
          final query = consumer
              ? service.operationForIdentity(identity, 'scoped')
              : service.getOperation('scoped');
          await api.entered.future;
          await ledger.saveOperation(
            account,
            original.copyWith(state: 'succeeded', message: committed),
          );
          api.response.complete(
            OperationResult(
              operationId: 'scoped',
              kind: 'message',
              status: status,
              message: status == OperationStatus.succeeded ? committed : null,
              errorCode: status == OperationStatus.failed
                  ? 'validation_error'
                  : null,
            ),
          );
          final result = (await query)!;
          expect(result.status, OperationStatus.succeeded);
          expect(result.message!.operationId, 'scoped');
          expect(result.errorCode, isNull);
        },
      );
    }
  }

  test(
    'real service late send failure returns concurrent committed retry',
    () async {
      final api = PausedSend();
      final session = AuthSession()
        ..establish(
          token: 'synthetic',
          user: const AuthUser(account: account, username: 'a'),
        );
      final service = ChatService(
        api: api,
        session: session,
        ledger: ledger,
        cacheRoot: Directory('${root.path}/cache'),
        webSocketHints: false,
      );
      addTearDown(service.dispose);
      Future<SendOutcome> send() => service.sendBody(
        targetAccount: peer,
        content: const [OutgoingText('same')],
        operationId: 'send',
      );
      final first = send();
      await api.entered.future;
      final retry = await send();
      api.release.complete();
      expect((await first).message!.id, retry.message!.id);
      expect(
        (await ChatLedger.atPath(path).operation(account, 'send'))!.state,
        'succeeded',
      );
      expect(api.calls, 2);
    },
  );

  test(
    'conflicting committed identity is rejected without losing original',
    () async {
      await ledger.saveOperation(
        account,
        plan().copyWith(state: 'succeeded', message: committed),
      );
      final wrong = ChatMessage(
        id: 'other',
        position: 2,
        senderAccount: account,
        targetAccount: peer,
        createdAt: DateTime.utc(2026),
        kind: ChatMessageKind.body,
        parts: const [TextPart('same')],
      );
      await expectLater(
        ledger.saveOperation(
          account,
          plan().copyWith(state: 'succeeded', message: wrong),
        ),
        throwsFormatException,
      );
      expect(
        (await ChatLedger.atPath(path).operation(account, 'op'))!.message!.id,
        committed.id,
      );
    },
  );

  for (final consumer in [false, true]) {
    for (final error in [false, true]) {
      test(
        'real ${consumer ? 'consumer' : 'account'} service late ${error ? 'error' : '404'} observes newer commit',
        () async {
          final api = PausedQuery();
          final session = AuthSession()
            ..establish(
              token: 'synthetic',
              user: const AuthUser(account: account, username: 'a'),
            );
          final service = ChatService(
            api: api,
            session: session,
            ledger: ledger,
            cacheRoot: Directory('${root.path}/cache'),
            webSocketHints: false,
          );
          addTearDown(service.dispose);
          final identity = await service.identityFor('late-query');
          final original = plan(id: 'late-query', identity: identity);
          await ledger.saveOperation(account, original);
          final query = consumer
              ? service.operationForIdentity(identity, 'late-query')
              : service.getOperation('late-query');
          await api.entered.future;
          await ledger.saveOperation(
            account,
            original.copyWith(state: 'succeeded', message: committed),
          );
          if (error) {
            api.response.completeError(
              const AuthFailure(
                status: 502,
                code: 'upstream_unavailable',
                message: 'synthetic failure',
              ),
            );
          } else {
            api.response.complete(null);
          }
          final result = await query;
          expect(result!.status, OperationStatus.succeeded);
          expect(result.message!.id, committed.id);
        },
      );
    }
  }

  for (final bad in ['operation', 'sender', 'target', 'association', 'kind']) {
    test(
      'real service rejects mismatched $bad before recording success',
      () async {
        final api = PausedQuery();
        final session = AuthSession()
          ..establish(
            token: 'synthetic',
            user: const AuthUser(account: account, username: 'a'),
          );
        final service = ChatService(
          api: api,
          session: session,
          ledger: ledger,
          cacheRoot: Directory('${root.path}/cache'),
          webSocketHints: false,
        );
        addTearDown(service.dispose);
        final query = service.getOperation('op');
        final checked = expectLater(
          query,
          throwsA(isA<AuthFailure>().having((f) => f.status, 'status', 502)),
        );
        await api.entered.future;
        final message = ChatMessage(
          id: 'committed',
          position: 1,
          senderAccount: bad == 'sender' ? '10000003' : account,
          targetAccount: bad == 'target' ? '10000003' : peer,
          createdAt: DateTime.utc(2026),
          kind: ChatMessageKind.body,
          parts: const [TextPart('same')],
          operationId: bad == 'association' ? 'other' : null,
        );
        api.response.complete(
          OperationResult(
            operationId: bad == 'operation' ? 'other' : 'op',
            kind: bad == 'kind' ? 'download' : 'message',
            status: OperationStatus.succeeded,
            message: message,
          ),
        );
        await checked;
        expect((await ledger.operation(account, 'op'))!.state, 'prepared');
      },
    );
  }

  test(
    'late pending cannot replace a newer definite failure snapshot',
    () async {
      final api = PausedQuery();
      final session = AuthSession()
        ..establish(
          token: 'synthetic',
          user: const AuthUser(account: account, username: 'a'),
        );
      final service = ChatService(
        api: api,
        session: session,
        ledger: ledger,
        cacheRoot: Directory('${root.path}/cache'),
        webSocketHints: false,
      );
      addTearDown(service.dispose);
      final query = service.getOperation('op');
      await api.entered.future;
      await ledger.saveOperation(
        account,
        plan().copyWith(
          state: 'failed',
          errorCode: 'validation_error',
          errorStatus: 422,
        ),
      );
      api.response.complete(
        const OperationResult(
          operationId: 'op',
          kind: 'message',
          status: OperationStatus.pending,
        ),
      );
      final result = (await query)!;
      expect(result.status, OperationStatus.failed);
      expect(result.errorCode, 'validation_error');
      expect(
        (await ChatLedger.atPath(path).operation(account, 'op'))!.revision,
        2,
      );
    },
  );

  test(
    'failed operation flush rolls back, then retry and cold open retain commit',
    () async {
      await File(path).rename('$path.saved');
      await Directory(path).create();
      final success = plan().copyWith(state: 'succeeded', message: committed);
      await expectLater(
        ledger.saveOperation(account, success),
        throwsA(isA<FileSystemException>()),
      );
      expect((await ledger.operation(account, 'op'))!.state, 'prepared');
      await Directory(path).delete();
      await File('$path.saved').rename(path);
      await ledger.saveOperation(account, success);
      expect(
        (await ChatLedger.atPath(path).operation(account, 'op'))!.message!.id,
        committed.id,
      );
    },
  );
}
