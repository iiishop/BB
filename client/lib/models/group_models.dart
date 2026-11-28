/// Pure-Dart DTOs for group management, user directory, and general notices.
///
/// Mirrors `server/contract/src/bb_auth_contract/group.py`.
library;

import 'chat_models.dart';

final RegExp opaqueIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,200}$');
final RegExp operationIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

enum GroupStatus {
  active,
  dissolved;

  static GroupStatus? tryParse(Object? value) {
    return switch (value) {
      'active' => GroupStatus.active,
      'dissolved' => GroupStatus.dissolved,
      _ => null,
    };
  }

  String get wire => name;
}

enum GroupRole {
  owner,
  member;

  static GroupRole? tryParse(Object? value) {
    return switch (value) {
      'owner' => GroupRole.owner,
      'member' => GroupRole.member,
      _ => null,
    };
  }

  String get wire => name;
}

/// Transactional group snapshot order from the authenticated HTTP response.
class GroupProfileRevision implements Comparable<GroupProfileRevision> {
  const GroupProfileRevision._(this.membership, this.profile, this.invites);

  static final _wirePattern = RegExp(r'^[0-9]+\.[1-9][0-9]*\.[0-9]+$');

  factory GroupProfileRevision.parse(String header) {
    if (!_wirePattern.hasMatch(header)) {
      throw const FormatException('invalid group profile revision');
    }
    final parts = header.split('.').map(int.tryParse).toList();
    if (parts.any((part) => part == null || part < 0)) {
      throw const FormatException('invalid group profile revision');
    }
    return GroupProfileRevision._(parts[0]!, parts[1]!, parts[2]!);
  }

  final int membership;
  final int profile;
  final int invites;

  @override
  int compareTo(GroupProfileRevision other) {
    final byMembership = membership.compareTo(other.membership);
    if (byMembership != 0) return byMembership;
    final byProfile = profile.compareTo(other.profile);
    if (byProfile != 0) return byProfile;
    return invites.compareTo(other.invites);
  }
}

class GroupProfile {
  const GroupProfile({
    required this.conversation,
    required this.groupNumber,
    required this.name,
    required this.description,
    required this.avatarUrl,
    required this.avatarVersion,
    required this.status,
    this.role,
    this.canInvite = false,
    this.allowMemberInvites,
    this.revision,
  });

  final ConversationRef conversation;
  final String groupNumber;
  final String name;
  final String description;
  final String avatarUrl;
  final String avatarVersion;
  final GroupStatus status;
  final GroupProfileRevision? revision;

  /// Viewer-relative role: null for non-members.
  final GroupRole? role;
  final bool canInvite;
  final bool? allowMemberInvites;

  bool get isActive => status == GroupStatus.active;

  bool get isDissolved => status == GroupStatus.dissolved;

  bool get isOwner => role == GroupRole.owner;

  bool get isMember => role != null;

  bool get canEdit => isActive && isOwner;

  bool get canRemoveMember => isActive && isOwner;

  bool get canDissolve => isActive && isOwner;

  bool get canLeave => isActive && role == GroupRole.member;

  bool get canApply => isActive && role == null;

  factory GroupProfile.fromJson(
    Object? json, {
    GroupProfileRevision? revision,
  }) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('group profile must be an object');
    }
    final ConversationRef conversation = ConversationRef.fromJson(
      json['conversation'],
      requireGroup: true,
    );
    final Object? groupNumber = json['group_number'];
    final Object? name = json['name'];
    final Object? description = json['description'];
    final Object? avatarUrl = json['avatar_url'];
    final Object? avatarVersion = json['avatar_version'];
    final GroupStatus? status = GroupStatus.tryParse(json['status']);
    final Object? rawRole = json['role'];
    final GroupRole? role = rawRole == null
        ? null
        : GroupRole.tryParse(rawRole);
    final Object? canInvite = json['can_invite'] ?? false;
    final Object? allowMemberInvites = json['allow_member_invites'];
    if (groupNumber is! String ||
        !isValidGroupNumber(groupNumber) ||
        name is! String ||
        name.trim().isEmpty ||
        description is! String ||
        avatarUrl is! String ||
        avatarVersion is! String ||
        status == null ||
        (rawRole != null && role == null) ||
        canInvite is! bool ||
        (allowMemberInvites != null && allowMemberInvites is! bool)) {
      throw const FormatException('group profile has invalid fields');
    }
    return GroupProfile(
      conversation: conversation,
      groupNumber: groupNumber,
      name: name,
      description: description,
      avatarUrl: avatarUrl,
      avatarVersion: avatarVersion,
      status: status,
      role: role,
      canInvite: canInvite,
      allowMemberInvites: allowMemberInvites as bool?,
      revision: revision,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'conversation': conversation.toJson(),
    'group_number': groupNumber,
    'name': name,
    'description': description,
    'avatar_url': avatarUrl,
    'avatar_version': avatarVersion,
    'status': status.wire,
    'role': role?.wire,
    'can_invite': canInvite,
    'allow_member_invites': allowMemberInvites,
  };
}

