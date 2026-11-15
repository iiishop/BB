import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/space_api_client.dart';
import 'package:bb_client/services/space_service.dart';
import 'package:flutter_test/flutter_test.dart';

class ContractApi extends SpaceApiClient {
  ContractApi(this.handler)
    : super(baseUri: Uri.parse('http://127.0.0.1:8888'));
  final Future<Map<String, dynamic>> Function(
    String,
    Map<String, dynamic>,
    String,
  )
  handler;
  @override
  Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body, {
    required String token,
  }) async {
    validateSpace(action, body);
    final result = await handler(action, body, token);
    validateSpace(action, result, kind: 'response');
    return result;
  }
}

Map<String, dynamic> receipt(String id) => {
  'operation_id': id,
  'status': 'succeeded',
  'action': 'create_draft',
  'resource_id': 'draft',
  'resource_version': 1,
};
void main() {
  late Directory root;
  late ChatLedger ledger;
  late AuthSession session;
  late ChatService chat;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('space-service-');
    ledger = ChatLedger.atPath('${root.path}/ledger.json');
    session = AuthSession()
      ..establish(
        token: 'synthetic',
        user: const AuthUser(account: '10000001', username: 'Alice'),
      );
    chat = ChatService(
      api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:8888')),
      session: session,
      ledger: ledger,
      cacheRoot: root,
    );
  });
  tearDown(() async {
    await chat.dispose();
    await root.delete(recursive: true);
  });
  test('consumer cannot reuse another consumer operation ID on same server/account', () async {
    final a = jsonEncode(['server', '10000001', 'consumer-a']);
    final b = jsonEncode(['server', '10000001', 'consumer-b']);
    await ledger.planSpaceOperation(a, 'op', 'create_draft', 'digest');
    expect(await ledger.spaceOperation(b, 'op'), isNull);
    await expectLater(
      ledger.planSpaceOperation(b, 'op', 'create_draft', 'digest'),
      throwsA(isA<AuthFailure>()),
    );
    await ledger.planSpaceOperation(
      jsonEncode(['other-server', '10000001', 'consumer-b']),
      'op',
      'create_draft',
      'digest',
    );
  });
  test(
    'lost publish reply reconciles without sending a second mutation',
    () async {
      var sends = 0;
      final api = ContractApi((action, body, token) async {
        if (action == 'get_operation') return receipt('op');
        sends++;
        throw upstreamTimeout;
      });
      final service = SpaceService(api: api, session: session, chat: chat);
      await expectLater(
        service.createDraft(operationId: 'op', text: 'body'),
        throwsA(isA<AuthFailure>()),
      );
      expect(
        (await service.createDraft(operationId: 'op', text: 'body')).resourceId,
        'draft',
      );
      expect(sends, 1);
      await expectLater(
        service.createDraft(operationId: 'op', text: 'changed'),
        throwsA(isA<AuthFailure>()),
      );
      final reopened = ChatLedger.atPath('${root.path}/ledger.json');
      final scope = jsonEncode([api.baseUri.toString(), '10000001', 'human']);
      expect(
        (await reopened.spaceOperation(scope, 'op'))!['receipt'],
        receipt('op'),
      );
      expect(
        await File('${root.path}/ledger.json').readAsString(),
        isNot(contains('body')),
      );
    },
  );
  test('in-flight switch saves original receipt but fences result and cross-account query', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final api = ContractApi((action, body, token) async {
      if (action == 'get_operation') return receipt('op');
      expect(token, 'synthetic');
      started.complete();
      await release.future;
      return receipt('op');
    });
    final service = SpaceService(api: api, session: session, chat: chat);
    final pending = service.createDraft(operationId: 'op', text: 'private');
    final assertion = expectLater(
      pending,
      throwsA(
        isA<AuthFailure>().having((e) => e.code, 'code', 'stale_identity'),
      ),
    );
    await started.future;
    session.establish(
      token: 'other',
      user: const AuthUser(account: '10000002', username: 'Bob'),
    );
    release.complete();
    await assertion;
    await expectLater(
      service.getOperation(operationId: 'op'),
      throwsA(isA<AuthFailure>().having((e) => e.status, 'status', 404)),
    );
    session.establish(
      token: 'relogin',
      user: const AuthUser(account: '10000001', username: 'Alice'),
    );
    expect((await service.getOperation(operationId: 'op')).resourceId, 'draft');
  });
  test(
    'intent flush failure prevents IO and rollback survives cold reopen',
    () async {
      var requests = 0;
      var fail = true;
      ledger = ChatLedger.atPath(
        '${root.path}/fault.json',
        beforeReplace: () async {
          if (fail) throw const FileSystemException('injected');
        },
      );
      final localChat = ChatService(
        api: chat.api,
        session: session,
        ledger: ledger,
        cacheRoot: root,
      );
      final api = ContractApi((action, body, token) async {
        requests++;
        return receipt('op');
      });
      final service = SpaceService(api: api, session: session, chat: localChat);
      await expectLater(
        service.createDraft(operationId: 'op', text: 'x'),
        throwsA(isA<FileSystemException>()),
      );
      expect(requests, 0);
      final scope = jsonEncode([api.baseUri.toString(), '10000001', 'human']);
      expect(await ledger.spaceOperation(scope, 'op'), isNull);
      fail = false;
      await service.createDraft(operationId: 'op', text: 'x');
      expect(requests, 1);
      expect(
        (await ChatLedger.atPath('${root.path}/fault.json')
            .spaceOperation(scope, 'op'))!['receipt'],
        receipt('op'),
      );
      await localChat.dispose();
    },
  );
  test('schema rejects unknown fields, wrong type, duplicate images and blank comments', () {
    expect(
      () => validateSpace('overview', {'author': '10000001'}),
      throwsFormatException,
    );
    expect(
      () => validateSpace('list_posts', {'limit': true}),
      throwsFormatException,
    );
    expect(
      () => validateSpace('update_draft', {
        'operation_id': 'op',
        'draft_id': 'd',
        'expected_version': 1,
        'text': '',
        'image_ids': ['same', 'same'],
      }),
      throwsFormatException,
    );
    expect(
      () => validateSpace('create_comment', {
        'operation_id': 'op',
        'post_id': 'p',
        'text': '  ',
      }),
      throwsFormatException,
    );
  });
}
