// Baseline parser/serialization evidence, not a production change.
// dart docs/contracts/dea475-operation-association-evidence/legacy_parser_probe.dart
import '../../../client/lib/models/chat_models.dart';

void main() {
  final wire = <String, dynamic>{
    'id': 'synthetic-message',
    'position': 1,
    'sender_account': '10000001',
    'target_account': '10000002',
    'created_at': '2026-11-15T00:00:00Z',
    'kind': 'body',
    'content': [<String, dynamic>{'type': 'text', 'text': 'same'}],
    'operation_id': 'synthetic-operation',
  };
  final message = ChatMessage.fromJson(wire);
  if (message.id != wire['id'] || messageToJson(message).containsKey('operation_id')) {
    throw StateError('Baseline parser behavior changed');
  }
  print('PASS baseline Dart accepts unknown operation_id and drops it on serialization');
}
