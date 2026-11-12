import 'dart:math' as math;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';
import 'client_identity.dart';

/// Unified client query facts for conversations, messages and context.
///
/// The shared v2 query routes (`list_conversations`, `get_message`,
/// `get_context`, bidirectional `read_messages`) are authored by Forge. This
/// service owns the semantics they will expose: only the current account's
/// private conversations, uniform safe misses, ordered history, explicit
/// truncation, and no implicit ACK/consumption. Until the shared transport
/// commit lands, the implementation uses the existing read-only HTTP facts and
/// keeps every scan explicitly bounded.
class ChatQueryService {
  ChatQueryService({
    required this.api,
    required this.session,
    required this.ledger,
    this.maxScanMessages = 2000,
  });

  final ChatApiClient api;
  final AuthSession session;
  final ChatLedger ledger;

  /// Bound for the forward scans used by `get_message`/`before` history until
  /// the shared bidirectional route exists. Reaching it is reported, never
  /// silently treated as "absent".
  final int maxScanMessages;

  static const int maxPageSize = 100;

  // ------------------------------------------------------------ conversations --

  /// Current account's existing private conversations only.
  ///
  /// [consumerId] enables the consumer's "not yet consumed" meaning: it is
  /// computed from this consumer's own watermark and incoming messages, never
  /// from an account-wide cursor or an outbound read receipt. Without a
  /// consumer the unread state is explicitly `unknown`.
  Future<ConversationPage> listConversations({
    String afterAccount = '',
    int limit = 50,
    String? consumerId,
  }) async {
    final AuthIdentity captured = _requireLogin();
    if (afterAccount.isNotEmpty && !_accountPattern.hasMatch(afterAccount)) {
      throw _validation('after_account');
    }
    if (consumerId != null) {
      // A caller-supplied consumer id is not authority by itself: it must
      // belong to the authenticated account. Owner/revision checks stay in the
      // v2 route layer when it is wired.
      final ConsumerBinding? binding = await ledger.bindingById(consumerId);
      if (binding == null || binding.account != captured.account) {
        throw staleBindingFailure;
      }
    }
    final int pageSize = limit.clamp(1, maxPageSize);
    final List<ConversationSummary> conversations = <ConversationSummary>[];
    String cursor = afterAccount;
    String? nextCursor;
    while (conversations.length < pageSize) {
      final UserPage page = await api.listUsers(
        token: captured.token,
        afterAccount: cursor,
        limit: pageSize,
      );
      if (!session.isCurrent(captured)) {
        throw staleIdentityFailure;
      }
      if (page.items.isEmpty) {
        nextCursor = null;
        break;
      }
      int examined = 0;
      for (final ChatUser user in page.items) {
        cursor = user.account;
        examined += 1;
        if (user.lastMessage == null || user.lastContactAt == null) {
          continue;
        }
        final ConversationSummary summary = await _summary(
          captured,
          user,
          consumerId,
        );
        _ensureCurrent(captured);
        conversations.add(summary);
        if (conversations.length >= pageSize) {
          break;
        }
      }
      final bool pageExhausted = examined == page.items.length;
      if (conversations.length >= pageSize) {
        // Unexamined users may remain on this page, so hand the caller the
        // last examined account as a stable cursor.
        nextCursor =
            (page.nextCursor != null || !pageExhausted) ? cursor : null;
        break;
      }
      if (page.nextCursor == null) {
        nextCursor = null;
        break;
      }
    }
    _ensureCurrent(captured);
    return ConversationPage(
      items: List<ConversationSummary>.unmodifiable(conversations),
      nextCursor: nextCursor,
      hasMore: nextCursor != null,
    );
  }

