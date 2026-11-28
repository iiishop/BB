import 'chat_models.dart';
import 'mention_models.dart';

class ReplyPage<T> {
  const ReplyPage({required this.items, required this.nextCursor});

  final List<T> items;
  final int? nextCursor;

  factory ReplyPage.fromJson(Object? json, T Function(Object?) decode) {
    if (json is! Map<String, dynamic> || json['items'] is! List) {
      throw const FormatException('invalid reply page');
    }
    final Object? cursor = json['next_cursor'];
    if (!json.containsKey('next_cursor') ||
        (cursor != null &&
            (cursor is! int || !isValidPositivePosition(cursor)))) {
      throw const FormatException('invalid reply cursor');
    }
    return ReplyPage(
      items: List<T>.unmodifiable((json['items'] as List).map(decode)),
      nextCursor: cursor as int?,
    );
  }

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) encode) => {
    'items': items.map(encode).toList(),
    'next_cursor': nextCursor,
  };
}

/// A direct reply item returned by `/chat/replies/unread` and `/chat/replies/direct`.
///
/// Mirrors `ReplyMessage` in `server/contract/src/bb_auth_contract/replies.py`:
/// conversation scope comes from the request, so `target_account` and
/// `conversation` are omitted while `sender_username` is always present.
class ReplyMessage {
  const ReplyMessage({
    required this.id,
    required this.position,
    required this.senderAccount,
    required this.senderUsername,
    required this.createdAt,
    required this.kind,
    this.parts = const <MessagePart>[],
    this.attachment,
    this.replyTo,
  });

  final String id;
  final int position;
  final String senderAccount;
  final String senderUsername;
  final DateTime createdAt;
  final ChatMessageKind kind;
  final List<MessagePart> parts;
  final Attachment? attachment;
  final ReplyQuote? replyTo;

  factory ReplyMessage.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('reply must be an object');
    }
    final Object? id = json['id'];
    final Object? position = json['position'];
    final Object? sender = json['sender_account'];
    final Object? senderUsername = json['sender_username'];
    final Object? createdAt = json['created_at'];
    final ChatMessageKind? kind = ChatMessageKind.tryParse(json['kind']);
    if (id is! String ||
        position is! int ||
        sender is! String ||
        !isValidAccount(sender) ||
        senderUsername is! String ||
        createdAt is! String ||
        kind == null ||
        kind == ChatMessageKind.system) {
      throw const FormatException('reply has invalid fields');
    }
    final DateTime? parsedTime = DateTime.tryParse(createdAt);
    if (parsedTime == null) {
      throw const FormatException('reply has invalid created_at');
    }
    final ({List<MessagePart> parts, Attachment? attachment}) body =
        parseMessageContentAndAttachment(json, kind);
    final ReplyQuote? replyTo = json['reply_to'] == null
        ? null
        : ReplyQuote.fromJson(json['reply_to']);
    return ReplyMessage(
      id: id,
      position: position,
      senderAccount: sender,
      senderUsername: senderUsername,
      createdAt: parsedTime.toUtc(),
      kind: kind,
      parts: body.parts,
      attachment: body.attachment,
      replyTo: replyTo,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'position': position,
    'sender_account': senderAccount,
    'sender_username': senderUsername,
    'created_at': createdAt.toUtc().toIso8601String(),
    'kind': kind.wire,
    'content': kind == ChatMessageKind.body
        ? parts.map((MessagePart part) => part.toJson()).toList()
        : null,
    'attachment': attachment?.toJson(),
    if (replyTo != null) 'reply_to': replyTo!.toJson(),
  };
}

/// One unread reply paired with its original message from `/chat/replies/unread`.
class UnreadReply {
  const UnreadReply({required this.reply, required this.original});

  final ReplyMessage reply;
  final ChatMessage original;

  factory UnreadReply.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('unread reply must be an object');
    }
    return UnreadReply(
      reply: ReplyMessage.fromJson(json['reply']),
      original: ChatMessage.fromJson(json['original']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'reply': reply.toJson(),
    'original': messageToJson(original),
  };
}
