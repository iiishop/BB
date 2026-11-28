/// Non-visual state controllers for DEA-517 group mentions:
/// - Composer `@` fuzzy search, cursor-aware insertion, and BB account binding.
/// - Recipient unread mention summaries, foreground visibility `mark_seen`, and
///   reverse-ordered jump/context resolution.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import '../models/group_models.dart';
import '../models/mention_models.dart';
import 'auth_session.dart';
import 'client_identity.dart';
import 'group_service.dart';

/// One committed `@member` token inside the composer draft, bound to an
/// immutable 8-digit BB account rather than plain text matching.
@immutable
class MentionSpan {
  const MentionSpan({
    required this.start,
    required this.end,
    required this.account,
    required this.label,
  });

  final int start;
  final int end;
  final String account;
  final String label;

  MentionSpan shift(int delta) => MentionSpan(
    start: start + delta,
    end: end + delta,
    account: account,
    label: label,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MentionSpan &&
          start == other.start &&
          end == other.end &&
          account == other.account &&
          label == other.label;

  @override
  int get hashCode => Object.hash(start, end, account, label);
}

/// Active `@query` detected immediately before a collapsed caret.
@immutable
class ActiveMentionQuery {
  const ActiveMentionQuery({
    required this.triggerOffset,
    required this.cursorOffset,
    required this.query,
  });

  final int triggerOffset;
  final int cursorOffset;
  final String query;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveMentionQuery &&
          triggerOffset == other.triggerOffset &&
          cursorOffset == other.cursorOffset &&
          query == other.query;

  @override
  int get hashCode => Object.hash(triggerOffset, cursorOffset, query);
}

/// Non-visual composer state for `@` member search, keyboard navigation, and
/// tracked BB account mentions.
class GroupMentionComposerController extends ChangeNotifier {
  List<GroupMember> _members = const <GroupMember>[];
  List<MentionSpan> _spans = const <MentionSpan>[];
  ActiveMentionQuery? _activeQuery;
  List<GroupMember> _candidates = const <GroupMember>[];
  bool _pickerOpen = false;
  int _highlightedIndex = 0;
  int? _dismissedTriggerOffset;

  List<GroupMember> get members => _members;
  List<MentionSpan> get spans => _spans;
  ActiveMentionQuery? get activeQuery => _activeQuery;
  List<GroupMember> get candidates => _candidates;
  bool get pickerOpen => _pickerOpen;
  int get highlightedIndex => _highlightedIndex;

  GroupMember? get highlightedCandidate =>
      _pickerOpen &&
          _highlightedIndex >= 0 &&
          _highlightedIndex < _candidates.length
      ? _candidates[_highlightedIndex]
      : null;

  /// Unique BB accounts for committed mention spans, preserving first-seen
  /// order and capped at [mentionMaxRecipients].
  List<String> get uniqueMentionedAccounts {
    if (_spans.isEmpty) {
      return const <String>[];
    }
    final List<MentionSpan> ordered = List<MentionSpan>.of(_spans)
      ..sort((MentionSpan a, MentionSpan b) => a.start.compareTo(b.start));
    final List<String> accounts = <String>[];
    final Set<String> seen = <String>{};
    for (final MentionSpan span in ordered) {
      if (isValidAccount(span.account) && seen.add(span.account)) {
        accounts.add(span.account);
        if (accounts.length >= mentionMaxRecipients) {
          break;
        }
      }
    }
    return List<String>.unmodifiable(accounts);
  }

  void setMembers(List<GroupMember> members) {
    _members = List<GroupMember>.unmodifiable(members);
    if (_activeQuery != null) {
      _refreshCandidates(resetHighlight: false);
    }
    notifyListeners();
  }

  void restore({
    required TextEditingValue value,
    required List<MentionSpan> spans,
  }) {
    _spans = List<MentionSpan>.unmodifiable(
      spans.where(
        (MentionSpan s) =>
            s.start >= 0 &&
            s.end <= value.text.length &&
            s.start < s.end &&
            value.text.substring(s.start, s.end) == s.label,
      ),
    );
    _dismissedTriggerOffset = null;
    _updateQueryFromValue(value);
    notifyListeners();
  }

