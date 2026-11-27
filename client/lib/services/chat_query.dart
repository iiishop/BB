import 'dart:math' as math;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import '../models/conversation_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';
import 'client_identity.dart';

/// Unified client query service over the shared server query layer.
///
/// Server routes (`/conversations`, `/messages/{id}`,
/// `/messages/{id}/context`, bidirectional pair history) are the single fact
/// source; this service never scans or guesses a message's existence. The
/// local v2 routes validate owner/consumer/binding first and then use this
/// service; all methods re-check the captured identity before returning.
class ChatQueryService {
  ChatQueryService({
    required this.api,
    required this.session,
    required this.ledger,
  });

  final ChatApiClient api;
  final AuthSession session;
  final ChatLedger ledger;
  final Map<String, _ConversationSnapshot> _snapshots = <String, _ConversationSnapshot>{};

  static final RegExp _accountPattern = RegExp(r'^[1-9][0-9]{7}$');
  static final RegExp _messageIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,200}$');

  // ------------------------------------------------------------ conversations --

  /// Existing private conversations only, peer-account keyset order.
  ///
  /// [consumerId] must belong to the authenticated account. The response adds
  /// that consumer's `consumed_through` and the bidirectional-stream
  /// `unconsumed_positions`; this is not an incoming-unread count and not an
  /// outbound read receipt.
  Future<ConversationPage> listConversations({
    String afterAccount = '',
    int limit = 50,
    required String consumerId,
    String order = 'account',
    bool unreadOnly = false,
    String? cursor,
  }) async {
    final AuthIdentity captured = _requireLogin();
    if (afterAccount.isNotEmpty && !_accountPattern.hasMatch(afterAccount)) {
      throw _validation('after_account');
    }
    if (limit < 1 || limit > 100) {
      throw _validation('limit');
    }
    final ConsumerBinding? binding = await ledger.bindingById(consumerId);
    if (binding == null || binding.account != captured.account) {
      throw staleBindingFailure;
    }
    if (!const <String>{'account', 'recent'}.contains(order) ||
        (afterAccount.isNotEmpty && (order != 'account' || unreadOnly || cursor != null))) {
      throw _validation('cursor');
    }
    final String scope = '${captured.account}:${captured.authGeneration}:$consumerId:${binding.bindingRevision}';
    final DateTime now = DateTime.now().toUtc();
    _snapshots.removeWhere((_, snapshot) => snapshot.expires.isBefore(now));
    if (cursor != null) {
      final _ConversationSnapshot? snapshot = _snapshots[cursor];
      if (snapshot == null || snapshot.scope != scope || snapshot.order != order || snapshot.unreadOnly != unreadOnly) {
        throw _validation('cursor');
      }
      _ensureCurrent(captured);
      return _snapshotPage(snapshot, limit);
    }
    final bool snapshotMode = order == 'recent' || unreadOnly;
    final Set<String> displayed = await ledger.displayedMessageIds(captured.account);
    final List<ConversationSummary> items = <ConversationSummary>[];
    String after = afterAccount;
    String? next;
    do {
      final ConversationRecordPage page = await api.conversations(
        token: captured.token, afterAccount: after, limit: snapshotMode ? 100 : limit,
      );
      _ensureCurrent(captured);
      for (final ConversationRecord row in page.items) {
        final summary = await summarizeConversation(captured: captured, row: row, consumerId: consumerId, displayed: displayed);
        if (!unreadOnly || summary.incomingUnread > 0) items.add(summary);
      }
      next = page.nextCursor;
      if (!snapshotMode || next == null) break;
      if (next.compareTo(after) <= 0) throw const FormatException('conversation cursor did not advance');
      after = next;
    } while (true);
    _ensureCurrent(captured);
    if (!snapshotMode) {
      return ConversationPage(items: List<ConversationSummary>.unmodifiable(items), nextCursor: next);
    }
    if (order == 'recent') {
      items.sort((a, b) {
        final int time = b.lastActivityAt.compareTo(a.lastActivityAt);
        return time != 0 ? time : a.peerAccount.compareTo(b.peerAccount);
      });
    }
    return _snapshotPage(_ConversationSnapshot(scope: scope, order: order,
      unreadOnly: unreadOnly, expires: now.add(const Duration(minutes: 5)),
      items: List<ConversationSummary>.unmodifiable(items)), limit);
  }

  /// Shared account-unread calculation for list and notification metadata.
  /// Callers retain their own owner/identity fence and peer failure policy.
  Future<ConversationSummary> summarizeConversation({
    required AuthIdentity captured,
    required ConversationRecord row,
    required String consumerId,
    required Set<String> displayed,
  }) async {
    _ensureCurrent(captured);
    await ledger.observeMessageAssociations(captured.account, [
      row.lastMessage,
    ], peerAccount: row.peerAccount);
    _ensureCurrent(captured);
    final consumed = await ledger.consumedThrough(
      captured.account,
      row.peerAccount,
      consumerId: consumerId,
    );
    int unread = 0, position = 0;
    ChatMessage? latestUnread;
    while (position < row.latestPosition) {
      final history = await api.conversation(
        token: captured.token,
        account: row.peerAccount,
        afterPosition: position,
        limit: 100,
      );
      _ensureCurrent(captured);
      for (final message in history.items) {
        if (message.position > row.latestPosition) break;
        if (message.targetAccount == captured.account &&
            !displayed.contains(message.id)) {
          unread++;
          latestUnread = message;
        }
      }
      if (history.items.isEmpty || !history.hasMore) break;
      if (history.nextPosition <= position) {
        throw const FormatException('history cursor did not advance');
      }
      position = history.nextPosition;
    }
    _ensureCurrent(captured);
    return ConversationSummary(
      peerAccount: row.peerAccount,
      conversation: directConversation(captured.account, row.peerAccount),
      displayName: row.displayName ?? row.peerAccount,
      lastMessage: row.lastMessage,
      lastActivityAt: row.lastActivityAt,
      latestPosition: row.latestPosition,
      consumedThrough: consumed,
      unconsumedPositions: math.max(0, row.latestPosition - consumed),
      incomingUnread: unread,
      latestUnread: latestUnread == null ? null : messagePreview(latestUnread),
    );
  }

  ConversationPage _snapshotPage(_ConversationSnapshot snapshot, int limit) {
    final List<ConversationSummary> page = snapshot.items.take(limit).toList();
    String? next;
    if (snapshot.items.length > limit) {
      // Ephemeral query cache only: no durable copy of business messages.
      // The cursor is scoped to this binding and expires on restart/after 5m.
      next = newConsumerId();
      if (_snapshots.length >= 32) _snapshots.remove(_snapshots.keys.first);
      _snapshots[next] = _ConversationSnapshot(scope: snapshot.scope, order: snapshot.order,
        unreadOnly: snapshot.unreadOnly, expires: snapshot.expires,
        items: snapshot.items.sublist(limit));
    }
    return ConversationPage(items: page, nextCursor: next);
  }

  // --------------------------------------------------------------- messages --

  /// Direct lookup from the shared server query layer.
  ///
  /// `null` is the uniform safe miss for absent and unauthorized messages.
  /// Network failures and incompletely fetched pages are never turned into
  /// that safe miss.
  Future<ChatMessage?> messageById(String messageId) async {
    final AuthIdentity captured = _requireLogin();
    if (!_messageIdPattern.hasMatch(messageId)) {
      throw _validation('message_id');
    }
    final ChatMessage? message = await api.messageById(
      token: captured.token,
      messageId: messageId,
    );
    _ensureCurrent(captured);
    if (message != null) {
      await ledger.observeMessageAssociations(captured.account, [message]);
      _ensureCurrent(captured);
    }
    return message;
  }

  /// Direct context from the same server read transaction.
  ///
  /// `null` means the anchor is absent or outside this account's scope.
  Future<ContextResult?> getContext({
    required String messageId,
    int beforeLimit = 10,
    int afterLimit = 10,
  }) async {
    final AuthIdentity captured = _requireLogin();
    if (!_messageIdPattern.hasMatch(messageId)) {
      throw _validation('message_id');
    }
    if (beforeLimit < 0 || beforeLimit > 49) {
      throw _validation('before_limit');
    }
    if (afterLimit < 0 || afterLimit > 49) {
      throw _validation('after_limit');
    }
    final MessageContextRecord? record = await api.messageContext(
      token: captured.token,
      messageId: messageId,
      beforeLimit: beforeLimit,
      afterLimit: afterLimit,
    );
    _ensureCurrent(captured);
    if (record == null) {
      return null;
    }
    await ledger.observeMessageAssociations(
      captured.account,
      record.items,
      peerAccount: record.peerAccount,
    );
    _ensureCurrent(captured);
    return ContextResult(
      items: record.items,
      anchorMessageId: record.anchorMessageId,
      peerAccount: record.peerAccount,
      conversation: record.conversation,
      startPosition: record.startPosition,
      endPosition: record.endPosition,
      beforeHasMore: record.beforeHasMore,
      afterHasMore: record.afterHasMore,
      missingPositions: record.missingPositions,
      missingTruncated: record.missingTruncated,
      replyRelations: record.replyRelations,
    );
  }

  // --------------------------------------------------------------- history --

  /// One ascending page of pair history.
  ///
  /// `afterPosition` and `beforePosition` are mutually exclusive. `nextPosition`
  /// follows the contract: the last item for `after`, the first item for
  /// `before`, and the request boundary for an empty page.
  Future<HistoryPage> readHistory({
    required String peerAccount,
    int? afterPosition,
    int? beforePosition,
    int limit = 50,
  }) async {
    final AuthIdentity captured = _requireLogin();
    if (!_accountPattern.hasMatch(peerAccount)) {
      throw _validation('account');
    }
    if (afterPosition != null && beforePosition != null) {
      throw _validation('before_position');
    }
    if ((afterPosition ?? 0) < 0) {
      throw _validation('after_position');
    }
    if (beforePosition != null && beforePosition < 1) {
      throw _validation('before_position');
    }
    if (limit < 1 || limit > 100) {
      throw _validation('limit');
    }
    final MessagePage page = await api.conversation(
      token: captured.token,
      account: peerAccount,
      afterPosition: afterPosition,
      beforePosition: beforePosition,
      limit: limit,
    );
    _ensureCurrent(captured);
    await ledger.observeMessageAssociations(
      captured.account,
      page.items,
      peerAccount: peerAccount,
    );
    _ensureCurrent(captured);
    final bool backward = beforePosition != null;
    final int nextPosition = backward
        ? (page.items.isNotEmpty ? page.items.first.position : beforePosition)
        : page.nextPosition;
    return HistoryPage(
      items: List<ChatMessage>.unmodifiable(page.items),
      nextPosition: nextPosition,
      hasMore: page.hasMore,
    );
  }

  // ------------------------------------------------------------- internals --

  AuthIdentity _requireLogin() {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    return captured;
  }

  void _ensureCurrent(AuthIdentity captured) {
    if (!session.isCurrent(captured)) {
      throw staleIdentityFailure;
    }
  }

  AuthFailure _validation(String field) => AuthFailure(
    status: 422,
    code: 'validation_error',
    message: '查询参数无效',
    fields: <AuthFieldError>[
      AuthFieldError(field: field, code: 'invalid', message: '参数无效'),
    ],
  );
}

