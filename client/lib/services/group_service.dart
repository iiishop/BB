/// Pure-Dart shared services for groups, directory, notices, and shared
/// conversation messaging/media caching with revocation support.
///
/// Consumed by both the Flutter UI and DEA-503's local control API (`chat_v2`)
/// without modifying `chat_service.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import '../models/group_models.dart';
import 'auth_session.dart';
import 'avatar_cache.dart';
import 'avatar_source.dart';
import 'chat_api_client.dart';
import 'client_identity.dart';
import 'conversation_access.dart';
import 'group_api_client.dart';
import 'install_safety_gate.dart';
import 'media_disk_cache.dart';
import 'media_source.dart';
import 'profile_api_client.dart';

/// Pure-Dart service for `group.REMOTE` operations, group avatar caching, and
/// general notice actions.
///
/// Group avatars live in their own [AvatarCacheStore] and use `'group-<number>'`
/// keys so a group number identical to a user's 8-digit account can never
/// collide with or overwrite a user's avatar cache.
class GroupService {
  GroupService({
    required this.api,
    required this.session,
    AvatarCacheStore? avatarCache,
    AvatarSourceReader? avatarSources,
    this.access,
  }) : avatarCache = avatarCache ?? AvatarCache(),
       avatarSources = avatarSources ?? DefaultAvatarSourceReader();

  final GroupApiClient api;
  final AuthSession session;
  final AvatarCacheStore avatarCache;
  final AvatarSourceReader avatarSources;
  final ConversationAccessController? access;

  String _token(AuthIdentity? captured) {
    if (captured != null) {
      if (!session.isCurrent(captured)) {
        throw staleIdentity;
      }
      return captured.token;
    }
    final AuthIdentity? current = session.identity;
    if (current == null) {
      throw unauthenticated;
    }
    return current.token;
  }

  AuthIdentity _requireIdentity(AuthIdentity? captured) {
    final AuthIdentity? current = session.identity;
    if (captured != null) {
      if (current == null || !captured.sameAs(current)) {
        throw staleIdentity;
      }
      return captured;
    }
    if (current == null) {
      throw unauthenticated;
    }
    return current;
  }

  void _ensureCurrent(AuthIdentity captured) {
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
  }

