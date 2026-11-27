/// Shared conversation addressing and shared conversation list models.
///
/// Mirrors `server/contract/src/bb_auth_contract/conversation.py` and the
/// shared conversation summary types in `chat_query.py`.
library;

import 'chat_models.dart';

final RegExp accountPattern = RegExp(r'^[1-9][0-9]{7}$');
final RegExp groupNumberPattern = RegExp(r'^[1-9][0-9]{7}$');
final RegExp groupConversationIdPattern = RegExp(r'^group:[a-f0-9]{32}$');
final RegExp directConversationIdPattern = RegExp(
  r'^dm:([1-9][0-9]{7}):([1-9][0-9]{7})$',
);

bool isValidAccount(String value) => accountPattern.hasMatch(value);

bool isValidGroupNumber(String value) => groupNumberPattern.hasMatch(value);

bool isValidGroupConversationId(String value) =>
    groupConversationIdPattern.hasMatch(value);

enum ConversationType {
  direct,
  group;

  static ConversationType? tryParse(Object? value) {
    return switch (value) {
      'direct' => ConversationType.direct,
      'group' => ConversationType.group,
      _ => null,
    };
  }

  String get wire => name;
}

/// Canonical address of either a 1:1 direct conversation (`dm:<low>:<high>`)
/// or a group conversation (`group:<32 lowercase hex>`).
class ConversationRef {
  const ConversationRef._({required this.type, required this.id});

  factory ConversationRef.direct(String first, String second) {
    if (!isValidAccount(first) || !isValidAccount(second) || first == second) {
      throw const FormatException(
        'direct conversation requires two distinct 8-digit accounts',
      );
    }
    final List<String> pair = <String>[first, second]..sort();
    return ConversationRef._(
      type: ConversationType.direct,
      id: 'dm:${pair[0]}:${pair[1]}',
    );
  }

  factory ConversationRef.group(String id) {
    if (!isValidGroupConversationId(id)) {
      throw const FormatException('invalid group conversation id');
    }
    return ConversationRef._(type: ConversationType.group, id: id);
  }

  factory ConversationRef.parseId(String id) {
    if (id.startsWith('group:')) {
      return ConversationRef.group(id);
    }
    final Match? match = directConversationIdPattern.firstMatch(id);
    if (match != null) {
      final String low = match.group(1)!;
      final String high = match.group(2)!;
      if (low.compareTo(high) >= 0) {
        throw const FormatException(
          'direct conversation requires sorted distinct accounts',
        );
      }
      return ConversationRef._(type: ConversationType.direct, id: id);
    }
    throw const FormatException('invalid conversation id');
  }

  factory ConversationRef.fromJson(Object? json, {bool requireGroup = false}) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('conversation must be an object');
    }
    final ConversationType? type = ConversationType.tryParse(json['type']);
    final Object? rawId = json['id'];
    if (type == null || rawId is! String) {
      throw const FormatException('conversation has invalid fields');
    }
    final ConversationRef parsed = ConversationRef.parseId(rawId);
    if (parsed.type != type) {
      throw const FormatException('conversation type does not match id');
    }
    if (requireGroup && parsed.type != ConversationType.group) {
      throw const FormatException('group conversation required');
    }
    return parsed;
  }

  final ConversationType type;
  final String id;

  bool get isGroup => type == ConversationType.group;

  bool get isDirect => type == ConversationType.direct;

  /// Returns the other participant for a direct conversation, or null.
  String? directPeerFor(String selfAccount) {
    if (!isDirect) {
      return null;
    }
    final Match? match = directConversationIdPattern.firstMatch(id);
    if (match == null) {
      return null;
    }
    final String low = match.group(1)!;
    final String high = match.group(2)!;
    if (low == selfAccount) {
      return high;
    }
    if (high == selfAccount) {
      return low;
    }
    return null;
  }

  bool containsDirectAccount(String account) {
    if (!isDirect) {
      return false;
    }
    final Match? match = directConversationIdPattern.firstMatch(id);
    if (match == null) {
      return false;
    }
    return match.group(1) == account || match.group(2) == account;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type.wire,
    'id': id,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationRef && type == other.type && id == other.id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => 'ConversationRef(${type.wire}:$id)';
}

/// Shared conversation item returned by `GET /chat/conversations`.
sealed class SharedConversation {
  const SharedConversation();

  ConversationRef get conversation;

  String get displayName;

  ChatMessage? get lastMessage;

  DateTime get lastActivityAt;

  int get latestPosition;

  factory SharedConversation.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('shared conversation must be an object');
    }
    final ConversationRef ref = ConversationRef.fromJson(json['conversation']);
    if (ref.isGroup) {
      return GroupConversationItem.fromJson(json);
    }
    return DirectConversationItem.fromJson(json);
  }
}

