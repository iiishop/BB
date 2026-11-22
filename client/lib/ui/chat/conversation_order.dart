import '../../models/chat_models.dart';

/// Ordering policy for the signed-in conversation list.
///
/// Rows with a last message sort by that message's creation time, newest
/// first, whoever sent it: `last_contact_at` comes from the pair's latest
/// persisted message, so a message received from a peer and one sent by the
/// current account are compared on the same clock. Opening a conversation
/// writes no message and therefore never changes this key.
///
/// Accounts that have never exchanged a message keep their deterministic
/// account order after the active conversations. Account is also the tie-break
/// for equal timestamps, so a refresh can only reorder rows when a message
/// time actually changed.
int compareChatUsersByLastMessage(ChatUser a, ChatUser b) {
  final DateTime? aAt = a.lastContactAt;
  final DateTime? bAt = b.lastContactAt;
  if (aAt != null && bAt != null) {
    final int byTime = bAt.compareTo(aAt);
    if (byTime != 0) {
      return byTime;
    }
  } else if (aAt != null) {
    return -1;
  } else if (bAt != null) {
    return 1;
  }
  return a.account.compareTo(b.account);
}

/// Returns a new list in [_compareChatUsersByLastMessage] order.
List<ChatUser> sortChatUsersByLastMessage(Iterable<ChatUser> users) {
  return users.toList()..sort(compareChatUsersByLastMessage);
}