  Future<ConversationSummary> _summary(
    AuthIdentity captured,
    ChatUser peer,
    String? consumerId,
  ) async {
    ConversationUnread unread = ConversationUnread.unknown;
    int? firstUnread;
    if (consumerId != null) {
      _ensureCurrent(captured);
      unread = ConversationUnread.none;
      final int consumed = await ledger.consumedThrough(
        captured.account,
        peer.account,
        consumerId: consumerId,
      );
      final MessagePage page = await api.conversation(
        token: captured.token,
        account: peer.account,
        afterPosition: consumed,
        limit: maxPageSize,
      );
      if (!session.isCurrent(captured)) {
        throw staleIdentityFailure;
      }
      for (final ChatMessage message in page.items) {
        if (message.senderAccount != captured.account) {
          unread = ConversationUnread.unread;
          firstUnread = message.position;
          break;
        }
      }
      if (unread == ConversationUnread.none && page.hasMore) {
        // The next page may contain the first incoming message; never claim
        // "no unread" from an incomplete page.
        unread = ConversationUnread.unknown;
      }
    }
    _ensureCurrent(captured);
    return ConversationSummary(
      peer: peer,
      lastMessage: peer.lastMessage,
      lastActivityAt: peer.lastContactAt,
      unread: unread,
      firstUnreadPosition: firstUnread,
    );
  }

  // --------------------------------------------------------------- messages --

  /// Full message by stable id for one allowed peer. Missing or inaccessible
  /// messages share the same safe result; a bounded scan is reported as
  /// truncated rather than claimed absent.
  Future<MessageLookup> getMessage({
    required String peerAccount,
    required String messageId,
  }) async {
    final AuthIdentity captured = _requireLogin();
    _requirePeer(captured, peerAccount);
    if (messageId.trim().isEmpty) {
      throw _validation('message_id');
    }
    final int scanBound = math.max(1, maxScanMessages);
    int after = 0;
    int scanned = 0;
    while (scanned < scanBound) {
      final MessagePage page = await api.conversation(
        token: captured.token,
        account: peerAccount,
        afterPosition: after,
        limit: maxPageSize,
      );
      if (!session.isCurrent(captured)) {
        throw staleIdentityFailure;
      }
      if (page.items.isEmpty) {
        return const MessageLookup(message: null, truncated: false);
      }
      bool boundHit = false;
      for (final ChatMessage message in page.items) {
        scanned += 1;
        if (scanned > scanBound) {
          boundHit = true;
          break;
        }
        if (message.id == messageId) {
          return MessageLookup(message: message, truncated: false);
        }
      }
      if (boundHit) {
        return const MessageLookup(message: null, truncated: true);
      }
      if (!page.hasMore) {
        // The scan completed exactly at the bound: this is a complete,
        // successful miss, not a truncated scan.
        return const MessageLookup(message: null, truncated: false);
      }
      if (scanned >= scanBound) {
        // The page ended at the bound and more records exist beyond it.
        return const MessageLookup(message: null, truncated: true);
      }
      if (page.nextPosition <= after) {
        return const MessageLookup(message: null, truncated: true);
      }
      after = page.nextPosition;
    }
    return const MessageLookup(message: null, truncated: true);
  }