  void clear() {
    if (_spans.isEmpty &&
        _activeQuery == null &&
        !_pickerOpen &&
        _candidates.isEmpty &&
        _dismissedTriggerOffset == null) {
      return;
    }
    _spans = const <MentionSpan>[];
    _activeQuery = null;
    _candidates = const <GroupMember>[];
    _pickerOpen = false;
    _highlightedIndex = 0;
    _dismissedTriggerOffset = null;
    notifyListeners();
  }

  /// Reconciles committed mention spans and active `@query` across one editor
  /// change from [oldValue] to [newValue].
  void handleTextValueChanged(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (oldValue.text != newValue.text) {
      _spans = reconcileSpans(
        oldText: oldValue.text,
        newText: newValue.text,
        spans: _spans,
      );
    }
    _updateQueryFromValue(newValue);
    notifyListeners();
  }

  /// Selects [member] for the active `@query`, inserting `@username ` at the
  /// original cursor position and binding [member.account] to that span.
  TextEditingValue selectMember(
    GroupMember member,
    TextEditingValue currentValue,
  ) {
    final ActiveMentionQuery? active =
        _activeQuery ??
        detectActiveQuery(currentValue.text, currentValue.selection, _spans);
    if (active == null) {
      return currentValue;
    }
    final String inserted = '@${member.username} ';
    final int replaceLength = active.cursorOffset - active.triggerOffset;
    final int delta = inserted.length - replaceLength;
    final String nextText = currentValue.text.replaceRange(
      active.triggerOffset,
      active.cursorOffset,
      inserted,
    );
    final List<MentionSpan> nextSpans = <MentionSpan>[];
    for (final MentionSpan span in _spans) {
      if (span.end <= active.triggerOffset) {
        nextSpans.add(span);
      } else if (span.start >= active.cursorOffset) {
        nextSpans.add(span.shift(delta));
      }
    }
    nextSpans.add(
      MentionSpan(
        start: active.triggerOffset,
        end: active.triggerOffset + inserted.length,
        account: member.account,
        label: inserted,
      ),
    );
    nextSpans.sort(
      (MentionSpan a, MentionSpan b) => a.start.compareTo(b.start),
    );
    _spans = List<MentionSpan>.unmodifiable(nextSpans);
    _activeQuery = null;
    _candidates = const <GroupMember>[];
    _pickerOpen = false;
    _highlightedIndex = 0;
    _dismissedTriggerOffset = null;
    notifyListeners();
    return TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(
        offset: active.triggerOffset + inserted.length,
      ),
    );
  }

  void moveHighlightUp() {
    if (!_pickerOpen || _candidates.isEmpty) {
      return;
    }
    _highlightedIndex =
        (_highlightedIndex - 1 + _candidates.length) % _candidates.length;
    notifyListeners();
  }

  void moveHighlightDown() {
    if (!_pickerOpen || _candidates.isEmpty) {
      return;
    }
    _highlightedIndex = (_highlightedIndex + 1) % _candidates.length;
    notifyListeners();
  }

  void dismissPicker() {
    if (!_pickerOpen && _activeQuery == null) {
      return;
    }
    _dismissedTriggerOffset = _activeQuery?.triggerOffset;
    _pickerOpen = false;
    _highlightedIndex = 0;
    notifyListeners();
  }

  void _updateQueryFromValue(TextEditingValue value) {
    final ActiveMentionQuery? detected = detectActiveQuery(
      value.text,
      value.selection,
      _spans,
    );
    if (detected == null) {
      _activeQuery = null;
      _candidates = const <GroupMember>[];
      _pickerOpen = false;
      _highlightedIndex = 0;
      _dismissedTriggerOffset = null;
      return;
    }
    if (_dismissedTriggerOffset == detected.triggerOffset) {
      _activeQuery = detected;
      _pickerOpen = false;
      return;
    }
    final bool triggerChanged =
        _activeQuery?.triggerOffset != detected.triggerOffset ||
        _activeQuery?.query != detected.query;
    _dismissedTriggerOffset = null;
    _activeQuery = detected;
    _refreshCandidates(resetHighlight: triggerChanged);
    _pickerOpen = true;
  }

  void _refreshCandidates({required bool resetHighlight}) {
    final ActiveMentionQuery? active = _activeQuery;
    if (active == null) {
      _candidates = const <GroupMember>[];
      _highlightedIndex = 0;
      return;
    }
    _candidates = List<GroupMember>.unmodifiable(
      filterMembers(_members, active.query),
    );
    if (_candidates.isEmpty) {
      _highlightedIndex = 0;
    } else if (resetHighlight || _highlightedIndex >= _candidates.length) {
      _highlightedIndex = 0;
    }
  }