  Future<GroupProfile> createGroup({
    required String operationId,
    required String name,
    String description = '',
    List<String> invitees = const <String>[],
    MediaSource? avatar,
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(
    () => _createGroup(
      operationId: operationId,
      name: name,
      description: description,
      invitees: invitees,
      avatar: avatar,
      captured: captured,
    ),
  );

  Future<GroupProfile> _createGroup({
    required String operationId,
    required String name,
    required String description,
    required List<String> invitees,
    required MediaSource? avatar,
    required AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!operationIdPattern.hasMatch(operationId)) {
      throw _validation('operation_id', 'operation_id 无效');
    }
    final String normalizedName = _validateGroupName(name);
    final String normalizedDescription = _validateGroupDescription(description);
    if (invitees.length > 100) {
      throw _validation('invitees', '初始邀请对象不能超过 100 人');
    }
    for (final String account in invitees) {
      if (!isValidAccount(account)) {
        throw _validation('invitees', '邀请对象必须是 8 位 BB 号');
      }
    }
    final GroupAvatarBytes? avatarBytes = avatar == null
        ? null
        : await _resolveAvatarBytes(avatar);
    _ensureCurrent(identity);
    final GroupProfile profile = await api.createGroup(
      token: identity.token,
      operationId: operationId,
      name: normalizedName,
      description: normalizedDescription,
      invitees: invitees,
      avatar: avatarBytes,
    );
    _ensureCurrent(identity);
    access?.grant(
      identity.account,
      profile.conversation.id,
      membershipRevision: 1,
      historyThrough: 0,
    );
    return profile;
  }

  Future<GroupProfile> findGroup(
    String groupNumber, {
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!isValidGroupNumber(groupNumber)) {
      throw _validation('group_number', '群号必须是 8 位数字');
    }
    final GroupProfile profile = await api.findGroup(
      token: identity.token,
      groupNumber: groupNumber,
    );
    _ensureCurrent(identity);
    return profile;
  }

  /// Resolves a group profile from a [GroupConversationItem] returned by
  /// `GET /chat/conversations`, using its explicit [GroupConversationItem.groupNumber].
  Future<GroupProfile> findGroupForConversationItem(
    GroupConversationItem item, {
    AuthIdentity? captured,
  }) async {
    final GroupProfile profile = await findGroup(
      item.groupNumber,
      captured: captured,
    );
    if (profile.conversation != item.conversation) {
      throw upstreamMalformed;
    }
    return profile;
  }

  Future<GroupProfile> updateGroup({
    required ConversationRef conversation,
    String? name,
    String? description,
    bool? allowMemberInvites,
    MediaSource? avatar,
    bool resetAvatar = false,
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(
    () => _updateGroup(
      conversation: conversation,
      name: name,
      description: description,
      allowMemberInvites: allowMemberInvites,
      avatar: avatar,
      resetAvatar: resetAvatar,
      captured: captured,
    ),
  );

  Future<GroupProfile> _updateGroup({
    required ConversationRef conversation,
    required String? name,
    required String? description,
    required bool? allowMemberInvites,
    required MediaSource? avatar,
    required bool resetAvatar,
    required AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    if (avatar != null && resetAvatar) {
      throw _validation('avatar', '不能同时上传新头像和恢复默认头像');
    }
    final String? normalizedName = name == null
        ? null
        : _validateGroupName(name);
    final String? normalizedDescription = description == null
        ? null
        : _validateGroupDescription(description);
    final GroupAvatarBytes? avatarBytes = avatar == null
        ? null
        : await _resolveAvatarBytes(avatar);
    _ensureCurrent(identity);
    final GroupProfile profile = await api.updateGroup(
      token: identity.token,
      conversation: conversation,
      name: normalizedName,
      description: normalizedDescription,
      allowMemberInvites: allowMemberInvites,
      avatar: avatarBytes,
      resetAvatar: resetAvatar,
    );
    _ensureCurrent(identity);
    if (avatarBytes != null || resetAvatar) {
      await avatarCache.invalidate(_avatarKey(profile.groupNumber));
    }
    return profile;
  }

  Future<DirectoryPage> listDirectory({
    String afterAccount = '',
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (afterAccount.isNotEmpty && !isValidAccount(afterAccount)) {
      throw _validation('after_account', 'after_account 必须是 8 位账号');
    }
    if (limit < 1 || limit > 100) {
      throw _validation('limit', 'limit 必须在 1–100 之间');
    }
    final DirectoryPage page = await api.listDirectory(
      token: identity.token,
      afterAccount: afterAccount,
      limit: limit,
    );
    _ensureCurrent(identity);
    return page;
  }

  Future<GroupMemberPage> listGroupMembers({
    required ConversationRef conversation,
    String afterAccount = '',
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    if (afterAccount.isNotEmpty && !isValidAccount(afterAccount)) {
      throw _validation('after_account', 'after_account 必须是 8 位账号');
    }
    if (limit < 1 || limit > 100) {
      throw _validation('limit', 'limit 必须在 1–100 之间');
    }
    try {
      final GroupMemberPage page = await api.listGroupMembers(
        token: identity.token,
        conversation: conversation,
        afterAccount: afterAccount,
        limit: limit,
      );
      _ensureCurrent(identity);
      return page;
    } on AuthFailure catch (failure) {
      await _maybeRevokeOnFailure(identity.account, conversation, failure);
      rethrow;
    }
  }

  Future<GroupRequestsResult> inviteToGroup({
    required ConversationRef conversation,
    required List<String> accounts,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    if (accounts.isEmpty || accounts.length > 100) {
      throw _validation('accounts', '邀请列表必须包含 1–100 个账号');
    }
    for (final String account in accounts) {
      if (!isValidAccount(account)) {
        throw _validation('accounts', '账号必须是 8 位 BB 号');
      }
    }
    final GroupRequestsResult result = await api.inviteToGroup(
      token: identity.token,
      conversation: conversation,
      accounts: accounts,
    );
    _ensureCurrent(identity);
    return result;
  }

  Future<GroupRequestsResult> applyToGroup({
    required ConversationRef conversation,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    final GroupRequestsResult result = await api.applyToGroup(
      token: identity.token,
      conversation: conversation,
    );
    _ensureCurrent(identity);
    return result;
  }

  Future<GroupProfile> leaveGroup({
    required ConversationRef conversation,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    final GroupProfile profile = await api.leaveGroup(
      token: identity.token,
      conversation: conversation,
    );
    _ensureCurrent(identity);
    await access?.revoke(identity.account, conversation.id);
    return profile;
  }

  Future<GroupProfile> removeGroupMember({
    required ConversationRef conversation,
    required String account,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    if (!isValidAccount(account)) {
      throw _validation('account', '账号必须是 8 位 BB 号');
    }
    final GroupProfile profile = await api.removeGroupMember(
      token: identity.token,
      conversation: conversation,
      account: account,
    );
    _ensureCurrent(identity);
    if (account == identity.account) {
      await access?.revoke(identity.account, conversation.id);
    }
    return profile;
  }

  Future<GroupProfile> dissolveGroup({
    required ConversationRef conversation,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    _requireGroupConversation(conversation);
    final GroupProfile profile = await api.dissolveGroup(
      token: identity.token,
      conversation: conversation,
    );
    _ensureCurrent(identity);
    await access?.revoke(identity.account, conversation.id);
    return profile;
  }

  Future<NoticePage> listNotices({
    NoticeFilter filter = NoticeFilter.all,
    String? cursor,
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (cursor != null && !opaqueIdPattern.hasMatch(cursor)) {
      throw _validation('cursor', 'cursor 无效');
    }
    if (limit < 1 || limit > 100) {
      throw _validation('limit', 'limit 必须在 1–100 之间');
    }
    final NoticePage page = await api.listNotices(
      token: identity.token,
      filter: filter,
      cursor: cursor,
      limit: limit,
    );
    _ensureCurrent(identity);
    return page;
  }

  Future<Notice> markNoticeRead(
    String notificationId, {
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!opaqueIdPattern.hasMatch(notificationId)) {
      throw _validation('notification_id', 'notification_id 无效');
    }
    final Notice notice = await api.markNoticeRead(
      token: identity.token,
      notificationId: notificationId,
    );
    _ensureCurrent(identity);
    return notice;
  }

  Future<Notice> executeNoticeAction({
    required String notificationId,
    required String actionId,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!opaqueIdPattern.hasMatch(notificationId)) {
      throw _validation('notification_id', 'notification_id 无效');
    }
    if (!opaqueIdPattern.hasMatch(actionId)) {
      throw _validation('action_id', 'action_id 无效');
    }
    final Notice notice = await api.executeNoticeAction(
      token: identity.token,
      notificationId: notificationId,
      actionId: actionId,
    );
    _ensureCurrent(identity);
    return notice;
  }

  /// Loads and caches a group avatar separately from user avatars.
  Future<GroupAvatarImage> loadGroupAvatar({
    required String groupNumber,
    required String avatarUrl,
    AuthIdentity? captured,
    bool thumb = false,
  }) async {
    if (!isValidGroupNumber(groupNumber)) {
      throw _validation('group_number', '群号必须是 8 位数字');
    }
    final String token = _token(captured);
    final AuthIdentity? identity = session.identity;
    final String key = _avatarKey(groupNumber);
    final CachedAvatar? cached = await avatarCache.read(key, thumb: thumb);
    AvatarFetch fetched = await api.fetchGroupAvatar(
      token: token,
      avatarUrl: avatarUrl,
      ifNoneMatch: cached?.version,
      thumb: thumb,
    );
    if (captured != null) {
      _ensureCurrent(captured);
    } else if (identity != null && !session.isCurrent(identity)) {
      throw staleIdentity;
    }
    if (fetched.notModified) {
      if (cached == null) {
        fetched = await api.fetchGroupAvatar(
          token: token,
          avatarUrl: avatarUrl,
          thumb: thumb,
        );
      } else {
        return GroupAvatarImage(
          groupNumber: groupNumber,
          bytes: cached.bytes,
          version: cached.version,
        );
      }
    }
    if (fetched.bytes.isEmpty) {
      throw upstreamMalformed;
    }
    await avatarCache.write(key, fetched.bytes, fetched.version, thumb: thumb);
    return GroupAvatarImage(
      groupNumber: groupNumber,
      bytes: fetched.bytes,
      version: fetched.version,
    );
  }

  Future<void> invalidateGroupAvatar(String groupNumber) {
    return avatarCache.invalidate(_avatarKey(groupNumber));
  }

  Future<GroupAvatarBytes> _resolveAvatarBytes(MediaSource source) async {
    if (!source.hasExactlyOne) {
      throw _validation('avatar', '头像必须且只能提供 path、url、base64 或 bytes 之一');
    }
    final Uint8List bytes;
    if (source.bytes != null) {
      bytes = source.bytes!;
    } else if (source.path != null) {
      bytes = await avatarSources.readPath(source.path!);
    } else if (source.url != null) {
      bytes = await avatarSources.readUrl(source.url!);
    } else {
      bytes = await avatarSources.readBase64(source.base64!);
    }
    validateAvatarBytes(bytes, sourceField: 'avatar', subject: '群头像');
    final String mime = detectImageMime(bytes)!;
    return GroupAvatarBytes(base64: base64Encode(bytes), mimeType: mime);
  }

  Future<void> _maybeRevokeOnFailure(
    String account,
    ConversationRef conversation,
    AuthFailure failure,
  ) async {
    if (failure.status == 403 ||
        failure.status == 404 ||
        failure.code == 'group_unavailable') {
      await access?.revoke(account, conversation.id);
    }
  }

  static String _avatarKey(String groupNumber) => 'group-$groupNumber';

  static void _requireGroupConversation(ConversationRef conversation) {
    if (!conversation.isGroup) {
      throw _validation('conversation', '需要群会话 ID');
    }
  }

  static String _validateGroupName(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 80) {
      throw _validation('name', '群名称长度必须在 1–80 个字符之间');
    }
    return trimmed;
  }

  static String _validateGroupDescription(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.runes.length > 500) {
      throw _validation('description', '群简介不能超过 500 个字符');
    }
    return trimmed;
  }

  static AuthFailure _validation(String field, String message) => AuthFailure(
    status: 422,
    code: 'validation_error',
    message: message,
    fields: <AuthFieldError>[
      AuthFieldError(field: field, code: 'invalid', message: message),
    ],
  );
}

/// Outcome of processing a [ServerEvent] in [SharedConversationService].
enum ServerEventDisposition {
  directMessage,
  groupCurrentMessage,
  staleGroupMessage,
  revokedGroupMessage,
  groupAccessGranted,
  groupAccessRevoked,
  staleAccessEvent,
}

/// Pure-Dart shared conversation queries & revocable media byte store.
///
/// Complements `ChatService` without touching `chat_service.dart` (owned by
/// DEA-503): uses `ChatApiClient` and [ConversationAccessController] so group
/// conversations, history, and media caches respect membership revocation.
class SharedConversationService {
  SharedConversationService({
    required this.api,
    required this.session,
    required this.access,
    MediaSourceResolver? resolver,
  }) : _resolver = resolver ?? MediaSourceResolver() {
    access.registerPurger(_purgeMemoryForConversation);
  }

  final ChatApiClient api;
  final AuthSession session;
  final ConversationAccessController access;
  final MediaSourceResolver _resolver;

  final Map<String, Uint8List> _thumbCache = <String, Uint8List>{};
  final Map<String, Uint8List> _originalCache = <String, Uint8List>{};
  final Map<String, Attachment> _metadataCache = <String, Attachment>{};
  final Map<String, Set<String>> _scopeMedia = <String, Set<String>>{};
  final Map<String, String> _groupNumbers = <String, String>{};

  void dispose() {
    access.unregisterPurger(_purgeMemoryForConversation);
    _thumbCache.clear();
    _originalCache.clear();
    _metadataCache.clear();
    _scopeMedia.clear();
    _groupNumbers.clear();
  }

  String? groupNumberFor(String account, String conversationId) =>
      _groupNumbers[ConversationAccessController.scopeKey(
        account,
        conversationId,
      )];

  AuthIdentity _requireIdentity(AuthIdentity? captured) {
    final AuthIdentity? current = session.identity;
    if (captured != null) {
      if (current == null || !captured.sameAs(current)) {
        throw staleIdentity;
      }
      return captured;
    }
    if (current == null) {
      throw unauthenticated;
    }
    return current;
  }

  Future<SharedConversationPage> listSharedConversations({
    String afterId = '',
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    final SharedConversationPage page = await api.sharedConversations(
      token: identity.token,
      afterId: afterId,
      limit: limit.clamp(1, 100),
    );
    if (!session.isCurrent(identity)) {
      throw staleIdentity;
    }
    for (final SharedConversation item in page.items) {
      if (item is GroupConversationItem) {
        _groupNumbers[ConversationAccessController.scopeKey(
              identity.account,
              item.conversation.id,
            )] =
            item.groupNumber;
        access.grant(
          identity.account,
          item.conversation.id,
          membershipRevision: item.membershipRevision,
          historyThrough: item.historyThrough,
        );
      }
    }
    return page;
  }

  /// Looks up a group's profile via `POST /chat/groups/find` using the
  /// `group_number` associated with [conversation] from shared conversation
  /// items (fetching shared conversation pages if not yet cached).
  Future<GroupProfile> loadGroupProfile({
    required ConversationRef conversation,
    required GroupService groups,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!conversation.isGroup) {
      throw GroupService._validation('conversation', '需要群会话 ID');
    }
    String? groupNumber = groupNumberFor(identity.account, conversation.id);
    if (groupNumber == null) {
      String afterId = '';
      while (true) {
        final SharedConversationPage page = await listSharedConversations(
          afterId: afterId,
          limit: 100,
          captured: identity,
        );
        groupNumber = groupNumberFor(identity.account, conversation.id);
        if (groupNumber != null || page.nextCursor == null) {
          break;
        }
        afterId = page.nextCursor!;
      }
    }
    if (groupNumber == null) {
      throw const AuthFailure(
        status: 404,
        code: 'not_found',
        message: '未找到对应群会话的群号',
      );
    }
    final GroupProfile profile = await groups.findGroup(
      groupNumber,
      captured: identity,
    );
    if (profile.conversation != conversation) {
      throw upstreamMalformed;
    }
    return profile;
  }

  Future<MessagePage> loadConversationHistory({
    required ConversationRef conversation,
    int? afterPosition = 0,
    int? beforePosition,
    int limit = 50,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (conversation.isGroup &&
        access.isRevoked(identity.account, conversation.id)) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '已无权查看该群聊天记录',
      );
    }
    try {
      final MessagePage page = await api.conversationHistory(
        token: identity.token,
        conversation: conversation,
        afterPosition: afterPosition,
        beforePosition: beforePosition,
        limit: limit.clamp(1, 100),
      );
      if (!session.isCurrent(identity)) {
        throw staleIdentity;
      }
      if (conversation.isGroup) {
        for (final ChatMessage message in page.items) {
          _registerMessageMedia(identity.account, conversation.id, message);
        }
      }
      return page;
    } on AuthFailure catch (failure) {
      if (conversation.isGroup &&
          (failure.status == 403 ||
              failure.status == 404 ||
              failure.code == 'group_unavailable')) {
        await access.revoke(identity.account, conversation.id);
      }
      rethrow;
    }
  }

  Future<ChatMessage> sendGroupMessage({
    required ConversationRef conversation,
    required String clientNonce,
    required List<MessagePart> content,
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(() async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!conversation.isGroup) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '需要群会话 ID',
      );
    }
    try {
      final ChatMessage message = await api.sendConversationMessage(
        token: identity.token,
        conversation: conversation,
        clientNonce: clientNonce,
        content: content,
      );
      if (!session.isCurrent(identity)) {
        throw staleIdentity;
      }
      return message;
    } on AuthFailure catch (failure) {
      if (failure.status == 403 ||
          failure.status == 404 ||
          failure.code == 'group_unavailable') {
        await access.revoke(identity.account, conversation.id);
      }
      rethrow;
    }
  });

  Future<ChatMessage> sendGroupAttachment({
    required ConversationRef conversation,
    required String clientNonce,
    required String mediaId,
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(() async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (!conversation.isGroup) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '需要群会话 ID',
      );
    }
    try {
      final ChatMessage message = await api.sendConversationAttachment(
        token: identity.token,
        conversation: conversation,
        clientNonce: clientNonce,
        mediaId: mediaId,
      );
      if (!session.isCurrent(identity)) {
        throw staleIdentity;
      }
      access.registerMedia(identity.account, conversation.id, mediaId);
      return message;
    } on AuthFailure catch (failure) {
      if (failure.status == 403 ||
          failure.status == 404 ||
          failure.code == 'group_unavailable') {
        await access.revoke(identity.account, conversation.id);
      }
      rethrow;
    }
  });

  Future<Attachment> uploadConversationMedia({
    required ConversationRef conversation,
    required MediaSource source,
    String? coverMediaId,
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(() async {
    final AuthIdentity identity = _requireIdentity(captured);
    final ResolvedMedia resolved = await _resolver.resolve(source);
    if (!session.isCurrent(identity)) {
      throw staleIdentity;
    }
    try {
      final Attachment uploaded = await api.uploadConversationMedia(
        token: identity.token,
        conversation: conversation,
        bytes: resolved.bytes,
        filename: resolved.filename,
        mimeType: resolved.mimeType,
        coverMediaId: coverMediaId,
      );
      if (!session.isCurrent(identity)) {
        throw staleIdentity;
      }
      access.registerMedia(identity.account, conversation.id, uploaded.mediaId);
      return uploaded;
    } on AuthFailure catch (failure) {
      if (conversation.isGroup &&
          (failure.status == 403 ||
              failure.status == 404 ||
              failure.code == 'group_unavailable')) {
        await access.revoke(identity.account, conversation.id);
      }
      rethrow;
    }
  });

  /// Scoped media metadata lookup; purges cached metadata on 403/404 or group
  /// access revocation.
  Future<Attachment> loadScopedMediaMetadata({
    required ConversationRef conversation,
    required String mediaId,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (conversation.isGroup &&
        access.isRevoked(identity.account, conversation.id)) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '无权访问该会话媒体',
      );
    }
    final String key = _cacheKey(identity.account, conversation.id, mediaId);
    final Attachment? hit = _metadataCache[key];
    if (hit != null) {
      return hit;
    }
    try {
      final Attachment metadata = await api.fetchMediaMetadata(
        token: identity.token,
        mediaId: mediaId,
      );
      if (!session.isCurrent(identity)) {
        throw staleIdentity;
      }
      if (conversation.isGroup &&
          access.isRevoked(identity.account, conversation.id)) {
        throw const AuthFailure(
          status: 403,
          code: 'forbidden',
          message: '无权访问该会话媒体',
        );
      }
      _rememberMediaKey(identity.account, conversation.id, key);
      _metadataCache[key] = metadata;
      return metadata;
    } on AuthFailure catch (failure) {
      if (conversation.isGroup &&
          (failure.status == 403 || failure.status == 404)) {
        await access.revoke(identity.account, conversation.id);
      }
      rethrow;
    }
  }

  /// Scoped media bytes lookup (`thumb` or `original`), purged when revoked.
  Future<Uint8List> loadScopedMediaBytes({
    required ConversationRef conversation,
    required String mediaId,
    bool thumb = false,
    AuthIdentity? captured,
  }) async {
    final AuthIdentity identity = _requireIdentity(captured);
    if (conversation.isGroup &&
        access.isRevoked(identity.account, conversation.id)) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '无权访问该会话媒体',
      );
    }
    final String key = _cacheKey(identity.account, conversation.id, mediaId);
    final Map<String, Uint8List> store = thumb ? _thumbCache : _originalCache;
    final Uint8List? hit = store[key];
    if (hit != null) {
      return hit;
    }
    try {
      final MediaResponse media = await api.fetchMedia(
        token: identity.token,
        mediaId: mediaId,
        variant: thumb ? 'thumb' : null,
      );
      if (!session.isCurrent(identity)) {
        throw staleIdentity;
      }
      if (conversation.isGroup &&
          access.isRevoked(identity.account, conversation.id)) {
        throw const AuthFailure(
          status: 403,
          code: 'forbidden',
          message: '无权访问该会话媒体',
        );
      }
      _rememberMediaKey(identity.account, conversation.id, key);
      store[key] = media.bytes;
      return media.bytes;
    } on AuthFailure catch (failure) {
      if (conversation.isGroup &&
          (failure.status == 403 || failure.status == 404)) {
        await access.revoke(identity.account, conversation.id);
      }
      rethrow;
    }
  }

  /// Applies a server event (`conversation.access_changed`, group
  /// `message.available` with `membership_revision`, or direct
  /// `message.available`) and reports its [ServerEventDisposition].
  Future<ServerEventDisposition> applyServerEvent(
    String account,
    ServerEvent event,
  ) async {
    final ConversationRef? conv = event.conversation;
    if (conv == null) {
      return ServerEventDisposition.directMessage;
    }
    if (event.isAccessChanged) {
      final bool applied = await access.applyAccessEvent(
        account: account,
        conversationId: conv.id,
        active: event.active ?? false,
        membershipRevision: event.membershipRevision ?? 1,
        historyThrough: event.historyThrough,
      );
      if (!applied) {
        return ServerEventDisposition.staleAccessEvent;
      }
      return (event.active ?? false)
          ? ServerEventDisposition.groupAccessGranted
          : ServerEventDisposition.groupAccessRevoked;
    }
    if (event.isGroupMessage && event.membershipRevision != null) {
      final GroupMessageEventStatus status = access.classifyGroupMessageEvent(
        account,
        conv.id,
        membershipRevision: event.membershipRevision!,
        position: event.position > 0 ? event.position : null,
      );
      return switch (status) {
        GroupMessageEventStatus.currentCycle =>
          ServerEventDisposition.groupCurrentMessage,
        GroupMessageEventStatus.stalePreLeaveRevision =>
          ServerEventDisposition.staleGroupMessage,
        GroupMessageEventStatus.revokedAccess =>
          ServerEventDisposition.revokedGroupMessage,
      };
    }
    return ServerEventDisposition.directMessage;
  }

  void _registerMessageMedia(
    String account,
    String conversationId,
    ChatMessage message,
  ) {
    if (message.attachment != null) {
      access.registerMedia(
        account,
        conversationId,
        message.attachment!.mediaId,
      );
      if (message.attachment!.coverMediaId != null) {
        access.registerMedia(
          account,
          conversationId,
          message.attachment!.coverMediaId!,
        );
      }
    }
    for (final MessagePart part in message.parts) {
      if (part is ImagePart) {
        access.registerMedia(account, conversationId, part.mediaId);
      }
    }
  }

  String _cacheKey(String account, String conversationId, String mediaId) =>
      '${api.baseUri}\u0001$account\u0001$conversationId\u0001$mediaId';

  void _rememberMediaKey(String account, String conversationId, String key) {
    final String scope = ConversationAccessController.scopeKey(
      account,
      conversationId,
    );
    _scopeMedia.putIfAbsent(scope, () => <String>{}).add(key);
  }

  void _purgeMemoryForConversation(
    String account,
    String conversationId,
    Set<String> mediaIds,
  ) {
    final String scope = ConversationAccessController.scopeKey(
      account,
      conversationId,
    );
    final Set<String>? keys = _scopeMedia.remove(scope);
    if (keys != null) {
      for (final String key in keys) {
        _thumbCache.remove(key);
        _originalCache.remove(key);
        _metadataCache.remove(key);
      }
    }
    for (final String mediaId in mediaIds) {
      final String key = _cacheKey(account, conversationId, mediaId);
      _thumbCache.remove(key);
      _originalCache.remove(key);
      _metadataCache.remove(key);
    }
  }
}

/// Registers a [MediaDiskCache] purger on [access] so any group revocation
/// deletes `chat-original-<scopeTag>|*` entries for `(server, account,
/// conversationId)` even when no viewer is currently open.
ConversationCachePurger registerDiskCachePurger({
  required ConversationAccessController access,
  required MediaDiskCache disk,
  required Uri serverUri,
}) {
  final String server = serverUri.toString();
  Future<void> purger(
    String account,
    String conversationId,
    Set<String> mediaIds,
  ) async {
    final String tag = ConversationAccessController.diskScopeTag(
      server: server,
      account: account,
      conversationId: conversationId,
    );
    final String prefix = 'chat-original-$tag|';
    await disk.deleteWhere((String key) => key.startsWith(prefix));
    for (final String mediaId in mediaIds) {
      await disk.delete('$prefix$mediaId');
    }
  }

  access.registerPurger(purger);
  return purger;
}
