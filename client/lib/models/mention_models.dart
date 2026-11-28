import 'chat_models.dart';

/// A page of server-owned unread chat alerts or mentions. Cursors are exclusive.
class ChatAlertPage<T, C extends Object> {
  const ChatAlertPage({required this.items, required this.nextCursor});

  final List<T> items;
  final C? nextCursor;

  factory ChatAlertPage.fromJson(
    Map<String, dynamic> json,
    T Function(Object?) readItem,
    bool Function(C) validCursor,
  ) {
    final Object? items = json['items'];
    final Object? cursor = json['next_cursor'];
    if (items is! List || !json.containsKey('next_cursor')) {
      throw const FormatException('invalid mention page');
    }
    if (cursor != null && (cursor is! C || !validCursor(cursor))) {
      throw const FormatException('invalid mention cursor');
    }
    return ChatAlertPage(
      items: List<T>.unmodifiable(items.map(readItem)),
      nextCursor: cursor as C?,
    );
  }

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) writeItem) =>
      <String, dynamic>{
        'items': items.map(writeItem).toList(),
        'next_cursor': nextCursor,
      };
}

bool isValidAlertConversationId(String id) =>
    groupConversationIdPattern.hasMatch(id) ||
    directConversationIdPattern.hasMatch(id);

class AlertCounts {
  const AlertCounts({required this.mentions, required this.replies});

  final int mentions;
  final int replies;

  factory AlertCounts.fromJson(Object? json) {
    if (json
        case {
          'unread_mention_count': final int mentions,
          'unread_reply_count': final int replies,
        }
        when mentions >= 0 && replies >= 0) {
      return AlertCounts(mentions: mentions, replies: replies);
    }
    throw const FormatException('invalid alert counts');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'unread_mention_count': mentions,
    'unread_reply_count': replies,
  };
}

class UnreadChatAlert {
  const UnreadChatAlert({
    required this.messageId,
    required this.position,
    required this.mention,
    required this.reply,
  });

  final String messageId;
  final int position;
  final bool mention;
  final bool reply;

  factory UnreadChatAlert.fromJson(Object? json) {
    if (json
        case {
          'message_id': final String id,
          'position': final int position,
          'mention': final bool mention,
          'reply': final bool reply,
        }
        when _messageIdPattern.hasMatch(id) &&
            position > 0 &&
            (mention || reply)) {
      return UnreadChatAlert(
        messageId: id,
        position: position,
        mention: mention,
        reply: reply,
      );
    }
    throw const FormatException('invalid unread chat alert');
  }
}

class ChatAlertSummary {
  const ChatAlertSummary({
    required this.conversationId,
    required this.displayName,
    required this.counts,
    required this.latestAlert,
  });

  final String conversationId;
  final String displayName;
  final AlertCounts counts;
  final UnreadChatAlert latestAlert;

  factory ChatAlertSummary.fromJson(Object? json) {
    if (json
        case {
          'conversation_id': final String id,
          'display_name': final String name,
          'latest_alert': final Object? alert,
        }
        when isValidAlertConversationId(id)) {
      return ChatAlertSummary(
        conversationId: id,
        displayName: name,
        counts: AlertCounts.fromJson(json),
        latestAlert: UnreadChatAlert.fromJson(alert),
      );
    }
    throw const FormatException('invalid chat alert summary');
  }

  /// MCP summary intentionally contains only the conversation and counts.
  Map<String, dynamic> toToolJson() => <String, dynamic>{
    'conversation_id': conversationId,
    'display_name': displayName,
    ...counts.toJson(),
  };
}

final RegExp _messageIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,200}$');

class MentionMessage {
  const MentionMessage({
    required this.messageId,
    required this.position,
    required this.senderAccount,
    required this.senderUsername,
    required this.createdAt,
    required this.content,
  });

  final String messageId;
  final int position;
  final String senderAccount;
  final String senderUsername;
  final String createdAt;
  final List<MessagePart> content;

  factory MentionMessage.fromJson(Object? json) {
    if (json
        case {
          'message_id': final String id,
          'position': final int position,
          'sender_account': final String account,
          'sender_username': final String username,
          'created_at': final String createdAt,
          'content': final List<dynamic> content,
        }
        when _messageIdPattern.hasMatch(id) &&
            position > 0 &&
            isValidAccount(account)) {
      return MentionMessage(
        messageId: id,
        position: position,
        senderAccount: account,
        senderUsername: username,
        createdAt: createdAt,
        content: List<MessagePart>.unmodifiable(
          content.map((Object? part) {
            return MessagePart.fromJson(part) ??
                (throw const FormatException('invalid mention content'));
          }),
        ),
      );
    }
    throw const FormatException('invalid mention details');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'position': position,
    'sender_account': senderAccount,
    'sender_username': senderUsername,
    'created_at': createdAt,
    'content': content.map((MessagePart part) => part.toJson()).toList(),
  };
}
