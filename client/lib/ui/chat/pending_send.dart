import 'package:flutter/foundation.dart';

import '../../models/chat_models.dart';

/// Local presentation state of a message that is still on its way to the
/// server.
///
/// This is deliberately UI-only: it never claims the server accepted anything
/// and it is dropped as soon as the durable operation replaces it. Retry keeps
/// the original operation id, so the ledger's idempotency rules are unchanged.
enum SendFeedbackState { sending, failed }

/// One local bubble for an outgoing item that has not settled yet.
@immutable
class PendingSend {
  const PendingSend({
    required this.operationId,
    required this.message,
    required this.state,
    this.imageBytes = const <String, Uint8List>{},
  });

  /// Stable id reused for every retry (`seed-b`, `seed-aN`).
  final String operationId;

  /// Synthetic message rendered with the normal bubble. Its media ids are
  /// local (`pending:...`) and only [imageBytes] can resolve them.
  final ChatMessage message;

  final SendFeedbackState state;

  /// Local bytes for body images and video covers that have not been uploaded.
  final Map<String, Uint8List> imageBytes;

  PendingSend copyWith({SendFeedbackState? state}) {
    return PendingSend(
      operationId: operationId,
      message: message,
      state: state ?? this.state,
      imageBytes: imageBytes,
    );
  }
}

/// A committed message tied to the operation id that produced it.
///
/// The chat page keys the bubble with this id so the local "sending" bubble
/// and its committed replacement are one element: the status line changes,
/// but the bubble does not re-enter and the list does not jump.
@immutable
class SentOperation {
  const SentOperation({required this.operationId, required this.message});

  final String operationId;
  final ChatMessage message;
}
