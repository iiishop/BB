/// Ordered media entries of one conversation, used by the full-screen viewer.
///
/// A conversation's images can live in a body message (`ImagePart`) while
/// videos live in independent attachment messages. The viewer needs both in
/// one sequence, ordered by the message position and then by the position of
/// the image inside that message.
library;

import 'chat_models.dart';

enum ChatMediaKind {
  image,
  video;

  bool get isVideo => this == ChatMediaKind.video;
}

/// One image/video slot in a conversation.
class ChatMediaItem {
  const ChatMediaItem({
    required this.message,
    required this.kind,
    required this.mediaId,
    required this.senderLabel,
    this.partIndex,
    this.coverMediaId,
    this.byteSize,
    this.filename,
    this.mimeType,
  });

  final ChatMessage message;
  final ChatMediaKind kind;

  /// Original media id; this is what save and "原图" fetch.
  final String mediaId;

  /// Display name of the sender ("我" or the peer's username).
  final String senderLabel;

  /// Index of the `ImagePart` inside a body message; null for attachments.
  final int? partIndex;

  /// Cover image of a video attachment, never the video original.
  final String? coverMediaId;

  /// Known original size for attachment messages; body images omit it until
  /// the shared message contract exposes per-image metadata.
  final int? byteSize;

  final String? filename;
  final String? mimeType;

  DateTime get createdAt => message.createdAt;

  bool get isVideo => kind.isVideo;

  /// Stable identity for page keys and reload lookups.
  String get key => '${message.id}:${partIndex ?? 'attachment'}';

  ChatMediaItem copyWith({int? byteSize}) {
    return ChatMediaItem(
      message: message,
      kind: kind,
      mediaId: mediaId,
      senderLabel: senderLabel,
      partIndex: partIndex,
      coverMediaId: coverMediaId,
      byteSize: byteSize ?? this.byteSize,
      filename: filename,
      mimeType: mimeType,
    );
  }
}

/// Flattens a conversation into the viewer sequence.
///
/// Messages are sorted by `position` (the server's stable order) and image
/// parts keep their order inside a message. Only images and videos are
/// included; other attachments stay in the bubble list.
List<ChatMediaItem> buildConversationMedia({
  required List<ChatMessage> messages,
  required String selfAccount,
  required String selfName,
  required String peerName,
}) {
  final List<ChatMessage> sorted = List<ChatMessage>.from(messages)
    ..sort((ChatMessage a, ChatMessage b) => a.position.compareTo(b.position));
  final List<ChatMediaItem> items = <ChatMediaItem>[];
  for (final ChatMessage message in sorted) {
    final String sender = message.senderAccount == selfAccount
        ? selfName
        : peerName;
    final Attachment? attachment = message.attachment;
    if (message.kind == ChatMessageKind.attachment && attachment != null) {
      final ChatMediaKind? kind = switch (attachment.kind) {
        AttachmentKind.image => ChatMediaKind.image,
        AttachmentKind.video => ChatMediaKind.video,
        _ => null,
      };
      if (kind != null) {
        items.add(
          ChatMediaItem(
            message: message,
            kind: kind,
            mediaId: attachment.mediaId,
            senderLabel: sender,
            coverMediaId: attachment.coverMediaId,
            byteSize: attachment.byteSize,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
          ),
        );
      }
      continue;
    }
    if (message.kind != ChatMessageKind.body) {
      continue;
    }
    for (int index = 0; index < message.parts.length; index += 1) {
      final MessagePart part = message.parts[index];
      if (part is! ImagePart) {
        continue;
      }
      items.add(
        ChatMediaItem(
          message: message,
          kind: ChatMediaKind.image,
          mediaId: part.mediaId,
          senderLabel: sender,
          partIndex: index,
        ),
      );
    }
  }
  return List<ChatMediaItem>.unmodifiable(items);
}

/// Index of [messageId] + [partIndex] in [items], or -1.
int findConversationMediaIndex(
  List<ChatMediaItem> items, {
  required String messageId,
  int? partIndex,
}) {
  final String key = '$messageId:${partIndex ?? 'attachment'}';
  for (int index = 0; index < items.length; index += 1) {
    if (items[index].key == key) {
      return index;
    }
  }
  return -1;
}
