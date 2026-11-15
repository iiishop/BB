import 'dart:convert';
import 'dart:io';

import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> wire({Object? operation = 'op'}) => {
  'id': 'm',
  'position': 1,
  'sender_account': '10000001',
  'target_account': '10000002',
  'created_at': '2026-11-15T00:00:00Z',
  'kind': 'body',
  'content': [
    {'type': 'text', 'text': 'same'},
  ],
  'operation_id': ?operation,
};

void main() {
  test(
    'internal round trip retains association; all legacy serializers omit it',
    () {
      final message = ChatMessage.fromJson(wire());
      expect(message.operationId, 'op');
      expect(messageToJson(message).containsKey('operation_id'), false);
      expect(
        ChatMessage.fromJson(messageToJson(message, includeAssociation: true))
            .operationId,
        'op',
      );
      final result = OperationResult(
        operationId: 'op',
        kind: 'message',
        status: OperationStatus.succeeded,
        message: message,
      ).toJson();
      expect((result['message'] as Map).containsKey('operation_id'), false);
      expect(ChatMessage.fromJson(wire(operation: null)).operationId, isNull);
    final legacyRecord = <String, dynamic>{
      'operation_id': 'op', 'kind': 'message', 'target_account': '10000002',
      'state': 'succeeded', 'source_digest': 'old', 'parts': <Object>[],
      'message': wire(operation: null),
    };
    final recovered = ChatOperationRecord.fromJson(legacyRecord);
    expect(recovered.revision, 0);
    expect(recovered.message!.operationId, 'op');
      for (final invalid in ['', 'space bad', 12]) {
        expect(
          () => ChatMessage.fromJson(wire(operation: invalid)),
          throwsFormatException,
        );
      }
      expect(() => message.withOperationId('other'), throwsFormatException);
      expect(() => message.validateReader('10000002'), throwsFormatException);
      expect(() => message.validateReader('10000003'), throwsFormatException);
      expect(
        () => message.validateReader('10000001', peerAccount: '10000003'),
        throwsFormatException,
      );
    },
  );

  for (final negotiated in [false, true]) {
    test(
      'HTTP association requires response negotiation: $negotiated',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final paths = <String>[];
        server.listen((request) async {
          expect(request.headers.value('X-BB-Message-Association'), '1');
          paths.add(request.uri.path);
          if (negotiated) {
            request.response.headers.set('X-BB-Message-Association', '1');
          }
          final value = switch (request.uri.path) {
            '/conversations/10000002/messages' => {
              'items': [wire()],
              'next_position': 1,
              'has_more': false,
            },
            '/conversations' => {
              'items': [
                {
                  'peer_account': '10000002',
                  'display_name': 'b',
                  'last_message': wire(),
                  'last_activity_at': '2026-11-15T00:00:00Z',
                  'latest_position': 1,
                },
              ],
              'next_cursor': null,
            },
            '/messages/m/context' => {
              'items': [wire()],
              'anchor_message_id': 'm',
              'peer_account': '10000002',
              'range': {'start_position': 1, 'end_position': 1},
              'before_has_more': false,
              'after_has_more': false,
              'missing_positions': [],
              'missing_truncated': false,
              'reply_relations': 'unsupported',
            },
            '/operations/op' => {
              'operation_id': 'op',
              'kind': 'message',
              'status': 'succeeded',
              'message': wire(),
            },
            '/messages/attachments' => {
              ...wire(),
              'kind': 'attachment',
              'content': null,
              'attachment': {
                'media_id': 'media',
                'media_type': 'document',
                'filename': 'file.txt',
                'mime_type': 'text/plain',
                'byte_size': 4,
                'cover_media_id': null,
              },
            },
            _ => wire(),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(value));
          await request.response.close();
        });
        final api = ChatApiClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        const token = 'synthetic';
        final messages = [
          await api.sendMessage(
            token: token,
            targetAccount: '10000002',
            clientNonce: 'op',
            content: const [TextPart('same')],
          ),
          await api.sendAttachment(
            token: token,
            targetAccount: '10000002',
            clientNonce: 'op',
            mediaId: 'media',
          ),
          (await api.conversation(
            token: token,
            account: '10000002',
          )).items.single,
          (await api.conversations(token: token)).items.single.lastMessage,
          (await api.messageById(token: token, messageId: 'm'))!,
          (await api.messageContext(
            token: token,
            messageId: 'm',
          ))!.items.single,
          (await api.getOperation(token: token, operationId: 'op'))!.message!,
        ];
        expect(paths.length, 7);
        expect(
          messages.map((m) => m.operationId),
          everyElement(negotiated ? 'op' : isNull),
        );
      },
    );
  }

  test(
    'history association settles only existing account-owned plans',
    () async {
      final ledger = ChatLedger.inMemory();
      final message = ChatMessage.fromJson(wire());
      await ledger.observeMessageAssociations('10000001', [message]);
      expect(await ledger.operation('10000001', 'op'), isNull);
      await ledger.saveOperation(
        '10000001',
        const ChatOperationRecord(
          operationId: 'op',
          kind: 'message',
          targetAccount: '10000002',
          state: 'uncertain',
          sourceDigest: 'x',
          parts: [],
        ),
      );
      await ledger.observeMessageAssociations('10000001', [
        message,
      ], peerAccount: '10000002');
      expect((await ledger.operation('10000001', 'op'))!.state, 'succeeded');
      await expectLater(
        ledger.observeMessageAssociations('10000003', [message]),
        throwsFormatException,
      );
      expect(await ledger.operation('10000003', 'op'), isNull);
    },
  );
}
