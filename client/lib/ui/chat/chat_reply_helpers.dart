import '../../models/chat_models.dart';

/// Display label for the original author in a reply quote or composer bar.
String replyQuoteAuthorLabel(ReplyQuote quote, String selfAccount) {
  final String? account = quote.senderAccount;
  if (account != null && account.isNotEmpty && account == selfAccount) {
    return '我';
  }
  final String? username = quote.senderUsername;
  if (username != null && username.isNotEmpty) {
    return username;
  }
  if (account != null && account.isNotEmpty) {
    return account;
  }
  return '系统消息';
}

/// Compact single-line preview summary for a message being quoted or previewed
/// in a menu / action sheet.
String messageQuotePreview(ChatMessage message) {
  if (message.isSystem) {
    final String text = (message.systemText ?? '').trim();
    return text.isEmpty ? '系统消息' : text.replaceAll(RegExp(r'\s+'), ' ');
  }
  if (message.kind == ChatMessageKind.attachment) {
    final Attachment? attachment = message.attachment;
    if (attachment == null) {
      return '[附件]';
    }
    return '${attachment.kind.previewLabel} ${attachment.filename}'.trim();
  }
  final List<String> segments = <String>[];
  bool hasImage = false;
  for (final MessagePart part in message.parts) {
    if (part is TextPart) {
      final String normalized = part.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (normalized.isNotEmpty) {
        segments.add(normalized);
      }
    } else if (part is ImagePart) {
      hasImage = true;
    }
  }
  if (segments.isEmpty) {
    return hasImage ? '[图片]' : '';
  }
  final String joined = segments.join(' ');
  return hasImage ? '$joined [图片]' : joined;
}

/// Builds a [ReplyQuote] snapshot from a committed timeline [ChatMessage].
ReplyQuote replyQuoteFromMessage(
  ChatMessage message, {
  required String fallbackAuthor,
}) {
  final bool system = message.isSystem;
  final String? account = system || message.senderAccount.isEmpty
      ? null
      : message.senderAccount;
  final String? username = system
      ? null
      : (message.senderUsername?.isNotEmpty == true
            ? message.senderUsername
            : (fallbackAuthor.isNotEmpty ? fallbackAuthor : account));
  return ReplyQuote(
    messageId: message.id,
    senderAccount: account,
    senderUsername: username,
    preview: messageQuotePreview(message),
  );
}

/// Plain body text eligible for "复制整条" (body text only; excludes quotes,
/// sender headers, and timestamps). Returns null when there is no body text.
String? copyableMessageBodyText(ChatMessage message) {
  if (message.isSystem || message.kind != ChatMessageKind.body) {
    return null;
  }
  final List<String> texts = <String>[
    for (final MessagePart part in message.parts)
      if (part is TextPart && part.text.isNotEmpty) part.text,
  ];
  if (texts.isEmpty) {
    return null;
  }
  return texts.join('\n');
}
