import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _account = '10000001';
const String _peer = '10000002';

Future<PresentationReceipt> _receipt(
  ChatLedger ledger, {
  required String id,
  required int position,
  String consumer = 'c1',
}) {
  return ledger.prepareReceipt(
    account: _account,
    consumerSession: consumer,
    peerAccount: _peer,
    messageId: id,
    position: position,
    contentDigest: 'digest-$id',
  );
}

Matcher _failure(int status, String code) => isA<AuthFailure>()
    .having((AuthFailure f) => f.status, 'status', status)
    .having((AuthFailure f) => f.code, 'code', code);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bb-confirm-atomic-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('attempt binding is atomic, idempotent and conflict-safe', () async {
    final String path = '${root.path}/ledger.json';
    final ChatLedger ledger = ChatLedger.atPath(path);
    final PresentationReceipt r1 = await _receipt(
      ledger,
      id: 'm1',
      position: 1,
    );
    final PresentationReceipt r2 = await _receipt(
      ledger,
      id: 'm2',
      position: 2,
    );
    final List<String> ids = <String>[r1.receiptId, r2.receiptId];

    final List<String> first = await ledger.confirmPresentationAttempt(
      account: _account,
      consumerSession: 'c1',
      attemptId: 'attempt-1',
      requestDigest: 'digest-1',
      receiptIds: ids,
    );
    expect(first.toSet(), ids.toSet());
    expect((await ledger.receipt(_account, r1.receiptId))!.confirmed, isTrue);
    expect((await ledger.receipt(_account, r2.receiptId))!.confirmed, isTrue);
    expect(
      (await ledger.confirmation(_account, 'attempt-1'))!['request_digest'],
      'digest-1',
    );

    // Reordering the same member set is still the same attempt.
    expect(
      (await ledger.confirmPresentationAttempt(
        account: _account,
        consumerSession: 'c1',
        attemptId: 'attempt-1',
        requestDigest: 'digest-1',
        receiptIds: ids.reversed.toList(),
      )).toSet(),
      ids.toSet(),
    );

    await expectLater(
      ledger.confirmPresentationAttempt(
        account: _account,
        consumerSession: 'c1',
        attemptId: 'attempt-1',
        requestDigest: 'changed-digest',
        receiptIds: ids,
      ),
      throwsA(_failure(409, 'conflict')),
    );
    await expectLater(
      ledger.confirmPresentationAttempt(
        account: _account,
        consumerSession: 'c2',
        attemptId: 'attempt-1',
        requestDigest: 'digest-1',
        receiptIds: ids,
      ),
      throwsA(_failure(409, 'conflict')),
    );
    await expectLater(
      ledger.confirmPresentationAttempt(
        account: _account,
        consumerSession: 'c1',
        attemptId: 'attempt-1',
        requestDigest: 'digest-1',
        receiptIds: <String>[r1.receiptId],
      ),
      throwsA(_failure(409, 'conflict')),
    );
    // A later request may legitimately re-present an already-confirmed
    // receipt under a new attempt; its own attempt record is still bound.
    expect(
      await ledger.confirmPresentationAttempt(
        account: _account,
        consumerSession: 'c1',
        attemptId: 'attempt-2',
        requestDigest: 'digest-2',
        receiptIds: <String>[r1.receiptId],
      ),
      <String>[r1.receiptId],
    );
    expect(await ledger.confirmation(_account, 'attempt-2'), isNotNull);

    // Lost response + restart: the persisted attempt replays idempotently.
    final ChatLedger restarted = ChatLedger.atPath(path);
    expect(
      (await restarted.confirmPresentationAttempt(
        account: _account,
        consumerSession: 'c1',
        attemptId: 'attempt-1',
        requestDigest: 'digest-1',
        receiptIds: ids,
      )).toSet(),
      ids.toSet(),
    );
  });

  test(
    'one invalid member rejects the whole group with no side effect',
    () async {
      final ChatLedger ledger = ChatLedger.atPath('${root.path}/ledger.json');
      final PresentationReceipt pending = await _receipt(
        ledger,
        id: 'm3',
        position: 3,
      );

      await expectLater(
        ledger.confirmPresentationAttempt(
          account: _account,
          consumerSession: 'c1',
          attemptId: 'attempt-bad',
          requestDigest: 'digest-bad',
          receiptIds: <String>[pending.receiptId, 'missing'],
        ),
        throwsA(_failure(404, 'not_found')),
      );
      expect(
        (await ledger.receipt(_account, pending.receiptId))!.confirmed,
        isFalse,
        reason: 'valid member must not be confirmed before all validate',
      );
      expect(await ledger.confirmation(_account, 'attempt-bad'), isNull);

      expect(
        await ledger.confirmPresentationAttempt(
          account: _account,
          consumerSession: 'c1',
          attemptId: 'attempt-good',
          requestDigest: 'digest-good',
          receiptIds: <String>[pending.receiptId],
        ),
        <String>[pending.receiptId],
      );
    },
  );

  test('ACK cannot cross a gap left by a failed confirmation', () async {
    final ChatLedger ledger = ChatLedger.atPath('${root.path}/ledger.json');
    final AuthSession session = AuthSession()
      ..establish(
        token: 'token',
        user: const AuthUser(account: _account, username: 'alice'),
      );
    final ChatService service = ChatService(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
      session: session,
      ledger: ledger,
      cacheRoot: Directory.systemTemp,
      webSocketHints: false,
    );
    addTearDown(service.dispose);
    final PresentationReceipt r1 = await _receipt(
      ledger,
      id: 'm1',
      position: 1,
    );
    final PresentationReceipt r2 = await _receipt(
      ledger,
      id: 'm2',
      position: 2,
    );
    await service.confirmPresentation(
      consumerSession: 'c1',
      attemptId: 'attempt-1',
      requestDigest: 'digest-1',
      receiptIds: <String>[r1.receiptId],
    );
    await expectLater(
      service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'c1',
        throughPosition: 2,
      ),
      throwsA(_failure(409, 'consumption_gap')),
    );

    await expectLater(
      service.confirmPresentation(
        consumerSession: 'c1',
        attemptId: 'attempt-2',
        requestDigest: 'digest-2',
        receiptIds: <String>[r2.receiptId, 'missing'],
      ),
      throwsA(_failure(404, 'not_found')),
    );
    await expectLater(
      service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'c1',
        throughPosition: 2,
      ),
      throwsA(_failure(409, 'consumption_gap')),
    );

    await service.confirmPresentation(
      consumerSession: 'c1',
      attemptId: 'attempt-3',
      requestDigest: 'digest-3',
      receiptIds: <String>[r2.receiptId],
    );
    expect(
      await service.ackMessages(
        peerAccount: _peer,
        consumerSession: 'c1',
        throughPosition: 2,
      ),
      2,
    );
  });

  test(
    'an in-flight confirm cannot write the newly switched account ledger',
    () async {
      final ChatLedger ledger = ChatLedger.atPath('${root.path}/ledger.json');
      final AuthSession session = AuthSession()
        ..establish(
          token: 'token-a',
          user: const AuthUser(account: _account, username: 'alice'),
        );
      final ChatService service = ChatService(
        api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
        session: session,
        ledger: ledger,
        cacheRoot: Directory.systemTemp,
        webSocketHints: false,
      );
      addTearDown(service.dispose);
      final PresentationReceipt receipt = await _receipt(
        ledger,
        id: 'm1',
        position: 1,
      );

      final Future<List<String>> inFlight = service.confirmPresentation(
        consumerSession: 'c1',
        attemptId: 'switch-attempt',
        requestDigest: 'digest-a',
        receiptIds: <String>[receipt.receiptId],
      );
      session.establish(
        token: 'token-b',
        user: const AuthUser(account: '10000009', username: 'bob'),
      );
      await expectLater(inFlight, throwsA(_failure(409, 'stale_identity')));

      // The identity check happens before the write: an invalidated binding
      // must not leave a half-committed confirmation.
      expect(await ledger.confirmation(_account, 'switch-attempt'), isNull);
      expect(await ledger.confirmation('10000009', 'switch-attempt'), isNull);
    },
  );
}
