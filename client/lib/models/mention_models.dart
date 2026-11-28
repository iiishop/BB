/// Pure-Dart DTOs and validation for DEA-517 Revision 1 shared alerts and
/// group mentions.
///
/// Mirrors `server/contract/src/bb_auth_contract/chat_alerts.py`,
/// `server/contract/src/bb_auth_contract/mentions.py`, and `mentioned_accounts`
/// on `SendMessage` in `chat.py`.
library;

import 'auth_models.dart';
import 'chat_models.dart';

const int mentionMaxPositivePosition = 9007199254740991;
const int mentionDefaultPageLimit = 50;
const int mentionMaxPageLimit = 100;
const int mentionMaxRecipients = 100;

const String alertSummaryPath = '/chat/alerts/summary';
const String alertListPath = '/chat/alerts/list';
const String alertMarkSeenPath = '/chat/alerts/mark_seen';
const String mentionListPath = '/chat/mentions/list';

final RegExp mentionMessageIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,200}$');

bool isValidPositivePosition(int value) =>
    value >= 1 && value <= mentionMaxPositivePosition;

bool isValidAlertPosition(int value) =>
    value >= 0 && value <= mentionMaxPositivePosition;

bool isValidMentionMessageId(String value) =>
    mentionMessageIdPattern.hasMatch(value);

bool isValidConversationId(String value) {
  try {
    ConversationRef.parseId(value);
    return true;
  } on FormatException {
    return false;
  }
}

void validateMentionAccounts(
  List<String> mentionedAccounts, {
  required bool isGroup,
}) {
  if (mentionedAccounts.isEmpty) {
    return;
  }
  if (!isGroup) {
    throw const AuthFailure(
      status: 422,
      code: 'validation_error',
      message: '仅群聊消息支持提及成员',
    );
  }
  if (mentionedAccounts.length > mentionMaxRecipients) {
    throw const AuthFailure(
      status: 422,
      code: 'validation_error',
      message: '单条消息最多提及 100 名成员',
    );
  }
  final Set<String> seen = <String>{};
  for (final String account in mentionedAccounts) {
    if (!isValidAccount(account)) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '提及成员账号格式无效',
      );
    }
    if (!seen.add(account)) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '提及成员账号不能重复',
      );
    }
  }
}

/// Shared per-type unread counts (`unread_mention_count`, `unread_reply_count`).
class AlertCounts {
  const AlertCounts({
    required this.unreadMentionCount,
    required this.unreadReplyCount,
  });

  final int unreadMentionCount;
  final int unreadReplyCount;

  bool get hasAny => unreadMentionCount > 0 || unreadReplyCount > 0;

  factory AlertCounts.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('alert counts must be an object');
    }
    final Object? mentionCount = json['unread_mention_count'];
    final Object? replyCount = json['unread_reply_count'];
    if (mentionCount is! int ||
        !isValidAlertPosition(mentionCount) ||
        replyCount is! int ||
        !isValidAlertPosition(replyCount)) {
      throw const FormatException('alert counts have invalid fields');
    }
    return AlertCounts(
      unreadMentionCount: mentionCount,
      unreadReplyCount: replyCount,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'unread_mention_count': unreadMentionCount,
    'unread_reply_count': unreadReplyCount,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertCounts &&
          unreadMentionCount == other.unreadMentionCount &&
          unreadReplyCount == other.unreadReplyCount;

  @override
  int get hashCode => Object.hash(unreadMentionCount, unreadReplyCount);
}

/// One unread jump entry (`POST /chat/alerts/list` and `latest_alert`).
class UnreadAlert {
  const UnreadAlert({
    required this.messageId,
    required this.position,
    required this.mention,
    required this.reply,
  });

  final String messageId;
  final int position;
  final bool mention;
  final bool reply;

  factory UnreadAlert.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('unread alert must be an object');
    }
    final Object? messageId = json['message_id'];
    final Object? position = json['position'];
    final Object? mention = json['mention'];
    final Object? reply = json['reply'];
    if (messageId is! String ||
        !isValidMentionMessageId(messageId) ||
        position is! int ||
        !isValidPositivePosition(position) ||
        mention is! bool ||
        reply is! bool) {
      throw const FormatException('unread alert has invalid fields');
    }
    return UnreadAlert(
      messageId: messageId,
      position: position,
      mention: mention,
      reply: reply,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'position': position,
    'mention': mention,
    'reply': reply,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnreadAlert &&
          messageId == other.messageId &&
          position == other.position &&
          mention == other.mention &&
          reply == other.reply;

  @override
  int get hashCode => Object.hash(messageId, position, mention, reply);
}

/// Reverse-ordered page of unread alerts in one conversation.
class AlertPage {
  const AlertPage({required this.items, this.nextCursor});

  final List<UnreadAlert> items;
  final int? nextCursor;