class DirectoryUser {
  const DirectoryUser({
    required this.account,
    required this.username,
    required this.avatarUrl,
    required this.avatarVersion,
    required this.presence,
  });

  final String account;
  final String username;
  final String avatarUrl;
  final String avatarVersion;
  final Presence presence;

  factory DirectoryUser.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('directory user must be an object');
    }
    final Object? account = json['account'];
    final Object? username = json['username'];
    final Object? avatarUrl = json['avatar_url'];
    final Object? avatarVersion = json['avatar_version'];
    final Object? presence = json['presence'];
    if (account is! String ||
        !isValidAccount(account) ||
        username is! String ||
        avatarUrl is! String ||
        avatarVersion is! String ||
        (presence != 'online' && presence != 'offline')) {
      throw const FormatException('directory user has invalid fields');
    }
    return DirectoryUser(
      account: account,
      username: username,
      avatarUrl: avatarUrl,
      avatarVersion: avatarVersion,
      presence: Presence.tryParse(presence),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
    'avatar_url': avatarUrl,
    'avatar_version': avatarVersion,
    'presence': presence.wire,
  };
}

class DirectoryPage {
  const DirectoryPage({required this.items, this.nextCursor});

  final List<DirectoryUser> items;
  final String? nextCursor;

  factory DirectoryPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        (json['next_cursor'] != null && json['next_cursor'] is! String)) {
      throw const FormatException('directory page has invalid fields');
    }
    final String? cursor = json['next_cursor'] as String?;
    return DirectoryPage(
      items: List<DirectoryUser>.unmodifiable(
        (json['items'] as List<dynamic>).map(DirectoryUser.fromJson),
      ),
      nextCursor: cursor == null || cursor.isEmpty ? null : cursor,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((DirectoryUser user) => user.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}

class GroupMember {
  const GroupMember({
    required this.account,
    required this.username,
    required this.avatarUrl,
    required this.avatarVersion,
    required this.presence,
    required this.role,
  });

  final String account;
  final String username;
  final String avatarUrl;
  final String avatarVersion;
  final Presence presence;
  final GroupRole role;

  bool get isOwner => role == GroupRole.owner;

  factory GroupMember.fromJson(Object? json) {
    final DirectoryUser base = DirectoryUser.fromJson(json);
    final GroupRole? role = GroupRole.tryParse(
      (json as Map<String, dynamic>)['role'],
    );
    if (role == null) {
      throw const FormatException('group member has invalid role');
    }
    return GroupMember(
      account: base.account,
      username: base.username,
      avatarUrl: base.avatarUrl,
      avatarVersion: base.avatarVersion,
      presence: base.presence,
      role: role,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
    'avatar_url': avatarUrl,
    'avatar_version': avatarVersion,
    'presence': presence.wire,
    'role': role.wire,
  };
}

class GroupMemberPage {
  const GroupMemberPage({required this.items, this.nextCursor});

  final List<GroupMember> items;
  final String? nextCursor;

  factory GroupMemberPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        (json['next_cursor'] != null && json['next_cursor'] is! String)) {
      throw const FormatException('group member page has invalid fields');
    }
    final String? cursor = json['next_cursor'] as String?;
    return GroupMemberPage(
      items: List<GroupMember>.unmodifiable(
        (json['items'] as List<dynamic>).map(GroupMember.fromJson),
      ),
      nextCursor: cursor == null || cursor.isEmpty ? null : cursor,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((GroupMember member) => member.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}

class GroupRequestsResult {
  const GroupRequestsResult({required this.requestIds});

  final List<String> requestIds;

  factory GroupRequestsResult.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['request_ids'] is! List) {
      throw const FormatException('group requests must be an object');
    }
    final List<String> ids = <String>[];
    for (final Object? value in json['request_ids'] as List<dynamic>) {
      if (value is! String || !opaqueIdPattern.hasMatch(value)) {
        throw const FormatException('group request id is invalid');
      }
      ids.add(value);
    }
    return GroupRequestsResult(requestIds: List<String>.unmodifiable(ids));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{'request_ids': requestIds};
}

enum NoticeState {
  informational,
  pending,
  processed,
  invalidated;

  static NoticeState? tryParse(Object? value) {
    return switch (value) {
      'informational' => NoticeState.informational,
      'pending' => NoticeState.pending,
      'processed' => NoticeState.processed,
      'invalidated' => NoticeState.invalidated,
      _ => null,
    };
  }

  String get wire => name;
}

enum NoticeFilter {
  all,
  pending;

  static NoticeFilter? tryParse(Object? value) {
    return switch (value) {
      'all' => NoticeFilter.all,
      'pending' => NoticeFilter.pending,
      _ => null,
    };
  }

  String get wire => name;
}

class NoticeAction {
  const NoticeAction({
    required this.id,
    required this.label,
    required this.available,
  });

  final String id;
  final String label;
  final bool available;

  factory NoticeAction.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('notice action must be an object');
    }
    final Object? id = json['id'];
    final Object? label = json['label'];
    final Object? available = json['available'];
    if (id is! String ||
        !opaqueIdPattern.hasMatch(id) ||
        label is! String ||
        available is! bool) {
      throw const FormatException('notice action has invalid fields');
    }
    return NoticeAction(id: id, label: label, available: available);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'label': label,
    'available': available,
  };
}