  /// Detects an active `@query` immediately preceding a collapsed cursor,
  /// stopping before newlines or committed [MentionSpan] ranges.
  static ActiveMentionQuery? detectActiveQuery(
    String text,
    TextSelection selection,
    List<MentionSpan> spans,
  ) {
    if (!selection.isValid || !selection.isCollapsed) {
      return null;
    }
    final int cursor = selection.baseOffset;
    if (cursor <= 0 || cursor > text.length) {
      return null;
    }
    for (final MentionSpan span in spans) {
      if (cursor > span.start && cursor <= span.end) {
        return null;
      }
    }
    for (int i = cursor - 1; i >= 0; i -= 1) {
      final int codeUnit = text.codeUnitAt(i);
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return null;
      }
      for (final MentionSpan span in spans) {
        if (i >= span.start && i < span.end) {
          return null;
        }
      }
      if (codeUnit == 0x40) {
        return ActiveMentionQuery(
          triggerOffset: i,
          cursorOffset: cursor,
          query: text.substring(i + 1, cursor),
        );
      }
    }
    return null;
  }

  /// Fuzzy-filters [members] by nickname substring, ordered rune subsequence
  /// (e.g. `星依` -> `星与星依`), or account substring.
  static List<GroupMember> filterMembers(
    List<GroupMember> members,
    String query,
  ) {
    final String normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return List<GroupMember>.of(members);
    }
    final List<({GroupMember member, int tier, int index, int order})> scored =
        <({GroupMember member, int tier, int index, int order})>[];
    for (int i = 0; i < members.length; i += 1) {
      final GroupMember member = members[i];
      final String username = member.username.toLowerCase();
      final int exactIdx = username.indexOf(normalized);
      if (exactIdx >= 0) {
        scored.add((member: member, tier: 0, index: exactIdx, order: i));
        continue;
      }
      final int? subseqStart = _subsequenceStart(username, normalized);
      if (subseqStart != null) {
        scored.add((member: member, tier: 1, index: subseqStart, order: i));
        continue;
      }
      final int accountIdx = member.account.indexOf(normalized);
      if (accountIdx >= 0) {
        scored.add((member: member, tier: 2, index: accountIdx, order: i));
      }
    }
    scored.sort((a, b) {
      final int byTier = a.tier.compareTo(b.tier);
      if (byTier != 0) return byTier;
      final int byIndex = a.index.compareTo(b.index);
      if (byIndex != 0) return byIndex;
      return a.order.compareTo(b.order);
    });
    return <GroupMember>[for (final entry in scored) entry.member];
  }

  static int? _subsequenceStart(String haystack, String needle) {
    final List<int> hRunes = haystack.runes.toList(growable: false);
    final List<int> nRunes = needle.runes.toList(growable: false);
    if (nRunes.isEmpty || nRunes.length > hRunes.length) {
      return null;
    }
    int ni = 0;
    int first = -1;
    for (int hi = 0; hi < hRunes.length && ni < nRunes.length; hi += 1) {
      if (hRunes[hi] == nRunes[ni]) {
        if (first < 0) {
          first = hi;
        }
        ni += 1;
      }
    }
    return ni == nRunes.length ? first : null;
  }

  /// Updates committed [spans] after editing [oldText] into [newText].
  /// Overlapping edits invalidate the touched span rather than binding stale
  /// accounts to edited text.
  static List<MentionSpan> reconcileSpans({
    required String oldText,
    required String newText,
    required List<MentionSpan> spans,
  }) {
    if (spans.isEmpty) {
      return const <MentionSpan>[];
    }
    final int minLen = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    int prefix = 0;
    while (prefix < minLen &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix += 1;
    }
    int suffix = 0;
    while (suffix < minLen - prefix &&
        oldText.codeUnitAt(oldText.length - 1 - suffix) ==
            newText.codeUnitAt(newText.length - 1 - suffix)) {
      suffix += 1;
    }
    final int oldEditStart = prefix;
    final int oldEditEnd = oldText.length - suffix;
    final int delta = newText.length - oldText.length;
    final List<MentionSpan> next = <MentionSpan>[];
    for (final MentionSpan span in spans) {
      if (span.end <= oldEditStart) {
        if (span.end <= newText.length &&
            newText.substring(span.start, span.end) == span.label) {
          next.add(span);
        }
      } else if (span.start >= oldEditEnd) {
        final MentionSpan shifted = span.shift(delta);
        if (shifted.start >= 0 &&
            shifted.end <= newText.length &&
            newText.substring(shifted.start, shifted.end) == shifted.label) {
          next.add(shifted);
        }
      }
    }
    return List<MentionSpan>.unmodifiable(next);
  }
}