  /// Ordered context around one message plus explicit range/truncation facts.
  ///
  /// Reply relations are not part of the current message facts; the result
  /// says so explicitly instead of fabricating them.
  Future<ContextResult> getContext({
    required String peerAccount,
    required String messageId,
    int before = 10,
    int after = 10,
  }) async {
    final AuthIdentity captured = _requireLogin();
    _requirePeer(captured, peerAccount);
    if (before < 0 || after < 0) {
      throw _validation('before');
    }
    final int beforeCount = before.clamp(0, 50);
    final int afterCount = after.clamp(0, 50);
    final MessageLookup lookup = await getMessage(
      peerAccount: peerAccount,
      messageId: messageId,
    );
    final ChatMessage? target = lookup.message;
    if (target == null) {
      return ContextResult(
        message: null,
        items: const <ChatMessage>[],
        truncated: lookup.truncated,
        truncatedBefore: false,
        truncatedAfter: false,
        replySupport: ReplySupport.unsupported,
      );
    }
    final int start = math.max(1, target.position - beforeCount);
    final int end = target.position + afterCount;
    final List<ChatMessage> window = <ChatMessage>[];
    int cursor = start - 1;
    int pages = 0;
    bool limitTruncated = false;
    while (true) {
      final int pageLimit = (end - cursor).clamp(1, maxPageSize);
      final MessagePage page = await api.conversation(
        token: captured.token,
        account: peerAccount,
        afterPosition: cursor,
        limit: pageLimit,
      );
      if (!session.isCurrent(captured)) {
        throw staleIdentityFailure;
      }
      if (page.items.isEmpty) {
        break;
      }
      for (final ChatMessage message in page.items) {
        if (message.position >= start && message.position <= end) {
          window.add(message);
        }
      }
      cursor = page.nextPosition;
      if (window.isNotEmpty && window.last.position >= end) {
        break;
      }
      if (!page.hasMore) {
        break;
      }
      pages += 1;
      if (pages > 3) {
        limitTruncated = true;
        break;
      }
    }
    window.sort(
      (ChatMessage a, ChatMessage b) => a.position.compareTo(b.position),
    );
    final bool beforeTruncated =
        start > 1 && (window.isEmpty || window.first.position > start);
    final bool afterTruncated =
        window.isNotEmpty &&
        window.last.position < end &&
        limitTruncated;
    _ensureCurrent(captured);
    return ContextResult(
      message: target,
      items: List<ChatMessage>.unmodifiable(window),
      truncated: lookup.truncated || limitTruncated,
      truncatedBefore: beforeTruncated,
      truncatedAfter: afterTruncated,
      replySupport: ReplySupport.unsupported,
    );
  }

  // --------------------------------------------------------------- history --

  /// Bidirectional history over one pair.
  ///
  /// Exactly one direction may be supplied: `afterPosition` reads forward from
  /// that exclusive cursor; `beforePosition` returns the up-to-[limit] messages
  /// immediately before it in ascending order. Both supplied is invalid. All
  /// results are ascending and de-duplicated by position.
  Future<HistoryPage> readHistory({
    required String peerAccount,
    int? afterPosition,
    int? beforePosition,
    int limit = 50,
  }) async {
    final AuthIdentity captured = _requireLogin();
    _requirePeer(captured, peerAccount);
    if (afterPosition != null && beforePosition != null) {
      throw _validation('before_position');
    }
    if ((afterPosition ?? 0) < 0 || (beforePosition ?? 0) < 0) {
      throw _validation('position');
    }
    final int pageSize = limit.clamp(1, maxPageSize);
    if (beforePosition == null) {
      final MessagePage page = await api.conversation(
        token: captured.token,
        account: peerAccount,
        afterPosition: afterPosition ?? 0,
        limit: pageSize,
      );
      if (!session.isCurrent(captured)) {
        throw staleIdentityFailure;
      }
      return HistoryPage(
        items: List<ChatMessage>.unmodifiable(page.items),
        hasMore: page.hasMore,
        truncated: false,
        order: HistoryOrder.ascending,
      );
    }

    if (beforePosition == 0) {
      return const HistoryPage(
        items: <ChatMessage>[],
        hasMore: false,
        truncated: false,
        order: HistoryOrder.ascending,
      );
    }
    final int scanBound = math.max(1, maxScanMessages);
    final List<ChatMessage> collected = <ChatMessage>[];
    int after = 0;
    int scanned = 0;
    bool truncated = false;
    while (true) {
      final MessagePage page = await api.conversation(
        token: captured.token,
        account: peerAccount,
        afterPosition: after,
        limit: maxPageSize,
      );
      if (!session.isCurrent(captured)) {
        throw staleIdentityFailure;
      }
      if (page.items.isEmpty) {
        break;
      }
      for (final ChatMessage message in page.items) {
        if (message.position >= beforePosition) {
          break;
        }
        scanned += 1;
        if (scanned > scanBound) {
          truncated = true;
          break;
        }
        collected.add(message);
      }
      if (truncated ||
          (page.items.isNotEmpty && page.items.last.position >= beforePosition) ||
          !page.hasMore) {
        break;
      }
      after = page.nextPosition;
    }
    _ensureCurrent(captured);
    final int from = math.max(0, collected.length - pageSize);
    return HistoryPage(
      items: List<ChatMessage>.unmodifiable(collected.sublist(from)),
      hasMore: from > 0,
      truncated: truncated,
      order: HistoryOrder.ascending,
    );
  }