class NoticeLink {
  const NoticeLink({required this.type, required this.id});

  final String type;
  final String id;

  bool get isGroup => type == 'group' && isValidGroupNumber(id);

  factory NoticeLink.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('notice link must be an object');
    }
    final Object? type = json['type'];
    final Object? id = json['id'];
    if (type is! String ||
        !opaqueIdPattern.hasMatch(type) ||
        id is! String ||
        !opaqueIdPattern.hasMatch(id)) {
      throw const FormatException('notice link has invalid fields');
    }
    return NoticeLink(type: type, id: id);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{'type': type, 'id': id};
}

class Notice {
  const Notice({
    required this.id,
    required this.type,
    required this.title,
    required this.text,
    required this.createdAt,
    required this.read,
    required this.state,
    required this.actions,
    this.link,
  });

  final String id;
  final String type;
  final String title;
  final String text;
  final DateTime createdAt;
  final bool read;
  final NoticeState state;
  final List<NoticeAction> actions;
  final NoticeLink? link;

  bool get isPending => state == NoticeState.pending;

  bool get isInvalidated => state == NoticeState.invalidated;

  bool get hasAvailableActions =>
      state == NoticeState.pending &&
      actions.any((NoticeAction action) => action.available);

  factory Notice.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('notice must be an object');
    }
    final Object? id = json['id'];
    final Object? type = json['type'];
    final Object? title = json['title'];
    final Object? text = json['text'];
    final Object? createdAt = json['created_at'];
    final Object? read = json['read'];
    final NoticeState? state = NoticeState.tryParse(json['state']);
    final Object? rawActions = json['actions'];
    if (id is! String ||
        !opaqueIdPattern.hasMatch(id) ||
        type is! String ||
        !opaqueIdPattern.hasMatch(type) ||
        title is! String ||
        text is! String ||
        createdAt is! String ||
        read is! bool ||
        state == null ||
        rawActions is! List) {
      throw const FormatException('notice has invalid fields');
    }
    final DateTime? parsedAt = DateTime.tryParse(createdAt);
    if (parsedAt == null) {
      throw const FormatException('notice created_at is invalid');
    }
    return Notice(
      id: id,
      type: type,
      title: title,
      text: text,
      createdAt: parsedAt.toUtc(),
      read: read,
      state: state,
      actions: List<NoticeAction>.unmodifiable(
        rawActions.map(NoticeAction.fromJson),
      ),
      link: json['link'] == null ? null : NoticeLink.fromJson(json['link']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'type': type,
    'title': title,
    'text': text,
    'created_at': createdAt.toIso8601String(),
    'read': read,
    'state': state.wire,
    'actions': actions.map((NoticeAction action) => action.toJson()).toList(),
    'link': link?.toJson(),
  };
}

class NoticePage {
  const NoticePage({
    required this.items,
    required this.unreadCount,
    required this.pendingCount,
    this.nextCursor,
  });

  final List<Notice> items;
  final String? nextCursor;
  final int unreadCount;
  final int pendingCount;

  factory NoticePage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        (json['next_cursor'] != null && json['next_cursor'] is! String) ||
        json['unread_count'] is! int ||
        (json['unread_count'] as int) < 0 ||
        json['pending_count'] is! int ||
        (json['pending_count'] as int) < 0) {
      throw const FormatException('notice page has invalid fields');
    }
    final String? cursor = json['next_cursor'] as String?;
    return NoticePage(
      items: List<Notice>.unmodifiable(
        (json['items'] as List<dynamic>).map(Notice.fromJson),
      ),
      nextCursor: cursor == null || cursor.isEmpty ? null : cursor,
      unreadCount: json['unread_count'] as int,
      pendingCount: json['pending_count'] as int,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((Notice item) => item.toJson()).toList(),
    'next_cursor': nextCursor,
    'unread_count': unreadCount,
    'pending_count': pendingCount,
  };
}

class GroupAvatarBytes {
  const GroupAvatarBytes({required this.base64, required this.mimeType});

  final String base64;
  final String mimeType;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'base64': base64,
    'mime_type': mimeType,
  };
}

class GroupAvatarImage {
  const GroupAvatarImage({
    required this.groupNumber,
    required this.bytes,
    required this.version,
  });

  final String groupNumber;
  final List<int> bytes;
  final String version;
}