/// Resolution result for jumping to the next unread alert in a conversation.
@immutable
class AlertJumpResolution {
  const AlertJumpResolution({required this.alert, this.context});

  final UnreadAlert alert;

  /// Populated via `GET /messages/{message_id}/context` when the target was
  /// not yet present in the loaded chat timeline; null when already loaded.
  final MessageContextRecord? context;
}

/// Coordinates per-account shared unread alert summaries (mentions + replies),
/// foreground-viewport `mark_seen`, and reverse-ordered jump target resolution.
class MentionRecipientController extends ChangeNotifier {
  MentionRecipientController({required this.shared}) {
    shared.access.addListener(_onAccessChanged);
  }

  final SharedConversationService shared;

  AuthIdentity? _boundIdentity;
  int _sessionEpoch = 0;
  bool _summaryLoadedOnce = false;
  bool _summaryInFlight = false;
  bool _summaryRetryQueued = false;

  final Map<String, ClientAlertSummary> _summaries =
      <String, ClientAlertSummary>{};
  final Map<String, int> _jumpCursors = <String, int>{};
  final Map<String, Set<String>> _submittedSeenIds = <String, Set<String>>{};
  final Map<String, Set<String>> _inFlightSeenIds = <String, Set<String>>{};
  final Map<String, List<ChatMessage>> _foregroundVisibleInbound =
      <String, List<ChatMessage>>{};

  bool get summaryLoadedOnce => _summaryLoadedOnce;

  Map<String, ClientAlertSummary> get summaries {
    _syncIdentity();
    return Map<String, ClientAlertSummary>.unmodifiable(_summaries);
  }

  AlertCounts countsFor(String conversationId) {
    _syncIdentity();
    return _summaries[conversationId]?.counts ??
        const AlertCounts(unreadMentionCount: 0, unreadReplyCount: 0);
  }

  int unreadMentionCountFor(String conversationId) =>
      countsFor(conversationId).unreadMentionCount;

  int unreadReplyCountFor(String conversationId) =>
      countsFor(conversationId).unreadReplyCount;

  bool hasUnreadMentions(String conversationId) =>
      unreadMentionCountFor(conversationId) > 0;

  bool hasUnreadReplies(String conversationId) =>
      unreadReplyCountFor(conversationId) > 0;

  bool hasUnreadAlerts(String conversationId) =>
      countsFor(conversationId).hasAny;

  UnreadAlert? latestAlertFor(String conversationId) {
    _syncIdentity();
    return _summaries[conversationId]?.latestAlert;
  }

  @override
  void dispose() {
    shared.access.removeListener(_onAccessChanged);
    _clearState();
    super.dispose();
  }

  /// Drops all in-memory pending display state for the prior session/account.
  void reset() {
    _clearState();
    notifyListeners();
  }

  void clearConversationJumpCursor(String conversationId) {
    _jumpCursors.remove(conversationId);
  }