  // ------------------------------------------------------------- internals --

  static final RegExp _accountPattern = RegExp(r'^[1-9][0-9]{7}$');

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

  void _requirePeer(AuthIdentity captured, String peerAccount) {
    if (!_accountPattern.hasMatch(peerAccount) ||
        peerAccount == captured.account) {
      // Same safe result as a message that does not exist or is not visible to
      // this account: never reveal whether a third-party conversation exists.
      throw const MessageNotVisible();
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

/// Safe miss for a peer outside the caller's allowed conversation scope.
class MessageNotVisible implements Exception {
  const MessageNotVisible();
}

enum ConversationUnread { none, unread, unknown }

class ConversationSummary {
  const ConversationSummary({
    required this.peer,
    this.lastMessage,
    this.lastActivityAt,
    this.unread = ConversationUnread.unknown,
    this.firstUnreadPosition,
  });

  final ChatUser peer;
  final UserPreview? lastMessage;
  final DateTime? lastActivityAt;
  final ConversationUnread unread;
  final int? firstUnreadPosition;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': peer.account,
    'username': peer.username,
    'last_message': lastMessage?.toJson(),
    'last_activity_at': lastActivityAt?.toIso8601String(),
    'unread': unread.name,
    if (firstUnreadPosition != null) 'first_unread_position': firstUnreadPosition,
  };
}

class ConversationPage {
  const ConversationPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<ConversationSummary> items;
  final String? nextCursor;
  final bool hasMore;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((ConversationSummary item) => item.toJson()).toList(),
    'next_cursor': nextCursor,
    'has_more': hasMore,
  };
}

class MessageLookup {
  const MessageLookup({required this.message, required this.truncated});

  final ChatMessage? message;
  final bool truncated;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message': message == null ? null : messageToJson(message!),
    'truncated': truncated,
  };
}

enum ReplySupport { unsupported }

class ContextResult {
  const ContextResult({
    required this.message,
    required this.items,
    required this.truncated,
    required this.truncatedBefore,
    required this.truncatedAfter,
    required this.replySupport,
  });

  final ChatMessage? message;
  final List<ChatMessage> items;
  final bool truncated;
  final bool truncatedBefore;
  final bool truncatedAfter;
  final ReplySupport replySupport;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message': message == null ? null : messageToJson(message!),
    'items': items.map(messageToJson).toList(),
    'truncated': truncated,
    'truncated_before': truncatedBefore,
    'truncated_after': truncatedAfter,
    // No reply relation exists in the current message facts.
    'replies': const <Object>[],
    'reply_support': replySupport.name,
  };
}

enum HistoryOrder { ascending }

class HistoryPage {
  const HistoryPage({
    required this.items,
    required this.hasMore,
    required this.truncated,
    required this.order,
  });

  final List<ChatMessage> items;
  final bool hasMore;
  final bool truncated;
  final HistoryOrder order;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map(messageToJson).toList(),
    'has_more': hasMore,
    'truncated': truncated,
    'order': order.name,
  };
}

/// Identity changed mid-query: the caller sees the contract's stale error
/// rather than a fabricated 401 or partial page.
const AuthFailure staleIdentityFailure = AuthFailure(
  status: 409,
  code: 'stale_identity',
  message: '身份已变化，请重新登录或显式重绑',
);

/// A caller-supplied consumer id that does not belong to the authenticated
/// account. Owner capability and revision validation are layered by the v2
/// route; this is the minimum service-level authorization.
const AuthFailure staleBindingFailure = AuthFailure(
  status: 409,
  code: 'stale_binding',
  message: '消费者能力或绑定不匹配',
);