/// One existing private conversation plus the validated consumer watermark.
class ConversationSummary {
  const ConversationSummary({
    required this.peerAccount,
    required this.lastMessage,
    required this.lastActivityAt,
    required this.latestPosition,
    required this.consumedThrough,
    required this.unconsumedPositions,
    required this.conversation,
    required this.displayName,
    required this.incomingUnread,
    required this.latestUnread,
  });

  final String peerAccount;
  final ChatMessage lastMessage;
  final DateTime lastActivityAt;
  final int latestPosition;
  final int consumedThrough;
  final int unconsumedPositions;
  final Map<String, dynamic> conversation;
  final String displayName;
  final int incomingUnread;
  final Map<String, dynamic>? latestUnread;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'peer_account': peerAccount,
    'last_message': messageToJson(lastMessage),
    'last_activity_at': lastActivityAt.toIso8601String(),
    'latest_position': latestPosition,
    'consumed_through': consumedThrough,
    'unconsumed_positions': unconsumedPositions,
    'conversation': conversation,
    'display_name': displayName,
    'incoming_unread': incomingUnread,
    'latest_unread': latestUnread,
  };
}

class ConversationPage {
  const ConversationPage({required this.items, required this.nextCursor});

  final List<ConversationSummary> items;
  final String? nextCursor;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((ConversationSummary item) => item.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}

class ContextResult {
  const ContextResult({
    required this.items,
    required this.anchorMessageId,
    required this.peerAccount,
    this.conversation,
    required this.startPosition,
    required this.endPosition,
    required this.beforeHasMore,
    required this.afterHasMore,
    required this.missingPositions,
    required this.missingTruncated,
    required this.replyRelations,
  });