  void _onAccessChanged() {
    final AuthIdentity? identity = _syncIdentity();
    if (identity == null) {
      return;
    }
    bool changed = false;
    final List<String> tracked = <String>{
      ..._summaries.keys,
      ..._jumpCursors.keys,
      ..._submittedSeenIds.keys,
      ..._foregroundVisibleInbound.keys,
    }.toList(growable: false);
    for (final String convId in tracked) {
      if (convId.startsWith('group:') &&
          shared.access.isRevoked(identity.account, convId)) {
        if (_dropConversationState(convId)) {
          changed = true;
        }
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  bool _dropConversationState(String conversationId) {
    final bool had =
        _summaries.remove(conversationId) != null ||
        _jumpCursors.remove(conversationId) != null ||
        _submittedSeenIds.remove(conversationId) != null ||
        _inFlightSeenIds.remove(conversationId) != null ||
        _foregroundVisibleInbound.remove(conversationId) != null;
    return had;
  }

  AuthIdentity? _syncIdentity() {
    final AuthIdentity? current = shared.session.identity;
    if (current == null) {
      if (_boundIdentity != null ||
          _summaries.isNotEmpty ||
          _summaryLoadedOnce) {
        _clearState();
        notifyListeners();
      }
      return null;
    }
    if (_boundIdentity == null || !_boundIdentity!.sameAs(current)) {
      _clearState();
      _boundIdentity = current;
      notifyListeners();
    }
    return current;
  }

  void _clearState() {
    _boundIdentity = null;
    _sessionEpoch += 1;
    _summaryLoadedOnce = false;
    _summaryInFlight = false;
    _summaryRetryQueued = false;
    _summaries.clear();
    _jumpCursors.clear();
    _submittedSeenIds.clear();
    _inFlightSeenIds.clear();
    _foregroundVisibleInbound.clear();
  }

  bool _isEpochCurrent(int epoch, AuthIdentity identity) =>
      _sessionEpoch == epoch && shared.session.isCurrent(identity);

  /// Refreshes per-conversation unread alert summaries from `/chat/alerts/summary`.
  Future<void> refreshSummary() async {
    final AuthIdentity? identity = _syncIdentity();
    if (identity == null) {
      return;
    }
    if (_summaryInFlight) {
      _summaryRetryQueued = true;
      return;
    }
    _summaryInFlight = true;
    final int epoch = _sessionEpoch;
    try {
      final List<ClientAlertSummary> items = await shared.listAllAlertSummaries(
        captured: identity,
      );
      if (!_isEpochCurrent(epoch, identity)) {
        return;
      }
      final Map<String, ClientAlertSummary> next = <String, ClientAlertSummary>{
        for (final ClientAlertSummary item in items)
          if (!item.conversation.isGroup ||
              !shared.access.isRevoked(identity.account, item.conversationId))
            item.conversationId: item,
      };
      _summaries
        ..clear()
        ..addAll(next);
      _summaryLoadedOnce = true;
      _jumpCursors.removeWhere(
        (String convId, int _) => !_summaries.containsKey(convId),
      );
      notifyListeners();
      for (final String convId in List<String>.of(_summaries.keys)) {
        final List<ChatMessage>? visible = _foregroundVisibleInbound[convId];
        if (visible != null && visible.isNotEmpty) {
          unawaited(
            reportVisibleMessages(
              conversation: ConversationRef.parseId(convId),
              visibleMessages: visible,
              isForegroundActive: true,
            ).then<void>((_) {}, onError: (Object _) {}),
          );
        }
      }
    } finally {
      _summaryInFlight = false;
      if (_summaryRetryQueued && _isEpochCurrent(epoch, identity)) {
        _summaryRetryQueued = false;
        unawaited(refreshSummary().then<void>((_) {}, onError: (Object _) {}));
      }
    }
  }

  /// Reports inbound messages that actually entered the foreground chat
  /// viewport. Hidden tabs, prefetching, or failed jumps must pass
  /// [isForegroundActive] = false or avoid calling this method.
  Future<AlertCounts?> reportVisibleMessages({
    required ConversationRef conversation,
    required Iterable<ChatMessage> visibleMessages,
    required bool isForegroundActive,
    bool forceCheckIfZero = false,
  }) async {
    final AuthIdentity? identity = _syncIdentity();
    if (identity == null) {
      return null;
    }
    if (!isForegroundActive ||
        (conversation.isGroup &&
            shared.access.isRevoked(identity.account, conversation.id))) {
      _foregroundVisibleInbound.remove(conversation.id);
      return null;
    }
    final int epoch = _sessionEpoch;
    final List<ChatMessage> inbound = <ChatMessage>[
      for (final ChatMessage message in visibleMessages)
        if (!message.isSystem &&
            message.senderAccount != identity.account &&
            message.resolveConversation(identity.account) == conversation &&
            isValidMentionMessageId(message.id))
          message,
    ];
    if (inbound.isEmpty) {
      return null;
    }
    _foregroundVisibleInbound[conversation.id] = List<ChatMessage>.unmodifiable(
      inbound,
    );
    if (!_summaryLoadedOnce) {
      await refreshSummary();
      if (!_isEpochCurrent(epoch, identity)) {
        return null;
      }
    }
    if (!forceCheckIfZero && !hasUnreadAlerts(conversation.id)) {
      return null;
    }
    final Set<String> submitted = _submittedSeenIds.putIfAbsent(
      conversation.id,
      () => <String>{},
    );
    final Set<String> inFlight = _inFlightSeenIds.putIfAbsent(
      conversation.id,
      () => <String>{},
    );
    final List<String> pendingIds = <String>[];
    final Set<String> batchSet = <String>{};
    for (final ChatMessage message in inbound) {
      if (!submitted.contains(message.id) &&
          !inFlight.contains(message.id) &&
          batchSet.add(message.id)) {
        pendingIds.add(message.id);
      }
    }
    if (pendingIds.isEmpty) {
      return null;
    }
    inFlight.addAll(pendingIds);
    try {
      final AlertCounts counts = await shared.markConversationAlertsSeen(
        conversation: conversation,
        messageIds: pendingIds,
        captured: identity,
      );
      if (!_isEpochCurrent(epoch, identity) ||
          (conversation.isGroup &&
              shared.access.isRevoked(identity.account, conversation.id))) {
        return null;
      }
      submitted.addAll(pendingIds);
      _applyCounts(conversation.id, counts);
      return counts;
    } finally {
      inFlight.removeAll(pendingIds);
    }
  }

  void _applyCounts(String conversationId, AlertCounts counts) {
    if (!counts.hasAny) {
      _summaries.remove(conversationId);
      _jumpCursors.remove(conversationId);
    } else {
      final ClientAlertSummary? existing = _summaries[conversationId];
      _summaries[conversationId] = existing == null
          ? ClientAlertSummary(
              conversationId: conversationId,
              displayName: '',
              unreadMentionCount: counts.unreadMentionCount,
              unreadReplyCount: counts.unreadReplyCount,
              latestAlert: const UnreadAlert(
                messageId: 'pending',
                position: 1,
                mention: false,
                reply: false,
              ),
            )
          : existing.copyWith(
              unreadMentionCount: counts.unreadMentionCount,
              unreadReplyCount: counts.unreadReplyCount,
            );
    }
    notifyListeners();
  }

  /// Resolves the next unread alert in [conversation] from newest to oldest
  /// via `/chat/alerts/list`, and fetches `/messages/{id}/context` when the
  /// target is not in [loadedMessageIds]. Does NOT call `mark_seen`; caller
  /// marks seen only after the target actually renders inside the foreground
  /// viewport.
  Future<AlertJumpResolution?> resolveNextJumpTarget({
    required ConversationRef conversation,
    required Set<String> loadedMessageIds,
    bool resetCursor = false,
  }) async {
    final AuthIdentity? identity = _syncIdentity();
    if (identity == null) {
      throw unauthenticated;
    }
    if (conversation.isGroup &&
        shared.access.isRevoked(identity.account, conversation.id)) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '已无权查看该群未读提醒',
      );
    }
    final int epoch = _sessionEpoch;
    final int? beforePosition = resetCursor
        ? null
        : _jumpCursors[conversation.id];
    AlertPage page = await shared.listConversationAlerts(
      conversation: conversation,
      beforePosition: beforePosition,
      limit: 1,
      captured: identity,
    );
    if (!_isEpochCurrent(epoch, identity)) {
      throw staleIdentity;
    }
    if (page.items.isEmpty && beforePosition != null) {
      page = await shared.listConversationAlerts(
        conversation: conversation,
        beforePosition: null,
        limit: 1,
        captured: identity,
      );
      if (!_isEpochCurrent(epoch, identity)) {
        throw staleIdentity;
      }
    }
    if (page.items.isEmpty) {
      _applyCounts(
        conversation.id,
        const AlertCounts(unreadMentionCount: 0, unreadReplyCount: 0),
      );
      return null;
    }
    final UnreadAlert target = page.items.first;
    MessageContextRecord? context;
    if (!loadedMessageIds.contains(target.messageId)) {
      context = await shared.loadMessageContext(
        conversation: conversation,
        messageId: target.messageId,
        captured: identity,
      );
      if (!_isEpochCurrent(epoch, identity)) {
        throw staleIdentity;
      }
      if (context == null ||
          !context.items.any(
            (ChatMessage message) => message.id == target.messageId,
          )) {
        throw const AuthFailure(
          status: 404,
          code: 'not_found',
          message: '无法定位该未读提醒消息',
        );
      }
    }
    _jumpCursors[conversation.id] = target.position;
    return AlertJumpResolution(alert: target, context: context);
  }
}