class DirectConversationItem extends SharedConversation {
  const DirectConversationItem({
    required this.conversation,
    required this.peerAccount,
    required this.lastMessage,
    required this.lastActivityAt,
    required this.latestPosition,
    this.rawDisplayName,
  });

  @override
  final ConversationRef conversation;
  final String peerAccount;
  final String? rawDisplayName;

  @override
  final ChatMessage lastMessage;

  @override
  final DateTime lastActivityAt;

  @override
  final int latestPosition;

  @override
  String get displayName =>
      (rawDisplayName != null && rawDisplayName!.isNotEmpty)
      ? rawDisplayName!
      : peerAccount;

  factory DirectConversationItem.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('direct conversation must be an object');
    }
    final ConversationRef conversation = ConversationRef.fromJson(
      json['conversation'],
    );
    if (!conversation.isDirect) {
      throw const FormatException('expected direct conversation');
    }
    final Object? peer = json['peer_account'];
    final Object? last = json['last_message'];
    final Object? activity = json['last_activity_at'];
    final Object? latest = json['latest_position'];
    final Object? displayName = json['display_name'];
    if (peer is! String ||
        !isValidAccount(peer) ||
        last is! Map<String, dynamic> ||
        activity is! String ||
        latest is! int ||
        latest < 0 ||
        (displayName != null && displayName is! String)) {
      throw const FormatException('direct conversation has invalid fields');
    }
    final DateTime? at = DateTime.tryParse(activity);
    if (at == null) {
      throw const FormatException('direct conversation time is invalid');
    }
    return DirectConversationItem(
      conversation: conversation,
      peerAccount: peer,
      rawDisplayName: displayName as String?,
      lastMessage: ChatMessage.fromJson(last),
      lastActivityAt: at.toUtc(),
      latestPosition: latest,
    );
  }
}

class GroupConversationItem extends SharedConversation {
  const GroupConversationItem({
    required this.conversation,
    required this.groupNumber,
    required this.displayName,
    required this.lastMessage,
    required this.lastActivityAt,
    required this.latestPosition,
    required this.historyThrough,
    required this.membershipRevision,
    required this.avatarUrl,
    required this.avatarVersion,
  });

  @override
  final ConversationRef conversation;
  final String groupNumber;

  @override
  final String displayName;

  @override
  final ChatMessage? lastMessage;

  @override
  final DateTime lastActivityAt;

  @override
  final int latestPosition;
  final int historyThrough;
  final int membershipRevision;
  final String avatarUrl;
  final String avatarVersion;

  factory GroupConversationItem.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('group conversation must be an object');
    }
    final ConversationRef conversation = ConversationRef.fromJson(
      json['conversation'],
      requireGroup: true,
    );
    final Object? groupNumber = json['group_number'];
    final Object? displayName = json['display_name'];
    final Object? last = json['last_message'];
    final Object? activity = json['last_activity_at'];
    final Object? latest = json['latest_position'];
    final Object? historyThrough = json['history_through'];
    final Object? membershipRevision = json['membership_revision'];
    final Object? avatarUrl = json['avatar_url'];
    final Object? avatarVersion = json['avatar_version'];
    if (groupNumber is! String ||
        !isValidGroupNumber(groupNumber) ||
        displayName is! String ||
        activity is! String ||
        latest is! int ||
        latest < 0 ||
        historyThrough is! int ||
        historyThrough < 0 ||
        membershipRevision is! int ||
        membershipRevision < 1 ||
        avatarUrl is! String ||
        avatarVersion is! String ||
        (last != null && last is! Map<String, dynamic>)) {
      throw const FormatException('group conversation has invalid fields');
    }
    final DateTime? at = DateTime.tryParse(activity);
    if (at == null) {
      throw const FormatException('group conversation time is invalid');
    }
    return GroupConversationItem(
      conversation: conversation,
      groupNumber: groupNumber,
      displayName: displayName,
      lastMessage: last == null ? null : ChatMessage.fromJson(last),
      lastActivityAt: at.toUtc(),
      latestPosition: latest,
      historyThrough: historyThrough,
      membershipRevision: membershipRevision,
      avatarUrl: avatarUrl,
      avatarVersion: avatarVersion,
    );
  }
}

class SharedConversationPage {
  const SharedConversationPage({required this.items, required this.nextCursor});

  final List<SharedConversation> items;
  final String? nextCursor;

  factory SharedConversationPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        (json['next_cursor'] != null && json['next_cursor'] is! String)) {
      throw const FormatException(
        'shared conversation page has invalid fields',
      );
    }
    final String? cursor = json['next_cursor'] as String?;
    return SharedConversationPage(
      items: List<SharedConversation>.unmodifiable(
        (json['items'] as List<dynamic>).map(SharedConversation.fromJson),
      ),
      nextCursor: cursor == null || cursor.isEmpty ? null : cursor,
    );
  }
}
