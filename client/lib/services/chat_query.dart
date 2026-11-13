import 'dart:math' as math;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
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
    final ConversationRecordPage page = await api.conversations(
      token: captured.token,
      afterAccount: afterAccount,
      limit: limit,
    );
    _ensureCurrent(captured);
    final List<ConversationSummary> items = <ConversationSummary>[];
    for (final ConversationRecord row in page.items) {
      final int consumed = await ledger.consumedThrough(
        captured.account,
        row.peerAccount,
        consumerId: consumerId,
      );
      _ensureCurrent(captured);
      items.add(
        ConversationSummary(
          peerAccount: row.peerAccount,
          lastMessage: row.lastMessage,
          lastActivityAt: row.lastActivityAt,
          latestPosition: row.latestPosition,
          consumedThrough: consumed,
          unconsumedPositions: math.max(0, row.latestPosition - consumed),
        ),
      );
    }
    _ensureCurrent(captured);
    return ConversationPage(
      items: List<ConversationSummary>.unmodifiable(items),
      nextCursor: page.nextCursor,
    );
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
    return ContextResult(
      items: record.items,
      anchorMessageId: record.anchorMessageId,
      peerAccount: record.peerAccount,
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
  });

  final String peerAccount;
  final ChatMessage lastMessage;
  final DateTime lastActivityAt;
  final int latestPosition;
  final int consumedThrough;
  final int unconsumedPositions;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'peer_account': peerAccount,
    'last_message': messageToJson(lastMessage),
    'last_activity_at': lastActivityAt.toIso8601String(),
    'latest_position': latestPosition,
    'consumed_through': consumedThrough,
    'unconsumed_positions': unconsumedPositions,
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