  factory AlertPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['items'] is! List) {
      throw const FormatException('alert page must be an object');
    }
    final Object? cursor = json['next_cursor'];
    if (cursor != null &&
        (cursor is! int || !isValidPositivePosition(cursor))) {
      throw const FormatException('alert page cursor is invalid');
    }
    return AlertPage(
      items: List<UnreadAlert>.unmodifiable(
        (json['items'] as List<dynamic>).map(UnreadAlert.fromJson),
      ),
      nextCursor: cursor as int?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((UnreadAlert item) => item.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}

/// Client summary of unread mentions/replies for one conversation
/// (`POST /chat/alerts/summary`).
class ClientAlertSummary {
  const ClientAlertSummary({
    required this.conversationId,
    required this.displayName,
    required this.unreadMentionCount,
    required this.unreadReplyCount,
    required this.latestAlert,
  });

  final String conversationId;
  final String displayName;
  final int unreadMentionCount;
  final int unreadReplyCount;
  final UnreadAlert latestAlert;

  ConversationRef get conversation => ConversationRef.parseId(conversationId);

  AlertCounts get counts => AlertCounts(
    unreadMentionCount: unreadMentionCount,
    unreadReplyCount: unreadReplyCount,
  );

  bool get hasAny => unreadMentionCount > 0 || unreadReplyCount > 0;

  factory ClientAlertSummary.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('client alert summary must be an object');
    }
    final Object? conversationId = json['conversation_id'];
    final Object? displayName = json['display_name'];
    final AlertCounts counts = AlertCounts.fromJson(json);
    if (conversationId is! String ||
        !isValidConversationId(conversationId) ||
        displayName is! String) {
      throw const FormatException('client alert summary has invalid fields');
    }
    final UnreadAlert latestAlert = UnreadAlert.fromJson(json['latest_alert']);
    return ClientAlertSummary(
      conversationId: conversationId,
      displayName: displayName,
      unreadMentionCount: counts.unreadMentionCount,
      unreadReplyCount: counts.unreadReplyCount,
      latestAlert: latestAlert,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'conversation_id': conversationId,
    'display_name': displayName,
    'unread_mention_count': unreadMentionCount,
    'unread_reply_count': unreadReplyCount,
    'latest_alert': latestAlert.toJson(),
  };

  ClientAlertSummary copyWith({
    String? displayName,
    int? unreadMentionCount,
    int? unreadReplyCount,
    UnreadAlert? latestAlert,
  }) {
    return ClientAlertSummary(
      conversationId: conversationId,
      displayName: displayName ?? this.displayName,
      unreadMentionCount: unreadMentionCount ?? this.unreadMentionCount,
      unreadReplyCount: unreadReplyCount ?? this.unreadReplyCount,
      latestAlert: latestAlert ?? this.latestAlert,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientAlertSummary &&
          conversationId == other.conversationId &&
          displayName == other.displayName &&
          unreadMentionCount == other.unreadMentionCount &&
          unreadReplyCount == other.unreadReplyCount &&
          latestAlert == other.latestAlert;

  @override
  int get hashCode => Object.hash(
    conversationId,
    displayName,
    unreadMentionCount,
    unreadReplyCount,
    latestAlert,
  );
}

/// Keyset page of conversations that currently have unread alerts.
class ClientAlertSummaryPage {
  const ClientAlertSummaryPage({required this.items, this.nextCursor});

  final List<ClientAlertSummary> items;
  final String? nextCursor;

  factory ClientAlertSummaryPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['items'] is! List) {
      throw const FormatException('alert summary page must be an object');
    }
    final Object? cursor = json['next_cursor'];
    if (cursor != null &&
        (cursor is! String || !isValidConversationId(cursor))) {
      throw const FormatException('alert summary cursor is invalid');
    }
    return ClientAlertSummaryPage(
      items: List<ClientAlertSummary>.unmodifiable(
        (json['items'] as List<dynamic>).map(ClientAlertSummary.fromJson),
      ),
      nextCursor: cursor as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((ClientAlertSummary item) => item.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}

/// One unread mention entry returned by `POST /chat/mentions/list`.
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
  final DateTime createdAt;
  final List<MessagePart> content;

  factory MentionMessage.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('mention message must be an object');
    }
    final Object? messageId = json['message_id'];
    final Object? position = json['position'];
    final Object? senderAccount = json['sender_account'];
    final Object? senderUsername = json['sender_username'];
    final Object? createdAt = json['created_at'];
    final Object? rawContent = json['content'];
    if (messageId is! String ||
        !isValidMentionMessageId(messageId) ||
        position is! int ||
        !isValidPositivePosition(position) ||
        senderAccount is! String ||
        !isValidAccount(senderAccount) ||
        senderUsername is! String ||
        createdAt is! String ||
        rawContent is! List) {
      throw const FormatException('mention message has invalid fields');
    }
    final DateTime? timestamp = DateTime.tryParse(createdAt);
    if (timestamp == null) {
      throw const FormatException('mention message created_at is invalid');
    }
    final List<MessagePart> parts = <MessagePart>[];
    for (final Object? raw in rawContent) {
      final MessagePart? part = MessagePart.fromJson(raw);
      if (part == null || (part is TextPart && part.text.isEmpty)) {
        throw const FormatException('mention message has invalid content part');
      }
      parts.add(part);
    }
    return MentionMessage(
      messageId: messageId,
      position: position,
      senderAccount: senderAccount,
      senderUsername: senderUsername,
      createdAt: timestamp.toUtc(),
      content: List<MessagePart>.unmodifiable(parts),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message_id': messageId,
    'position': position,
    'sender_account': senderAccount,
    'sender_username': senderUsername,
    'created_at': createdAt.toIso8601String(),
    'content': content.map((MessagePart part) => part.toJson()).toList(),
  };
}

/// Reverse-ordered page of unread mentions in one group.
class MentionPage {
  const MentionPage({required this.items, this.nextCursor});

  final List<MentionMessage> items;
  final int? nextCursor;

  factory MentionPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['items'] is! List) {
      throw const FormatException('mention page must be an object');
    }
    final Object? cursor = json['next_cursor'];
    if (cursor != null &&
        (cursor is! int || !isValidPositivePosition(cursor))) {
      throw const FormatException('mention page cursor is invalid');
    }
    return MentionPage(
      items: List<MentionMessage>.unmodifiable(
        (json['items'] as List<dynamic>).map(MentionMessage.fromJson),
      ),
      nextCursor: cursor as int?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((MentionMessage item) => item.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}