  final List<ChatMessage> items;
  final String anchorMessageId;
  final String peerAccount;
  final ConversationRef? conversation;
  final int startPosition;
  final int endPosition;
  final bool beforeHasMore;
  final bool afterHasMore;
  final List<int> missingPositions;
  final bool missingTruncated;
  final String replyRelations;
}

/// A query-time visible message plus media that could not be fetched.
///
/// When [missingMediaIds] is non-empty the item has no presentation receipt:
/// a partial image display must never become consumable evidence.
class QueryVisibleMessage {
  const QueryVisibleMessage({
    required this.item,
    required this.missingMediaIds,
  });

  final VisibleMessage item;
  final List<String> missingMediaIds;
}

class HistoryPage {
  const HistoryPage({
    required this.items,
    required this.nextPosition,
    required this.hasMore,
  });

  final List<ChatMessage> items;
  final int nextPosition;
  final bool hasMore;
}

/// Identity changed mid-query: stale error rather than an old page.
const AuthFailure staleIdentityFailure = AuthFailure(
  status: 409,
  code: 'stale_identity',
  message: '身份已变化，请重新登录或显式重绑',
);

/// A caller-supplied consumer id not bound to the authenticated account.
/// Owner capability and revision validation are layered by the v2 route.
const AuthFailure staleBindingFailure = AuthFailure(
  status: 409,
  code: 'stale_binding',
  message: '消费者能力或绑定不匹配',
);

class _ConversationSnapshot {
  const _ConversationSnapshot({required this.scope, required this.order,
    required this.unreadOnly, required this.expires, required this.items});
  final String scope;
  final String order;
  final bool unreadOnly;
  final DateTime expires;
  final List<ConversationSummary> items;
}

/// Canonical protocol-v1 conversation identity. Speaker identity stays separate.
Map<String, dynamic> directConversation(String account, String peer) {
  final List<String> members = <String>[account, peer]..sort();
  return <String, dynamic>{'type': 'direct', 'id': 'dm:${members[0]}:${members[1]}'};
}

/// Untrusted text metadata only; this never loads media or creates a receipt.
Map<String, dynamic> messagePreview(ChatMessage message) {
  final String text = message.kind == ChatMessageKind.attachment
      ? '[attachment]'
      : message.parts.map((part) => part is TextPart ? part.text : '[image]').join(' ');
  final List<int> runes = text.runes.take(161).toList();
  return <String, dynamic>{
    'message_id': message.id, 'sender_account': message.senderAccount,
    'position': message.position, 'created_at': message.createdAt.toUtc().toIso8601String(),
    'text': String.fromCharCodes(runes.take(160)), 'truncated': runes.length > 160,
  };
}
