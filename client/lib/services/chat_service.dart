import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show Uint8List;

import '../config/media_policy.dart';
import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'install_safety_gate.dart';
import 'chat_api_client.dart';
import 'chat_delivery_remote.dart';
import 'chat_ledger.dart';
import 'chat_query.dart';
import 'client_identity.dart';
import 'download_manager.dart';
import 'conversation_access.dart';
import 'event_feed.dart';
import 'group_api_client.dart';
import 'group_service.dart';
import 'media_source.dart';
import 'media_stream_proxy.dart';

/// One ordered body draft segment supplied by the UI or the local API.
sealed class OutgoingPart {
  const OutgoingPart();

  MessagePart toWirePart(String? mediaId);
}

class OutgoingText extends OutgoingPart {
  const OutgoingText(this.text);

  final String text;

  @override
  MessagePart toWirePart(String? mediaId) => TextPart(text);
}

class OutgoingImage extends OutgoingPart {
  const OutgoingImage(this.source);

  final MediaSource source;

  @override
  MessagePart toWirePart(String? mediaId) {
    if (mediaId == null || mediaId.isEmpty) {
      throw StateError('image part has no resolved media id');
    }
    return ImagePart(mediaId);
  }
}

/// One independent attachment item.
class OutgoingAttachment {
  const OutgoingAttachment({required this.source, this.cover});

  final MediaSource source;
  final MediaSource? cover;
}

class SendOutcome {
  const SendOutcome({
    required this.operationId,
    this.message,
    this.failure,
    this.part,
    this.attachment,
  });

  final String operationId;
  final ChatMessage? message;
  final AuthFailure? failure;

  /// Original body part (body sends only) for a retry.
  final List<OutgoingPart>? part;

  /// Original attachment (attachment sends only) for a retry.
  final OutgoingAttachment? attachment;

  bool get succeeded => message != null;
}

class ComposedSendResult {
  const ComposedSendResult({
    required this.body,
    required this.attachments,
    required this.operationSeed,
  });

  final SendOutcome? body;
  final List<SendOutcome> attachments;
  final String operationSeed;

  bool get allSucceeded =>
      (body == null || body!.succeeded) &&
      attachments.every((SendOutcome item) => item.succeeded);

  bool get anySucceeded =>
      (body?.succeeded ?? false) ||
      attachments.any((SendOutcome item) => item.succeeded);
}

/// Preview bytes plus whether they are the bounded derivative or the original.
class MediaPreview {
  const MediaPreview({required this.bytes, required this.isDerivative});

  final Uint8List bytes;
  final bool isDerivative;
}

/// Pure-Dart STEP-3 client service shared by the Flutter UI and the local
/// control API.
///
/// It owns credentials use (never exposure), ordered sending, durable
/// operation/download/display ledgers, the event feed, and consumption ACKs.
class ChatService {
  ChatService({
    required this.api,
    required this.session,
    required this.ledger,
    required Directory cacheRoot,
    MediaSourceResolver? resolver,
    VideoCoverExtractor? coverExtractor,
    DateTime Function()? clock,
    this.eventPollInterval = const Duration(seconds: 2),
    bool webSocketHints = true,
    this.beforeCommit,
  }) : _resolver = resolver ?? MediaSourceResolver(),
       _coverExtractor = coverExtractor ?? FfmpegVideoCoverExtractor(),
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    eventFeed = EventFeed(
      api: api,
      session: session,
      ledger: ledger,
      deliveryRemote: deliveryRemote,
      onGroupEvent: (account, event) => sharedConversations.applyServerEvent(account, event),
      pollInterval: eventPollInterval,
      webSocketHints: webSocketHints,
    );
    downloads = DownloadManager(
      api: api,
      session: session,
      ledger: ledger,
      cacheRoot: cacheRoot,
      onEvent: (LocalEvent event) => eventFeed.deliverPendingFor(event.account),
    );
    mediaStreams = MediaStreamProxy(api: api, session: session);
  }

  final ChatApiClient api;
  final AuthSession session;
  final ChatLedger ledger;
  final MediaSourceResolver _resolver;
  final VideoCoverExtractor _coverExtractor;
  final DateTime Function() _clock;
  final Duration eventPollInterval;

  /// Fault-injection seam for the identity-check → durable-write window. It is
  /// null in production; tests use it to switch the session at the exact
  /// commit point and prove the watermark is not written.
  final Future<void> Function()? beforeCommit;

  final _groupAccess = ConversationAccessController();
  late final SharedConversationService sharedConversations = SharedConversationService(
    api: api, session: session, access: _groupAccess, resolver: _resolver,
  );
  late final GroupService groups = GroupService(
    api: GroupApiClient(baseUri: api.baseUri, timeout: api.timeout, transport: api.transport),
    session: session,
    access: _groupAccess,
  );
  late final ChatDeliveryRemote deliveryRemote = ChatDeliveryRemote(api);
  late final EventFeed eventFeed;
  late DownloadManager downloads;
  late MediaStreamProxy mediaStreams;

  /// Unified conversation/message/context queries (shared v2 query routes will
  /// delegate here once Forge's schema lands).
  late final ChatQueryService query = ChatQueryService(
    api: api,
    session: session,
    ledger: ledger,
  );

  final Map<String, Uint8List> _mediaCache = <String, Uint8List>{};
  final List<String> _mediaCacheOrder = <String>[];
  static const int _maxCachedMediaEntries = 48;
  static const int _maxCachedMediaBytes = 6 * 1024 * 1024;

  /// Thumbnail bytes are cached separately from originals (DEA-471): a cache
  /// key always carries server/account/media and never mixes with avatars.
  final Map<String, Uint8List> _thumbnailCache = <String, Uint8List>{};
  final List<String> _thumbnailCacheOrder = <String>[];
  static const int _maxCachedThumbnailEntries = 96;
  static const int _maxCachedThumbnailBytes = 4 * 1024 * 1024;

  /// Immutable media metadata (byte_size, mime, filename) by server/account.
  final Map<String, Attachment> _mediaMetadata = <String, Attachment>{};
  final List<String> _mediaMetadataOrder = <String>[];
  static const int _maxCachedMetadataEntries = 256;

  /// Starts the durable event poller. Safe to call repeatedly.
  void start() => eventFeed.start();

  /// Re-arms origin-account work after a login/restore/switch: pending
  /// download terminal events and their feeds are recovered for the account
  /// that is authenticated now.
  Future<void> resumeForCurrentSession() async {
    if (session.identity == null) {
      return;
    }
    await downloads.resumePending();
    await eventFeed.pollOnce();
  }

  Future<void> dispose() async {
    sharedConversations.dispose();
    await eventFeed.dispose();
    await downloads.dispose();
    await mediaStreams.close();
  }

  String get selfAccount {
    final AuthUser? user = session.user;
    if (user == null || !session.hasToken) {
      throw unauthenticated;
    }
    return user.account;
  }

  /// Stable client consumer for human/UI-originated work on an account.
  static String _humanSession(String account) => 'human:$account';

  /// Strict v2 identity check at the business linearization point.
  ///
  /// Order: logged in → account/auth generation → stored consumer binding.
  /// The request identity must be exactly the stored binding snapshot; mixing
  /// a current generation with an old revision is a binding conflict.
  Future<({AuthIdentity identity, ConsumerBinding binding})> requireIdentity(
    ExpectedIdentity expected,
  ) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    if (expected.account != captured.account ||
        expected.authGeneration != captured.authGeneration) {
      throw staleIdentity;
    }
    final ConsumerBinding? binding = await ledger.bindingById(
      expected.consumerId,
    );
    // The ledger lock is an await point: a concurrent login can replace the
    // session while the request waits. Never return a captured identity that
    // is no longer current; all upstream work must use this same snapshot.
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    if (binding == null || binding.account != captured.account) {
      throw staleBinding('消费者能力或归属不匹配');
    }
    if (!expected.matches(binding.identity)) {
      throw staleBinding('消费者绑定版本已变化');
    }
    return (identity: captured, binding: binding);
  }

  /// v2 owner enrollment. The owner key itself never reaches this layer; only
  /// its hash is persisted before the consumer exists.
  Future<ConsumerBinding> enrollConsumer({
    required String ownerKeyHash,
    required String sessionId,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    return ledger.enrollConsumer(
      account: captured.account,
      authGeneration: captured.authGeneration,
      ownerKeyHash: ownerKeyHash,
      sessionId: sessionId,
    );
  }

  Future<ConsumerBinding> consumerForOwner({
    required String ownerKeyHash,
    required String consumerId,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    return ledger.consumerForOwner(
      account: captured.account,
      ownerKeyHash: ownerKeyHash,
      consumerId: consumerId,
    );
  }

  Future<ConsumerBinding> bindConsumerOwner({
    required String ownerKeyHash,
    required String consumerId,
    required int expectedBindingRevision,
    required String sessionId,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    return ledger.bindConsumerOwner(
      account: captured.account,
      authGeneration: captured.authGeneration,
      ownerKeyHash: ownerKeyHash,
      consumerId: consumerId,
      expectedBindingRevision: expectedBindingRevision,
      sessionId: sessionId,
    );
  }

  /// Consumer-scoped consumption watermark.
  Future<int> consumptionFor({
    required ExpectedIdentity expectedIdentity,
    required String peerAccount,
  }) async {
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await requireIdentity(expectedIdentity);
    if (!isGroupId(peerAccount)) {
      return ledger.consumedThrough(
        context.identity.account, peerAccount, consumerId: context.binding.consumerId);
    }
    final member = await requireGroup(context.identity, peerAccount);
    final stored = await ledger.consumedThrough(context.identity.account,
      groupConsumptionKey(peerAccount, member.membershipRevision),
      consumerId: context.binding.consumerId);
    await requireIdentity(expectedIdentity);
    return max(stored, member.historyThrough);
  }

  /// v2 operation lookup scoped to the requesting consumer.
  ///
  /// A plan belongs to the consumer that accepted it: another consumer of the
  /// same account gets `null` (404) and never reaches the server idempotency
  /// record, so old results cannot leak sideways.
  Future<OperationResult?> operationForIdentity(
    ExpectedIdentity expectedIdentity,
    String operationId,
  ) async {
    _validateOperationId(operationId);
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await requireIdentity(expectedIdentity);
    final String account = context.identity.account;
    final ChatOperationRecord? record = await ledger.operation(
      account,
      operationId,
    );
    if (record == null) {
      return null;
    }
    final ExpectedIdentity? owner = record.expectedIdentity;
    if (owner == null || owner.consumerId != expectedIdentity.consumerId) {
      return null;
    }
    final group = isGroupId(record.targetAccount)
        ? await requireGroup(context.identity, record.targetAccount) : null;
    final result = await _queryMessageOperation(
      context.identity,
      operationId,
      record: record,
      exposeUncertain: true,
    );
    await requireSameGroupMembership(context.identity, group);
    await requireIdentity(expectedIdentity);
    return result;
  }

  Future<Map<String, dynamic>> notificationChanges({
    required ExpectedIdentity expectedIdentity,
    required int afterCursor,
    int? throughCursor,
    List<int> retryCursors = const [],
    int limit = 100,
  }) async {
    final context = await requireIdentity(expectedIdentity);
    final account = context.identity.account;
    final settings = await ledger.notificationSettings(account);
    final int available = await ledger.localEventHead(account, expectedIdentity.consumerId);
    final int head = throughCursor ?? available;
    if (afterCursor < 0 || head < afterCursor || head > available) {
      throw const AuthFailure(status: 422, code: 'validation_error', message: 'Invalid notification cursor range.');
    }
    final displayed = await ledger.displayedMessageIds(account);
    final page = await ledger.readLocalEvents(account: account,
      consumerSession: expectedIdentity.consumerId, afterCursor: afterCursor, limit: limit);
    final fresh = page.items.where((e) => e.cursor <= head).toList();
    final entries = [...fresh];
    if (retryCursors.length > 100 || retryCursors.any((c) => c < 1 || c > afterCursor)) {
      throw const AuthFailure(status: 422, code: 'validation_error', message: 'Invalid retry cursor.');
    }
    for (final cursor in retryCursors.toSet()) {
      final retry = await ledger.readLocalEvents(account: account, consumerSession: expectedIdentity.consumerId, afterCursor: cursor - 1, limit: 1);
      if (retry.items.isNotEmpty && retry.items.first.cursor == cursor) entries.add(retry.items.first);
    }
    final List<Map<String, dynamic>> deferred = [];
    bool localFailure(AuthFailure f) => const {'not_found', 'upstream_unavailable', 'upstream_timeout', 'network_error'}.contains(f.code);
    final Map<String, String> failedPeers = {};
    final Map<String, Map<String, dynamic>> changes = {};
    if (settings['enabled'] == true) {
      for (final entry in entries) {
        final event = entry.event;
        if (event.type != LocalEventType.messageAvailable || event.peerAccount == null || event.position == null) continue;
        final source = int.tryParse(event.eventId.replaceFirst('server:', ''));
        if (source == null) throw const FormatException('invalid notification source');
        if (source <= (settings['skip_source_through'] as int)) continue;
        // Durable v1 local events deliberately store peer/position, not bodies or
        // message IDs. Resolve exactly that authoritative position (also works
        // for migrated feeds); never turn this lookup into a display receipt.
        if (failedPeers.containsKey(event.peerAccount)) continue;
        MessagePage history;
        try {
          history = await api.conversation(token: context.identity.token,
            account: event.peerAccount!, afterPosition: event.position! - 1, limit: 1);
        } on AuthFailure catch (failure) {
          if (!localFailure(failure)) rethrow;
          failedPeers[event.peerAccount!] = failure.code;
          continue;
        }
        if (history.items.isEmpty || history.items.first.position != event.position) continue;
        final message = history.items.first;
        if (displayed.contains(message.id)) continue;
        if (message.targetAccount != account) continue;
        final peer = message.senderAccount;
        final row = changes.putIfAbsent(peer, () => <String, dynamic>{
          'conversation': directConversation(account, peer), 'peer_account': peer,
          'display_name': peer, 'new_count': 0, 'incoming_unread': 0,
          'last_message': messagePreview(message),
        });
        row['new_count'] = (row['new_count'] as int) + 1;
        if (message.position > ((row['last_message'] as Map<String, dynamic>)['position'] as int)) row['last_message'] = messagePreview(message);
      }
      // Reuse the sole account-unread implementation; no notification-specific
      // read database. No change means no history query on an idle heartbeat.
      if (changes.isNotEmpty) {
        String after = '';
        do {
          final summaries = await api.conversations(token: context.identity.token, afterAccount: after, limit: 100);
          for (final row in summaries.items) {
            if (!changes.containsKey(row.peerAccount) || failedPeers.containsKey(row.peerAccount)) continue;
            try {
              final summary = await query.summarizeConversation(captured: context.identity, row: row,
                consumerId: expectedIdentity.consumerId, displayed: displayed);
              changes[row.peerAccount]?['incoming_unread'] = summary.incomingUnread;
              changes[row.peerAccount]?['display_name'] = summary.displayName;
            } on AuthFailure catch (failure) {
              if (!localFailure(failure)) rethrow;
              failedPeers[row.peerAccount] = failure.code;
            }
          }
          if (summaries.nextCursor == null) break;
          after = summaries.nextCursor!;
        } while (true);
      }
    }
    final businessNotices = settings['enabled'] == true
        ? await _businessNoticeChanges(context.identity, entries, settings['skip_source_through'] as int)
        : null;
    if (settings['enabled'] == true) {
      await _groupNotificationChanges(
        context.identity,
        expectedIdentity.consumerId,
        entries,
        settings['skip_source_through'] as int,
        displayed,
        changes,
        deferred,
      );
    }
    for (final peer in failedPeers.keys) { changes.remove(peer); }
    for (final entry in entries) {
      final code = failedPeers[entry.event.peerAccount];
      if (code != null) deferred.add({'cursor': entry.cursor, 'peer_account': entry.event.peerAccount, 'error_code': code});
    }
    await requireIdentity(expectedIdentity);
    final current = await ledger.notificationSettings(account);
    if (current['revision'] != settings['revision']) {
      // Discard the sampled metadata; the caller retries from its old cursor.
      return <String, dynamic>{'settings': current, 'items': <dynamic>[], 'deferred': <dynamic>[],
        'next_cursor': afterCursor, 'through_cursor': head, 'has_more': afterCursor < head};
    }
    final int next = settings['enabled'] == false ? head : fresh.isEmpty ? head : fresh.last.cursor;
    return <String, dynamic>{'settings': settings, 'items': changes.values.toList(), 'deferred': deferred,
      'business_notices': ?businessNotices,
      'next_cursor': next, 'through_cursor': head, 'has_more': next < head};
  }

  int _sourcePosition(LocalEvent event) {
    final value = int.tryParse(event.eventId.replaceFirst('server:', ''));
    if (value == null || value < 1) throw upstreamMalformed;
    return value;
  }

  Future<Map<String, dynamic>?> _businessNoticeChanges(
    AuthIdentity captured,
    List<LocalEventEntry> entries,
    int skipThrough,
  ) async {
    final sources = <String, int>{};
    for (final entry in entries) {
      final event = entry.event;
      if (event.type != LocalEventType.notificationAvailable) continue;
      final position = _sourcePosition(event);
      if (position > skipThrough) sources[event.notificationId!] = position;
    }
    if (sources.isEmpty) return null;
    Map<String, dynamic>? latest;
    var latestSource = 0;
    var count = 0;
    int? unread;
    int? pending;
    String? cursor;
    final seen = <String>{};
    do {
      final page = await groups.listNotices(captured: captured, cursor: cursor, limit: 100);
      unread ??= page.unreadCount;
      pending ??= page.pendingCount;
      for (final notice in page.items) {
        final id = notice.id;
        if (!seen.add(id)) continue;
        final source = sources[id];
        if (source == null) continue;
        count++;
        if (source <= latestSource) continue;
        final type = notice.type, text = notice.text;
        final preview = text.runes.take(161).toList();
        latest = {
          'notification_id': id,
          'type': type,
          'text': String.fromCharCodes(preview.take(160)),
          'truncated': preview.length > 160,
        };
        latestSource = source;
      }
      final next = page.nextCursor;
      if (next == null || count == sources.length) break;
      if (next == cursor) throw upstreamMalformed;
      cursor = next;
    } while (true);
    if (latest == null) return null;
    return {
      'new_count': count,
      'unread_count': unread,
      'pending_count': pending,
      'last_notice': latest,
    };
  }

  final _sharedConversationSnapshots = <String, _SharedConversationSnapshot>{};

  Future<Map<String, dynamic>> listConversationsFor(
    AuthIdentity captured,
    ExpectedIdentity expected, {
    required String afterAccount,
    required int limit,
    required String order,
    required bool unreadOnly,
    String? cursor,
  }) async {
    Future<ConversationPage> direct({String? next, int? pageSize}) =>
        query.listConversations(
          afterAccount: afterAccount, consumerId: expected.consumerId,
          order: order, unreadOnly: unreadOnly, cursor: next, limit: pageSize ?? limit,
        );
    final snapshot = cursor == null ? null : _sharedConversationSnapshots[cursor];
    if (snapshot != null) {
      if (!expected.matches(snapshot.identity) || snapshot.order != order ||
          snapshot.unreadOnly != unreadOnly || !DateTime.now().isBefore(snapshot.expires)) {
        throw _validation('cursor 无效');
      }
      return _sharedConversationPage(captured, snapshot, limit);
    }
    if (afterAccount.isNotEmpty || cursor != null) {
      return (await direct(next: cursor)).toJson();
    }
    Map<String, GroupConversationItem> members;
    try {
      members = await _activeGroups(captured);
    } on AuthFailure catch (failure) {
      // An older BB server can still serve the existing direct-chat API.
      if (failure.status != 404) rethrow;
      members = {};
    }
    if (members.isEmpty) return (await direct()).toJson();
    final rows = <Map<String, dynamic>>[];
    String? next;
    var after = '';
    do {
      final page = await query.listConversations(
        afterAccount: after, consumerId: expected.consumerId, order: order,
        unreadOnly: unreadOnly, cursor: next, limit: 100,
      );
      rows.addAll(page.items.map((row) => row.toJson()));
      next = page.nextCursor;
      if (next == null) break;
      if (order == 'account' && !unreadOnly) {
        if (next.compareTo(after) <= 0) throw upstreamMalformed;
        after = next;
        next = null;
      }
    } while (true);
    final displayed = await ledger.displayedMessageIds(expected.account);
    for (final member in members.values) {
      try {
        final row = await summarizeGroup(captured, member, expected.consumerId, displayed);
        if (!unreadOnly || row['incoming_unread'] != 0) rows.add(row);
      } on AuthFailure catch (failure) {
        if (!const {'forbidden', 'not_found', 'group_unavailable'}.contains(failure.code)) {
          rethrow;
        }
      }
    }
    String key(Map<String, dynamic> row) => (row['conversation'] as Map)['id'] as String;
    rows.sort((first, second) {
      if (order == 'recent') {
        final time = DateTime.parse(second['last_activity_at'] as String)
            .compareTo(DateTime.parse(first['last_activity_at'] as String));
        if (time != 0) return time;
      }
      return key(first).compareTo(key(second));
    });
    return _sharedConversationPage(captured, _SharedConversationSnapshot(
      identity: expected, order: order, unreadOnly: unreadOnly, rows: rows,
      expires: DateTime.now().add(const Duration(minutes: 5)),
    ), limit);
  }

  Future<Map<String, dynamic>> _sharedConversationPage(
    AuthIdentity captured,
    _SharedConversationSnapshot snapshot,
    int limit,
  ) async {
    final groupIds = <String>{
      for (final row in snapshot.rows)
        if (row['membership_revision'] != null) (row['conversation'] as Map)['id'] as String,
    };
    final current = await _activeGroups(captured, ids: groupIds);
    final rows = snapshot.rows.where((row) {
      final revision = row['membership_revision'];
      return revision == null || current[(row['conversation'] as Map)['id']]?.membershipRevision == revision;
    }).toList();
    String? next;
    if (rows.length > limit) {
      final now = DateTime.now();
      _sharedConversationSnapshots.removeWhere((_, value) => !now.isBefore(value.expires));
      if (_sharedConversationSnapshots.length >= 32) {
        _sharedConversationSnapshots.remove(_sharedConversationSnapshots.keys.first);
      }
      next = newConsumerId();
      _sharedConversationSnapshots[next] = _SharedConversationSnapshot(
        identity: snapshot.identity, order: snapshot.order,
        unreadOnly: snapshot.unreadOnly, expires: snapshot.expires, rows: rows.sublist(limit),
      );
    }
    return {'items': rows.take(limit).toList(), 'next_cursor': next};
  }

  Future<Map<String, GroupConversationItem>> _activeGroups(
    AuthIdentity captured, {
    Set<String>? ids,
  }) async {
    if (ids?.isEmpty ?? false) return {};
    final result = <String, GroupConversationItem>{};
    var after = '';
    do {
      final page = await sharedConversations.listSharedConversations(
        captured: captured, afterId: after, limit: 100);
      for (final row in page.items.whereType<GroupConversationItem>()) {
        final id = row.conversation.id;
        if (ids == null || ids.contains(id)) result[id] = row;
      }
      if (ids != null && result.length == ids.length) break;
      final next = page.nextCursor;
      if (next == null) break;
      if (next.compareTo(after) <= 0) throw upstreamMalformed;
      after = next;
    } while (true);
    return result;
  }

  Future<GroupConversationItem> requireGroup(AuthIdentity captured, String id) async {
    final current = await _activeGroups(captured, ids: {id});
    if (!session.isCurrent(captured)) throw staleIdentity;
    return current[id] ?? (throw const AuthFailure(
      status: 404, code: 'not_found', message: '群会话当前不可访问'));
  }

  Future<void> requireSameGroupMembership(AuthIdentity captured, GroupConversationItem? group) async {
    if (group == null) return;
    final current = await requireGroup(captured, group.conversation.id);
    if (current.membershipRevision != group.membershipRevision) {
      throw staleBinding('群成员身份已变化');
    }
  }

  static String groupConsumptionKey(String group, int revision) => '$group@$revision';

  Future<Map<String, dynamic>> summarizeGroup(
    AuthIdentity captured,
    GroupConversationItem membership,
    String consumer,
    Set<String> displayed, {
    void Function(ChatMessage)? onUnread,
  }) async {
    final group = membership.conversation.id;
    final boundary = membership.historyThrough;
    final revision = membership.membershipRevision;
    final latest = membership.latestPosition;
    if (latest < boundary) throw upstreamMalformed;
    final stored = await ledger.consumedThrough(captured.account,
      groupConsumptionKey(group, revision), consumerId: consumer);
    final consumed = max(boundary, stored);
    var unread = 0;
    var position = boundary;
    Map<String, dynamic>? preview;
    while (position < latest) {
      final page = await sharedConversations.loadConversationHistory(captured: captured,
        conversation: membership.conversation, afterPosition: position, limit: 100);
      for (final message in page.items) {
        if (message.position > latest) break;
        if (message.position <= boundary || message.isSystem ||
            message.senderAccount == captured.account || displayed.contains(message.id)) {
          continue;
        }
        unread++;
        preview = messagePreview(message);
        onUnread?.call(message);
      }
      if (!page.hasMore) break;
      if (page.nextPosition <= position) throw upstreamMalformed;
      position = page.nextPosition;
    }
    return {
      'conversation': membership.conversation.toJson(),
      'display_name': membership.displayName,
      'last_message': membership.lastMessage == null ? null : messageToJson(membership.lastMessage!),
      'last_activity_at': membership.lastActivityAt.toUtc().toIso8601String(),
      'latest_position': latest,
      'group_number': membership.groupNumber,
      'history_through': boundary,
      'membership_revision': revision,
      'avatar_url': membership.avatarUrl,
      'avatar_version': membership.avatarVersion,
      'consumed_through': consumed,
      'unconsumed_positions': max(0, latest - consumed),
      'incoming_unread': unread,
      'latest_unread': preview,
    };
  }

  Future<Map<String, dynamic>> groupHistoryFor({
    required ExpectedIdentity expected,
    required String group,
    int? after,
    int? before,
    int limit = 50,
    bool unreadOnly = false,
    Set<String>? createdReceiptIds,
    int? membershipRevision,
  }) async {
    final context = await requireIdentity(expected);
    final membership = await requireGroup(context.identity, group);
    final revision = membership.membershipRevision;
    final historyThrough = membership.historyThrough;
    if (membershipRevision != null && revision != membershipRevision) {
      throw staleBinding('群成员身份已变化');
    }
    final page = await sharedConversations.loadConversationHistory(captured: context.identity,
      conversation: membership.conversation, afterPosition: after, beforePosition: before, limit: limit);
    final displayed = unreadOnly ? await ledger.displayedMessageIds(expected.account) : null;
    final items = <Map<String, dynamic>>[];
    for (final message in page.items) {
      if (displayed != null && (message.position <= historyThrough ||
          message.isSystem || message.senderAccount == expected.account ||
          displayed.contains(message.id))) {
        continue;
      }
      final visible = await visibleMessageForQuery(
        captured: context.identity,
        binding: context.binding,
        peerAccount: groupConsumptionKey(group, revision),
        message: message,
        createdReceiptIds: createdReceiptIds,
        groupMembership: membership,
      );
      items.add(visible.item.toJson());
    }
    await requireSameGroupMembership(context.identity, membership);
    await requireIdentity(expected);
    final next = before != null
        ? (page.items.isEmpty ? before : page.items.first.position)
        : page.nextPosition;
    return {'items': items, 'next_position': next, 'has_more': page.hasMore};
  }

  Future<Map<String, dynamic>> waitGroupHistory({
    required ExpectedIdentity expected,
    required String group,
    required int after,
    required int timeout,
    Set<String>? createdReceiptIds,
  }) async {
    final context = await requireIdentity(expected);
    final membership = await requireGroup(context.identity, group);
    final deadline = DateTime.now().add(Duration(seconds: timeout));
    for (;;) {
      final page = await groupHistoryFor(expected: expected, group: group, after: after,
        createdReceiptIds: createdReceiptIds,
        membershipRevision: membership.membershipRevision);
      if ((page['items'] as List).isNotEmpty) {
        return {...page, 'reason': 'messages'};
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return {...page, 'reason': 'timeout'};
      const interval = Duration(milliseconds: 400);
      await Future<void>.delayed(remaining < interval ? remaining : interval);
    }
  }

  Future<void> _groupNotificationChanges(
    AuthIdentity captured,
    String consumer,
    List<LocalEventEntry> entries,
    int skipThrough,
    Set<String> displayed,
    Map<String, Map<String, dynamic>> changes,
    List<Map<String, dynamic>> deferred,
  ) async {
    final relevant = <String, List<LocalEventEntry>>{};
    final account = captured.account;
    final discover = await ledger.discoversConversations(account, consumer);
    final selected = discover ? null : (await ledger.subscriptions(account))[consumer]?.toSet();
    for (final entry in entries) {
      final event = entry.event;
      final group = event.groupId;
      if (event.type == LocalEventType.messageAvailable && group != null &&
          (discover || (selected?.contains(group) ?? false)) &&
          _sourcePosition(event) > skipThrough) {
        (relevant[group] ??= []).add(entry);
      }
    }
    if (relevant.isEmpty) return;
    final groups = await _activeGroups(captured, ids: relevant.keys.toSet());
    for (final group in groups.keys) {
      final membership = groups[group]!;
      final after = membership.historyThrough;
      final revision = membership.membershipRevision;
      final candidates = relevant[group]!.where((e) =>
        e.event.position! > after && e.event.membershipRevision == revision).toList();
      if (candidates.isEmpty) continue;
      try {
        final targetIds = candidates.map((e) => e.event.messageId).toSet();
        final summary = await summarizeGroup(captured, membership, consumer, displayed,
          onUnread: (message) {
            if (!targetIds.contains(message.id)) return;
            final row = changes.putIfAbsent(group, () => {
              'conversation': groupRef(group),
              'display_name': membership.displayName,
              'membership_revision': revision,
              'new_count': 0,
              'last_message': messagePreview(message),
            });
            row['new_count'] = (row['new_count'] as int) + 1;
            row['last_message'] = messagePreview(message);
          },
        );
        changes[group]?['incoming_unread'] = summary['incoming_unread'];
      } on AuthFailure catch (failure) {
        changes.remove(group);
        if (const {'not_found', 'forbidden', 'group_unavailable'}.contains(failure.code)) {
          continue;
        }
        if (!const {'upstream_unavailable', 'upstream_timeout', 'network_error'}.contains(failure.code)) {
          rethrow;
        }
        for (final entry in candidates) {
          deferred.add({
            'cursor': entry.cursor,
            'conversation': groupRef(group),
            'membership_revision': revision,
            'error_code': failure.code,
          });
        }
      }
    }
    final sentGroups = changes.keys.where(isGroupId).toSet();
    final current = await _activeGroups(captured, ids: sentGroups);
    for (final id in sentGroups) {
      if (current[id]?.membershipRevision != changes[id]!['membership_revision']) {
        changes.remove(id);
      }
    }
  }

  Future<void> subscribeEventsFor({
    required ExpectedIdentity expectedIdentity,
    String? peerAccount,
    bool discover = false,
  }) async {
    final context = await requireIdentity(expectedIdentity);
    if (peerAccount != null && isGroupId(peerAccount)) {
      await requireGroup(context.identity, peerAccount);
    }
    await eventFeed.subscribe(
      consumerSession: expectedIdentity.consumerId,
      peerAccount: peerAccount,
      discover: discover,
      expectedIdentity: expectedIdentity,
    );
    await requireIdentity(expectedIdentity);
  }

  Future<LocalEventPage> readEventsFor({
    required ExpectedIdentity expectedIdentity,
    required int afterCursor,
    int limit = 50,
  }) async {
    final captured = (await requireIdentity(expectedIdentity)).identity;
    final page = await eventFeed.read(
      consumerSession: expectedIdentity.consumerId,
      expectedIdentity: expectedIdentity,
      afterCursor: afterCursor,
      limit: limit,
    );
    return _scopeSharedEvents(expectedIdentity, captured, page);
  }

  Future<LocalEventPage> waitEventsFor({
    required ExpectedIdentity expectedIdentity,
    required int afterCursor,
    int limit = 50,
    int timeoutSeconds = 60,
  }) async {
    if (!const <int>{30, 60, 120}.contains(timeoutSeconds)) {
      throw _validation('timeout 只能是 30、60 或 120 秒');
    }
    final captured = (await requireIdentity(expectedIdentity)).identity;
    final page = await eventFeed.wait(
      consumerSession: expectedIdentity.consumerId,
      expectedIdentity: expectedIdentity,
      afterCursor: afterCursor,
      limit: limit,
      timeout: Duration(seconds: timeoutSeconds),
    );
    return _scopeSharedEvents(expectedIdentity, captured, page);
  }

  Future<LocalEventPage> _scopeSharedEvents(
    ExpectedIdentity expected, AuthIdentity captured, LocalEventPage page,
  ) async {
    final ids = page.items.map((entry) => entry.event.groupId).whereType<String>().toSet();
    if (ids.isEmpty) return page;
    final discover = await ledger.discoversConversations(expected.account, expected.consumerId);
    if (!discover) {
      final peers = (await ledger.subscriptions(expected.account))[expected.consumerId];
      ids.retainWhere((id) => peers?.contains(id) ?? false);
    }
    final current = await _activeGroups(captured, ids: ids);
    await requireIdentity(expected);
    return LocalEventPage(
      items: page.items.where((entry) {
        final event = entry.event;
        final group = event.groupId;
        return group == null || (ids.contains(group) &&
            (event.type == LocalEventType.conversationAccessChanged ||
                current[group]?.membershipRevision == event.membershipRevision));
      }).toList(),
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
      reason: page.reason,
    );
  }

  /// Current client-issued identity metadata for one consumer alias.
  ///
  /// This is what a v2 caller echoes back as `expected_identity`; it contains
  /// no token.
  Future<ExpectedIdentity> identityFor(String consumerSession) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        consumerSession == _humanSession(captured.account)
        ? await _captureLocalBinding(captured.account)
        : await _captureBinding(consumerSession);
    return context.binding.identity;
  }

  /// Captures the client-owned human consumer for UI/plain sends.
  ///
  /// This alias is the client's own session, so a new login legitimately
  /// rotates it. Plugin `consumer_session` aliases are never rotated
  /// implicitly.
  Future<({AuthIdentity identity, ConsumerBinding binding})>
  _captureLocalBinding(String account) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final ConsumerBinding binding = await ledger.bindConsumer(
      account: account,
      authGeneration: captured.authGeneration,
      consumerSession: _humanSession(account),
      allowGenerationRotation: true,
    );
    return (identity: captured, binding: binding);
  }

  /// Captures the login identity and resolves the stable consumer binding in
  /// one business-layer step.
  ///
  /// The returned pair is the only source of account/consumer for the rest of
  /// the operation: later steps never re-read the mutable session to decide
  /// which account's row to write or which token to use.
  Future<({AuthIdentity identity, ConsumerBinding binding})> _captureBinding(
    String consumerSession, {
    bool create = true,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final ConsumerBinding binding = await ledger.bindConsumer(
      account: captured.account,
      authGeneration: captured.authGeneration,
      consumerSession: consumerSession,
      requireExisting: !create,
    );
    return (identity: captured, binding: binding);
  }

  /// Rejects a v2 call whose `expected_identity` is no longer current.
  ///
  /// A re-login (including A→B→A) changes `auth_generation` and a binding
  /// change moves `binding_revision`, so an identity captured before either
  /// event can never pass again.
  void _expectCurrentIdentity(
    ExpectedIdentity? expected,
    ConsumerBinding binding,
    AuthIdentity captured,
  ) {
    if (expected == null) {
      return;
    }
    if (expected.account != captured.account ||
        expected.authGeneration != captured.authGeneration) {
      throw staleIdentity;
    }
    if (!expected.matches(binding.identity)) {
      throw staleBinding('消费者绑定版本已变化，请重新绑定后再试');
    }
  }

  // --------------------------------------------------------------- account --

  Future<UserPage> listUsers({
    String afterAccount = '',
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final AuthIdentity captured;
    if (expectedIdentity != null) {
      captured = (await requireIdentity(expectedIdentity)).identity;
    } else {
      final AuthIdentity? current = session.identity;
      if (current == null) {
        throw unauthenticated;
      }
      captured = current;
    }
    final UserPage page = await api.listUsers(
      token: captured.token,
      afterAccount: afterAccount,
      limit: limit.clamp(1, 100),
    );
    if (!session.isCurrent(captured)) {
      throw expectedIdentity == null ? unauthenticated : staleIdentity;
    }
    return page;
  }

  /// Reads one peer's presence from the same `GET /users` source the signed-in
  /// list uses, without paging the whole directory.
  ///
  /// Accounts are ascending 8-digit keyset values, so the page directly before
  /// [account] contains that account even when the directory is paginated and
  /// `limit: 1` returns it. Returns null when the server no longer lists the
  /// account; callers must keep their last confirmed value instead of reading
  /// that as offline.
  Future<Presence?> presenceOf(
    String account, {
    ExpectedIdentity? expectedIdentity,
  }) async {
    final int numeric = int.tryParse(account) ?? 0;
    // The keyset cursor must itself be a valid account: '' starts before the
    // smallest allocatable account, (account - 1) is the row just below this
    // one.
    final String after = numeric > 10000000 ? '${numeric - 1}' : '';
    final UserPage page = await listUsers(
      afterAccount: after,
      limit: 1,
      expectedIdentity: expectedIdentity,
    );
    for (final ChatUser user in page.items) {
      if (user.account == account) {
        return user.presence;
      }
    }
    return null;
  }

  // ------------------------------------------------------- unread / viewed --

  final Map<String, int> _unreadHistoryPositions = <String, int>{};
  String? _unreadHistoryGeneration;

  /// History already observed by the human unread query in this login.
  /// Capture this at navigation time, before starting asynchronous history reads.
  int observedConversationPosition(String peerAccount) {
    final String? generation = session.authGeneration;
    if (generation == null || generation != _unreadHistoryGeneration) {
      return 0;
    }
    return _unreadHistoryPositions[peerAccount] ?? 0;
  }

  /// Account incoming unread per existing conversation for the human UI.
  ///
  /// The single derivation stays [ChatQueryService.listConversations]'
  /// `incomingUnread`: server inbound message ids minus confirmed display
  /// receipts. This method only names the client-owned human consumer and
  /// pages that existing query; it never reads or writes the consumption
  /// watermark (`consumed_through`) and never creates an outbound read
  /// receipt. Peers without a conversation are absent (unread zero).
  Future<Map<String, int>> incomingUnreadByPeer({int limit = 100}) async {
    if (limit < 1 || limit > 100) {
      throw _validation('limit 必须在 1–100 之间');
    }
    final AuthIdentity? current = session.identity;
    if (current == null) {
      throw unauthenticated;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureLocalBinding(current.account);
    final Map<String, int> unread = <String, int>{};
    final Map<String, int> positions = <String, int>{};
    String after = '';
    do {
      final ConversationPage page = await query.listConversations(
        consumerId: context.binding.consumerId,
        afterAccount: after,
        limit: limit,
      );
      for (final ConversationSummary summary in page.items) {
        unread[summary.peerAccount] = summary.incomingUnread;
        positions[summary.peerAccount] = summary.latestPosition;
      }
      after = page.nextCursor ?? '';
    } while (after.isNotEmpty);
    if (!session.isCurrent(current)) {
      throw unauthenticated;
    }
    if (_unreadHistoryGeneration != current.authGeneration) {
      _unreadHistoryGeneration = current.authGeneration;
      _unreadHistoryPositions.clear();
    }
    positions.forEach((String peer, int position) {
      _unreadHistoryPositions.update(
        peer,
        (int observed) => max(observed, position),
        ifAbsent: () => position,
      );
    });
    return Map<String, int>.unmodifiable(unread);
  }

  /// Records the human UI entering [peerAccount]'s conversation as viewed.
  ///
  /// The UI supplies [throughPosition] from [observedConversationPosition] at
  /// entry. Without a supplied bound, the first server history response supplies
  /// it. Entries beyond that position are confirmed by the rendering path.
  /// Returns the number of newly confirmed inbound display facts.
  Future<int> markConversationViewed(
    String peerAccount, {
    int? throughPosition,
  }) async {
    if (!_accountPattern.hasMatch(peerAccount)) {
      throw _validation('peer_account 必须是 8 位账号');
    }
    final AuthIdentity? current = session.identity;
    if (current == null) {
      throw unauthenticated;
    }
    final int entryMaxPosition;
    if (throughPosition != null) {
      entryMaxPosition = throughPosition;
    } else {
      final MessagePage newest = await api.conversation(
        token: current.token,
        account: peerAccount,
        afterPosition: null,
        beforePosition: 9007199254740991,
        limit: 1,
      );
      if (!session.isCurrent(current)) {
        throw unauthenticated;
      }
      entryMaxPosition = newest.items.isEmpty ? 0 : newest.items.single.position;
    }
    if (entryMaxPosition <= 0) {
      return 0;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureLocalBinding(current.account);
    final Set<String> displayed = await ledger.displayedMessageIds(
      current.account,
    );
    final List<ChatMessage> inbound = <ChatMessage>[];
    int position = 0;
    while (position < entryMaxPosition) {
      final MessagePage page = await api.conversation(
        token: current.token,
        account: peerAccount,
        afterPosition: position,
        limit: 100,
      );
      if (!session.isCurrent(current)) {
        throw unauthenticated;
      }
      for (final ChatMessage message in page.items) {
        if (message.position > entryMaxPosition) {
          break;
        }
        if (message.targetAccount == current.account &&
            !displayed.contains(message.id)) {
          inbound.add(message);
        }
      }
      if (page.items.isEmpty || !page.hasMore) {
        break;
      }
      if (page.nextPosition <= position) {
        throw const FormatException('history cursor did not advance');
      }
      position = page.nextPosition;
    }
    final int confirmed = await _confirmInboundDisplay(
      captured: current,
      consumerId: context.binding.consumerId,
      peerAccount: peerAccount,
      messages: inbound,
    );
    if (!session.isCurrent(current)) {
      throw unauthenticated;
    }
    return confirmed;
  }

  /// Records inbound [messages] the human UI actually rendered.
  ///
  /// Used for arrivals while the conversation stays open; same display-fact
  /// basis as [markConversationViewed]. Bookkeeping only: no ACK, no
  /// consumption watermark, no outbound read receipt.
  Future<int> recordDisplayedIncoming({
    required String peerAccount,
    required Iterable<ChatMessage> messages,
  }) async {
    if (!_accountPattern.hasMatch(peerAccount)) {
      throw _validation('peer_account 必须是 8 位账号');
    }
    final AuthIdentity? current = session.identity;
    if (current == null) {
      throw unauthenticated;
    }
    final List<ChatMessage> inbound = <ChatMessage>[
      for (final ChatMessage message in messages)
        if (message.targetAccount == current.account) message,
    ];
    if (inbound.isEmpty) {
      return 0;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureLocalBinding(current.account);
    final Set<String> displayed = await ledger.displayedMessageIds(
      current.account,
    );
    final int confirmed = await _confirmInboundDisplay(
      captured: current,
      consumerId: context.binding.consumerId,
      peerAccount: peerAccount,
      messages: <ChatMessage>[
        for (final ChatMessage message in inbound)
          if (!displayed.contains(message.id)) message,
      ],
    );
    if (!session.isCurrent(current)) {
      throw unauthenticated;
    }
    return confirmed;
  }

  /// Prepares and confirms display receipts for inbound messages.
  ///
  /// Reuses the ledger's existing exact-display entries: `prepareReceipt`
  /// followed by the internal UI `confirmReceipts`. It deliberately skips the
  /// contiguous consumer ACK so the recovery watermark keeps its own meaning.
  Future<int> _confirmInboundDisplay({
    required AuthIdentity captured,
    required String consumerId,
    required String peerAccount,
    required Iterable<ChatMessage> messages,
  }) async {
    final List<String> receiptIds = <String>[];
    for (final ChatMessage message in messages) {
      final PresentationReceipt receipt = await ledger.prepareReceipt(
        account: captured.account,
        consumerId: consumerId,
        consumerSession: _humanSession(captured.account),
        peerAccount: peerAccount,
        messageId: message.id,
        position: message.position,
        contentDigest: _messageDigest(message),
      );
      receiptIds.add(receipt.receiptId);
    }
    if (receiptIds.isEmpty) {
      return 0;
    }
    return (await ledger.confirmReceipts(
      account: captured.account,
      receiptIds: receiptIds,
    )).length;
  }

  Future<MessagePage> loadConversation({
    required String peerAccount,
    int? afterPosition,
    int? beforePosition,
    int limit = 50,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final MessagePage page = await api.conversation(
      token: captured.token,
      account: peerAccount,
      afterPosition: afterPosition,
      beforePosition: beforePosition,
      limit: limit.clamp(1, 100),
    );
    // Bookkeeping only, and it must not delay the first frame: every message
    // carrying an operation id costs a local read (often a write too), serially,
    // so awaiting it here put up to 200 local round trips in front of the open.
    unawaited(
      ledger
          .observeMessageAssociations(
            captured.account,
            page.items,
            peerAccount: peerAccount,
          )
          // The page is already rendered; a ledger problem is reconciled on the
          // next load and must never surface as a failed conversation.
          .catchError((Object _) {}),
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    return page;
  }

  Future<OperationResult?> getOperation(String operationId) async {
    _validateOperationId(operationId);
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final OperationResult? result = await _operationFor(captured, operationId);
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    return result;
  }

  /// Account-scoped operation lookup under one captured identity.
  ///
  /// The operation fact belongs to the account that accepted the plan: a
  /// switched account neither reads nor resumes it. The server idempotency
  /// record is only consulted with the captured account's token.
  Future<OperationResult?> _operationFor(
    AuthIdentity captured,
    String operationId,
  ) async {
    final String account = captured.account;
    final String? owner = await ledger.accountForOperation(operationId);
    if (owner != null && owner != account) {
      return null;
    }
    final String? taskId = await ledger.downloadTaskForOperation(
      account,
      operationId,
    );
    if (taskId != null) {
      final DownloadTask? task = await ledger.download(account, taskId);
      if (task == null) {
        return null;
      }
      return OperationResult(
        operationId: operationId,
        kind: 'download',
        status: switch (task.status) {
          DownloadStatus.succeeded => OperationStatus.succeeded,
          DownloadStatus.failed => OperationStatus.failed,
          _ => OperationStatus.pending,
        },
        taskId: task.taskId,
        errorCode: task.errorCode,
      );
    }
    final ChatOperationRecord? record = await ledger.operation(
      account,
      operationId,
    );
    return _queryMessageOperation(captured, operationId, record: record);
  }

  OperationResult _operationResult(
    ChatOperationRecord record, {
    bool exposeUncertain = false,
  }) {
    final succeeded = record.state == 'succeeded' && record.message != null;
    return OperationResult(
      operationId: record.operationId,
      kind: 'message',
      status: succeeded
          ? OperationStatus.succeeded
          : switch (record.state) {
              'failed' => OperationStatus.failed,
              'uncertain' when exposeUncertain => OperationStatus.uncertain,
              _ => OperationStatus.pending,
            },
      message: succeeded
          ? record.message!.withOperationId(record.operationId)
          : null,
      errorCode: record.state == 'failed' ? record.errorCode : null,
    );
  }

  ChatMessage _associatedMessage(
    ChatMessage message,
    String account,
    String operationId, {
    String? target,
    ChatMessageKind? kind,
  }) {
    final actualTarget = message.isGroup ? message.conversation!.id : message.targetAccount;
    if (message.senderAccount != account ||
        (target != null && actualTarget != target) ||
        (kind != null && message.kind != kind) ||
        (message.operationId != null && message.operationId != operationId)) {
      throw upstreamMalformed;
    }
    return message.withOperationId(operationId);
  }

  /// Permissions are checked by the two distinct callers. Only reconciliation
  /// and monotonic persistence are shared; a consumer never falls back to an
  /// account-wide query when its local plan is absent.
  Future<OperationResult?> _queryMessageOperation(
    AuthIdentity captured,
    String operationId, {
    ChatOperationRecord? record,
    bool exposeUncertain = false,
  }) async {
    final account = captured.account;
    OperationResult? latestSuccess(ChatOperationRecord? value) =>
        value?.state == 'succeeded' && value?.message != null
        ? _operationResult(value!, exposeUncertain: exposeUncertain)
        : null;
    final saved = latestSuccess(record);
    if (saved != null) return saved;
    final OperationResult? remote;
    try {
      remote = await api.getOperation(
        token: captured.token,
        operationId: operationId,
      );
    } catch (_) {
      final latest = latestSuccess(
        await ledger.operation(account, operationId),
      );
      if (latest != null) return latest;
      rethrow;
    }
    if (remote != null &&
        (remote.operationId != operationId ||
            remote.kind != 'message' ||
            (remote.status == OperationStatus.succeeded &&
                remote.message == null) ||
            (remote.status != OperationStatus.succeeded &&
                remote.message != null))) {
      throw upstreamMalformed;
    }
    if (remote?.status == OperationStatus.succeeded) {
      final plan = record ?? await ledger.operation(account, operationId);
      final message = _associatedMessage(
        remote!.message!,
        account,
        operationId,
        target: plan?.targetAccount,
        kind: plan == null
            ? null
            : plan.kind == 'attachment'
            ? ChatMessageKind.attachment
            : ChatMessageKind.body,
      );
      if (plan != null) {
        await _succeed(account, plan, message);
      }
      return OperationResult(
        operationId: operationId,
        kind: 'message',
        status: OperationStatus.succeeded,
        message: message,
      );
    }
    // The network response may predate a concurrent retry's durable commit.
    final current = await ledger.operation(account, operationId);
    final committed = latestSuccess(current);
    if (committed != null) return committed;
    if (current != null && current.revision != record?.revision) {
      return _operationResult(current, exposeUncertain: exposeUncertain);
    }
    if (remote != null) return remote;
    return current == null
        ? null
        : _operationResult(current, exposeUncertain: exposeUncertain);
  }

  // ------------------------------------------------------------------ send --

  /// Sends an ordered body. The same [operationId] always maps to the same
  /// server message; retries reuse it and never resend a success under a new ID.
  Future<SendOutcome> sendBody({
    required String targetAccount,
    required List<OutgoingPart> content,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) => InstallSafetyGate.instance.protect(
    () => _sendBody(
      targetAccount: targetAccount,
      content: content,
      operationId: operationId,
      expectedIdentity: expectedIdentity,
    ),
  );

  Future<SendOutcome> _sendBody({
    required String targetAccount,
    required List<OutgoingPart> content,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final AuthIdentity? maybeCurrent = session.identity;
    if (maybeCurrent == null) {
      throw unauthenticated;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        expectedIdentity == null
        ? await _captureLocalBinding(maybeCurrent.account)
        : await requireIdentity(expectedIdentity);
    final AuthIdentity captured = context.identity;
    final String account = captured.account;
    final String token = captured.token;
    final member = isGroupId(targetAccount) ? await requireGroup(captured, targetAccount) : null;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final ExpectedIdentity currentIdentity = context.binding.identity;
    final String opId = operationId ?? newOperationId('b');
    _validateOperationId(opId);
    final List<OutgoingPart> cleaned = <OutgoingPart>[
      for (final OutgoingPart part in content)
        if (part is! OutgoingText || part.text.isNotEmpty) part,
    ];
    if (cleaned.isEmpty) {
      throw _validation('正文不能为空');
    }
    final String sourceDigest = _digestOfBody(targetAccount, cleaned);
    ChatOperationRecord? record = await ledger.operation(account, opId);
    final String? owner = await ledger.accountForOperation(opId);
    if (owner != null && owner != account) {
      // The plan belongs to an account the caller is no longer logged in as.
      throw staleIdentity;
    }
    if (record != null) {
      if (member != null && expectedIdentity != null &&
          record.expectedIdentity?.consumerId != currentIdentity.consumerId) {
        throw staleBinding('群发送操作属于另一个消费者');
      }
      _expectSameOperation(record, targetAccount, sourceDigest, 'message');
      if (record.state == 'succeeded' && record.message != null) {
        await requireSameGroupMembership(captured, member);
        return SendOutcome(
          operationId: opId,
          message: record.message,
          part: cleaned,
        );
      }
      if (record.state == 'failed' && record.errorStatus == 409) {
        // A conflicting operation must never be replayed under the same id.
        throw _storedFailure(record);
      }
      final bool identityMatches =
          record.expectedIdentity != null &&
          record.expectedIdentity!.matches(currentIdentity);
      if (!identityMatches) {
        final outcome = await _reconcileStalePlan(captured, account, record, cleaned);
        await requireSameGroupMembership(captured, member);
        return outcome;
      }
      // Other failures are safe to retry with the same nonce: the server
      // either committed the identical request or rejected it.
    }
    final List<Map<String, dynamic>> storedParts =
        record?.parts ?? const <Map<String, dynamic>>[];
    if (storedParts.isNotEmpty) {
      _expectPartsMatch(storedParts, cleaned);
    }
    final int imageCount = cleaned.whereType<OutgoingImage>().length;
    final List<String> mediaIds = record == null
        ? <String>[]
        : List<String>.from(record.resolvedMediaIds);
    while (mediaIds.length < imageCount) {
      mediaIds.add('');
    }
    int imageIndex = 0;
    for (int i = 0; i < cleaned.length; i++) {
      final OutgoingPart part = cleaned[i];
      if (part is! OutgoingImage) {
        continue;
      }
      if (imageIndex >= mediaIds.length || mediaIds[imageIndex].isEmpty) {
        final ResolvedMedia media = await _resolver.resolve(part.source);
        final Attachment uploaded = await _uploadChatMedia(
          token: token,
          targetAccount: targetAccount,
          bytes: media.bytes,
          filename: media.filename,
          mimeType: media.mimeType,
        );
        mediaIds[imageIndex] = uploaded.mediaId;
        if (!session.isCurrent(captured)) {
          throw staleIdentity;
        }
        record = ChatOperationRecord(
          operationId: opId,
          kind: 'message',
          targetAccount: targetAccount,
          state: 'prepared',
          sourceDigest: sourceDigest,
          parts: _storedParts(cleaned, mediaIds),
          resolvedMediaIds: List<String>.from(mediaIds),
          attempts: (record?.attempts ?? 0) + 1,
          createdAt: record?.createdAt ?? _clock(),
          updatedAt: _clock(),
          expectedIdentity: record?.expectedIdentity ?? currentIdentity,
        );
        await ledger.saveOperation(account, record);
      }
      imageIndex += 1;
    }
    record = ChatOperationRecord(
      operationId: opId,
      kind: 'message',
      targetAccount: targetAccount,
      state: 'prepared',
      sourceDigest: sourceDigest,
      parts: _storedParts(cleaned, mediaIds),
      resolvedMediaIds: mediaIds,
      attempts: (record?.attempts ?? 0) + 1,
      message: record?.message,
      createdAt: record?.createdAt ?? _clock(),
      updatedAt: _clock(),
      expectedIdentity: record?.expectedIdentity ?? currentIdentity,
    );
    await ledger.saveOperation(account, record);
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    final outcome = await _sendOrCommitted(
      captured,
      record,
      () => _submitBody(captured, account, record!, cleaned, mediaIds),
      parts: cleaned,
    );
    await requireSameGroupMembership(captured, member);
    return outcome;
  }

  Future<Attachment> _uploadChatMedia({
    required String token,
    required String targetAccount,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
    String? coverMediaId,
  }) {
    if (isGroupId(targetAccount)) {
      return api.uploadConversationMedia(token: token,
        conversation: ConversationRef.group(targetAccount), bytes: bytes,
        filename: filename, mimeType: mimeType, coverMediaId: coverMediaId);
    }
    return api.uploadMedia(token: token, targetAccount: targetAccount, bytes: bytes,
      filename: filename, mimeType: mimeType, coverMediaId: coverMediaId);
  }

  Future<SendOutcome> _sendOrCommitted(
    AuthIdentity captured,
    ChatOperationRecord record,
    Future<SendOutcome> Function() submit, {
    List<OutgoingPart>? parts,
    OutgoingAttachment? attachment,
  }) async {
    try {
      return await submit();
    } on AuthFailure {
      final latest = await ledger.operation(
        captured.account,
        record.operationId,
      );
      if (session.isCurrent(captured) &&
          latest?.state == 'succeeded' &&
          latest?.message != null) {
        return SendOutcome(
          operationId: record.operationId,
          message: latest!.message!.withOperationId(record.operationId),
          part: parts,
          attachment: attachment,
        );
      }
      rethrow;
    }
  }

  static const int _maxStorageBusyRetries = 3;

  Future<ChatMessage> _sendMessageWithStorageRetry({
    required AuthIdentity captured,
    required String targetAccount,
    required String clientNonce,
    required List<MessagePart> content,
  }) async {
    for (int attempt = 0; ; attempt++) {
      try {
        final message = isGroupId(targetAccount)
            ? await api.sendConversationMessage(
                token: captured.token, conversation: ConversationRef.group(targetAccount),
                clientNonce: clientNonce, content: content)
            : await api.sendMessage(
                token: captured.token, targetAccount: targetAccount,
                clientNonce: clientNonce, content: content);
        return _associatedMessage(
          message,
          captured.account,
          clientNonce,
          target: targetAccount,
          kind: ChatMessageKind.body,
        );
      } on AuthFailure catch (failure) {
        if (failure.status == 503 && failure.code == 'storage_busy') {
          if (attempt >= _maxStorageBusyRetries) {
            throw _storageFailure(failure);
          }
          final int seconds = failure.retryAfterSeconds ?? 1;
          await Future<void>.delayed(
            Duration(seconds: seconds < 0 ? 0 : seconds),
          );
          if (!session.isCurrent(captured)) {
            throw staleIdentity;
          }
          continue;
        }
        if (failure.status == 503) {
          throw _storageFailure(failure);
        }
        rethrow;
      }
    }
  }

  Future<ChatMessage> _sendAttachmentWithStorageRetry({
    required AuthIdentity captured,
    required String targetAccount,
    required String clientNonce,
    required String mediaId,
  }) async {
    for (int attempt = 0; ; attempt++) {
      try {
        final message = isGroupId(targetAccount)
            ? await api.sendConversationAttachment(
                token: captured.token, conversation: ConversationRef.group(targetAccount),
                clientNonce: clientNonce, mediaId: mediaId)
            : await api.sendAttachment(
                token: captured.token, targetAccount: targetAccount,
                clientNonce: clientNonce, mediaId: mediaId);
        return _associatedMessage(
          message,
          captured.account,
          clientNonce,
          target: targetAccount,
          kind: ChatMessageKind.attachment,
        );
      } on AuthFailure catch (failure) {
        if (failure.status == 503 && failure.code == 'storage_busy') {
          if (attempt >= _maxStorageBusyRetries) {
            throw _storageFailure(failure);
          }
          final int seconds = failure.retryAfterSeconds ?? 1;
          await Future<void>.delayed(
            Duration(seconds: seconds < 0 ? 0 : seconds),
          );
          if (!session.isCurrent(captured)) {
            throw staleIdentity;
          }
          continue;
        }
        if (failure.status == 503) {
          throw _storageFailure(failure);
        }
        rethrow;
      }
    }
  }

  static AuthFailure _storageFailure(AuthFailure failure) {
    final String message;
    if (failure.code == 'storage_busy') {
      message = '存储繁忙，请稍后再试';
    } else if (failure.code == 'storage_io_error') {
      message = '存储写入失败，请稍后重试或联系管理员';
    } else {
      message = '服务暂不可用，请稍后重试';
    }
    return AuthFailure(
      status: failure.status,
      code: failure.code,
      message: message,
      fields: failure.fields,
      retryAfterSeconds: failure.retryAfterSeconds,
    );
  }

  Future<SendOutcome> _submitBody(
    AuthIdentity captured,
    String account,
    ChatOperationRecord record,
    List<OutgoingPart> content,
    List<String> mediaIds,
  ) async {
    final List<MessagePart> parts = <MessagePart>[
      for (int i = 0; i < content.length; i++)
        content[i] is OutgoingImage
            ? ImagePart(mediaIds[_imagePos(content, i)])
            : content[i].toWirePart(null),
    ];
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    if (record.state == 'uncertain') {
      final OperationResult? resolved = await _operationFor(
        captured,
        record.operationId,
      );
      if (!session.isCurrent(captured)) {
        // The identity changed while this accepted operation was in flight.
        // A committed send stays under the original account; the stale caller
        // gets the contract's stale error, never a fabricated 401/failure.
        throw staleIdentity;
      }
      if (resolved?.message != null) {
        await _succeed(account, record, resolved!.message!);
        return SendOutcome(
          operationId: record.operationId,
          message: resolved.message,
          part: content,
        );
      }
    }
    try {
      final ChatMessage message = await _sendMessageWithStorageRetry(
        captured: captured,
        targetAccount: record.targetAccount,
        clientNonce: record.operationId,
        content: parts,
      );
      // The remote commit already happened under the captured identity. Record
      // it in the original account's ledger first; a later switch only turns
      // this call's result into the contract's stale error, it must not turn a
      // committed send into a lost local fact.
      await _succeed(account, record, message);
      if (!session.isCurrent(captured)) {
        // The identity changed while this accepted operation was in flight.
        // A committed send stays under the original account; the stale caller
        // gets the contract's stale error, never a fabricated 401/failure.
        throw staleIdentity;
      }
      return SendOutcome(
        operationId: record.operationId,
        message: message,
        part: content,
      );
    } on AuthFailure catch (failure) {
      if (_isUncertain(failure)) {
        await _markUncertain(account, record);
        if (!session.isCurrent(captured)) {
          throw staleIdentity;
        }
        final OperationResult? resolved = await _operationFor(
          captured,
          record.operationId,
        );
        if (!session.isCurrent(captured)) {
          throw staleIdentity;
        }
        if (resolved?.message != null) {
          await _succeed(account, record, resolved!.message!);
          return SendOutcome(
            operationId: record.operationId,
            message: resolved.message,
            part: content,
          );
        }
        // Identical retry with the same nonce: at most one message commits.
        try {
          final ChatMessage message = await _sendMessageWithStorageRetry(
            captured: captured,
            targetAccount: record.targetAccount,
            clientNonce: record.operationId,
            content: parts,
          );
          await _succeed(account, record, message);
          if (!session.isCurrent(captured)) {
            throw staleIdentity;
          }
          return SendOutcome(
            operationId: record.operationId,
            message: message,
            part: content,
          );
        } on AuthFailure catch (again) {
          if (_isUncertain(again)) {
            await _markUncertain(account, record);
            rethrow;
          }
          if (!session.isCurrent(captured)) {
            // The login changed under the request: this is not a failed send
            // fact, and the server may even have committed under the original
            // account. Leave reconciliation to the next recovery.
            rethrow;
          }
          await _markFailed(account, record, again);
          rethrow;
        }
      }
      if (!session.isCurrent(captured)) {
        rethrow;
      }
      await _markFailed(account, record, failure);
      rethrow;
    }
  }

  Future<SendOutcome> sendAttachment({
    required String targetAccount,
    required OutgoingAttachment attachment,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) => InstallSafetyGate.instance.protect(
    () => _sendAttachment(
      targetAccount: targetAccount,
      attachment: attachment,
      operationId: operationId,
      expectedIdentity: expectedIdentity,
    ),
  );

  Future<SendOutcome> _sendAttachment({
    required String targetAccount,
    required OutgoingAttachment attachment,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final AuthIdentity? maybeCurrent = session.identity;
    if (maybeCurrent == null) {
      throw unauthenticated;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        expectedIdentity == null
        ? await _captureLocalBinding(maybeCurrent.account)
        : await requireIdentity(expectedIdentity);
    final AuthIdentity captured = context.identity;
    final String account = captured.account;
    final String token = captured.token;
    final member = isGroupId(targetAccount) ? await requireGroup(captured, targetAccount) : null;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final ExpectedIdentity currentIdentity = context.binding.identity;
    final String opId = operationId ?? newOperationId('a');
    _validateOperationId(opId);
    final String sourceDigest = _digestOfAttachment(targetAccount, attachment);
    ChatOperationRecord? record = await ledger.operation(account, opId);
    final String? owner = await ledger.accountForOperation(opId);
    if (owner != null && owner != account) {
      throw staleIdentity;
    }
    if (record != null) {
      if (member != null && expectedIdentity != null &&
          record.expectedIdentity?.consumerId != currentIdentity.consumerId) {
        throw staleBinding('群发送操作属于另一个消费者');
      }
      _expectSameOperation(record, targetAccount, sourceDigest, 'attachment');
      if (record.state == 'succeeded' && record.message != null) {
        await requireSameGroupMembership(captured, member);
        return SendOutcome(
          operationId: opId,
          message: record.message,
          attachment: attachment,
        );
      }
      if (record.state == 'failed' && record.errorStatus == 409) {
        throw _storedFailure(record);
      }
      final bool identityMatches =
          record.expectedIdentity != null &&
          record.expectedIdentity!.matches(currentIdentity);
      if (!identityMatches) {
        final outcome = await _reconcileStaleAttachment(captured, account, record, attachment);
        await requireSameGroupMembership(captured, member);
        return outcome;
      }
    }
    ResolvedMedia media;
    if (record?.resolvedMediaId == null || record!.resolvedMediaId!.isEmpty) {
      media = await _resolver.resolve(attachment.source);
    } else {
      media = ResolvedMedia(
        bytes: Uint8List(0),
        filename: record.attachmentSource?['filename'] as String? ?? 'file',
        mimeType:
            record.attachmentSource?['mime_type'] as String? ??
            'application/octet-stream',
      );
    }
    String? mediaId = record?.resolvedMediaId;
    String? coverId = record?.resolvedCoverMediaId;
    String filename =
        record?.attachmentSource?['filename'] as String? ?? media.filename;
    String mimeType =
        record?.attachmentSource?['mime_type'] as String? ?? media.mimeType;
    if (mediaId == null || mediaId.isEmpty) {
      if (media.bytes.isEmpty) {
        media = await _resolver.resolve(attachment.source);
        filename = media.filename;
        mimeType = media.mimeType;
      }
      if (mimeType.startsWith('video/')) {
        if (coverId == null || coverId.isEmpty) {
          final ResolvedMedia? cover = await _resolveCover(attachment, media);
          if (cover == null) {
            throw _validation('无法提取视频封面，不能发送该视频');
          }
          final Attachment uploadedCover = await _uploadChatMedia(
            token: token,
            targetAccount: targetAccount,
            bytes: cover.bytes,
            filename: cover.filename,
            mimeType: cover.mimeType,
          );
          coverId = uploadedCover.mediaId;
          if (!session.isCurrent(captured)) {
            throw staleIdentity;
          }
        }
      }
      final Attachment uploaded = await _uploadChatMedia(
        token: token,
        targetAccount: targetAccount,
        bytes: media.bytes,
        filename: filename,
        mimeType: mimeType,
        coverMediaId: coverId,
      );
      mediaId = uploaded.mediaId;
      if (!session.isCurrent(captured)) {
        // The identity changed while this accepted operation was in flight.
        // A committed send stays under the original account; the stale caller
        // gets the contract's stale error, never a fabricated 401/failure.
        throw staleIdentity;
      }
      record = ChatOperationRecord(
        operationId: opId,
        kind: 'attachment',
        targetAccount: targetAccount,
        state: 'prepared',
        sourceDigest: sourceDigest,
        parts: const <Map<String, dynamic>>[],
        attachmentSource: <String, dynamic>{
          'filename': filename,
          'mime_type': mimeType,
        },
        resolvedMediaId: mediaId,
        resolvedCoverMediaId: coverId,
        attempts: (record?.attempts ?? 0) + 1,
        createdAt: record?.createdAt ?? _clock(),
        updatedAt: _clock(),
        expectedIdentity: record?.expectedIdentity ?? currentIdentity,
      );
      await ledger.saveOperation(account, record);
    }
    record = ChatOperationRecord(
      operationId: opId,
      kind: 'attachment',
      targetAccount: targetAccount,
      state: 'prepared',
      sourceDigest: sourceDigest,
      parts: const <Map<String, dynamic>>[],
      attachmentSource: <String, dynamic>{
        'filename': filename,
        'mime_type': mimeType,
      },
      resolvedMediaId: mediaId,
      resolvedCoverMediaId: coverId,
      attempts: (record?.attempts ?? 0) + 1,
      createdAt: record?.createdAt ?? _clock(),
      updatedAt: _clock(),
      expectedIdentity: record?.expectedIdentity ?? currentIdentity,
    );
    await ledger.saveOperation(account, record);
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    final outcome = await _sendOrCommitted(
      captured,
      record,
      () => _submitAttachment(captured, account, record!, attachment),
      attachment: attachment,
    );
    await requireSameGroupMembership(captured, member);
    return outcome;
  }

  Future<SendOutcome> _submitAttachment(
    AuthIdentity captured,
    String account,
    ChatOperationRecord record,
    OutgoingAttachment attachment,
  ) async {
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    if (record.state == 'uncertain') {
      final OperationResult? resolved = await _operationFor(
        captured,
        record.operationId,
      );
      if (!session.isCurrent(captured)) {
        // The identity changed while this accepted operation was in flight.
        // A committed send stays under the original account; the stale caller
        // gets the contract's stale error, never a fabricated 401/failure.
        throw staleIdentity;
      }
      if (resolved?.message != null) {
        await _succeed(account, record, resolved!.message!);
        return SendOutcome(
          operationId: record.operationId,
          message: resolved.message,
          attachment: attachment,
        );
      }
    }
    try {
      final ChatMessage message = await _sendAttachmentWithStorageRetry(
        captured: captured,
        targetAccount: record.targetAccount,
        clientNonce: record.operationId,
        mediaId: record.resolvedMediaId!,
      );
      await _succeed(account, record, message);
      if (!session.isCurrent(captured)) {
        // The identity changed while this accepted operation was in flight.
        // A committed send stays under the original account; the stale caller
        // gets the contract's stale error, never a fabricated 401/failure.
        throw staleIdentity;
      }
      return SendOutcome(
        operationId: record.operationId,
        message: message,
        attachment: attachment,
      );
    } on AuthFailure catch (failure) {
      if (_isUncertain(failure)) {
        await _markUncertain(account, record);
        if (!session.isCurrent(captured)) {
          throw staleIdentity;
        }
        final OperationResult? resolved = await _operationFor(
          captured,
          record.operationId,
        );
        if (!session.isCurrent(captured)) {
          throw staleIdentity;
        }
        if (resolved?.message != null) {
          await _succeed(account, record, resolved!.message!);
          return SendOutcome(
            operationId: record.operationId,
            message: resolved.message,
            attachment: attachment,
          );
        }
        try {
          final ChatMessage message = await _sendAttachmentWithStorageRetry(
            captured: captured,
            targetAccount: record.targetAccount,
            clientNonce: record.operationId,
            mediaId: record.resolvedMediaId!,
          );
          await _succeed(account, record, message);
          if (!session.isCurrent(captured)) {
            throw staleIdentity;
          }
          return SendOutcome(
            operationId: record.operationId,
            message: message,
            attachment: attachment,
          );
        } on AuthFailure catch (again) {
          if (_isUncertain(again)) {
            await _markUncertain(account, record);
            rethrow;
          }
          if (!session.isCurrent(captured)) {
            // The login changed under the request: this is not a failed send
            // fact, and the server may even have committed under the original
            // account. Leave reconciliation to the next recovery.
            rethrow;
          }
          await _markFailed(account, record, again);
          rethrow;
        }
      }
      if (!session.isCurrent(captured)) {
        rethrow;
      }
      await _markFailed(account, record, failure);
      rethrow;
    }
  }

  /// UI entry: body first, then each non-image attachment in original order.
  Future<ComposedSendResult> sendComposed({
    required String targetAccount,
    required List<OutgoingPart> body,
    required List<OutgoingAttachment> attachments,
    String? operationSeed,
  }) => InstallSafetyGate.instance.protect(
    () => _sendComposed(
      targetAccount: targetAccount,
      body: body,
      attachments: attachments,
      operationSeed: operationSeed,
    ),
  );

  Future<ComposedSendResult> _sendComposed({
    required String targetAccount,
    required List<OutgoingPart> body,
    required List<OutgoingAttachment> attachments,
    String? operationSeed,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final String seed = operationSeed ?? newOperationId('x');
    SendOutcome? bodyOutcome;
    final List<SendOutcome> outcomes = <SendOutcome>[];
    final List<OutgoingPart> cleaned = <OutgoingPart>[
      for (final OutgoingPart part in body)
        if (part is! OutgoingText || part.text.isNotEmpty) part,
    ];
    if (cleaned.isNotEmpty) {
      if (!session.isCurrent(captured)) {
        bodyOutcome = SendOutcome(
          operationId: '$seed-b',
          failure: unauthenticated,
          part: cleaned,
        );
      } else {
        try {
          bodyOutcome = await sendBody(
            targetAccount: targetAccount,
            content: cleaned,
            operationId: '$seed-b',
          );
        } on AuthFailure catch (failure) {
          bodyOutcome = SendOutcome(
            operationId: '$seed-b',
            failure: failure,
            part: cleaned,
          );
        }
      }
    }
    for (int i = 0; i < attachments.length; i++) {
      if (!session.isCurrent(captured)) {
        outcomes.add(
          SendOutcome(
            operationId: '$seed-a$i',
            failure: unauthenticated,
            attachment: attachments[i],
          ),
        );
        continue;
      }
      try {
        outcomes.add(
          await sendAttachment(
            targetAccount: targetAccount,
            attachment: attachments[i],
            operationId: '$seed-a$i',
          ),
        );
      } on AuthFailure catch (failure) {
        outcomes.add(
          SendOutcome(
            operationId: '$seed-a$i',
            failure: failure,
            attachment: attachments[i],
          ),
        );
      }
    }
    return ComposedSendResult(
      body: bodyOutcome,
      attachments: List<SendOutcome>.unmodifiable(outcomes),
      operationSeed: seed,
    );
  }

  /// Handles a persisted plan whose captured identity is no longer current.
  ///
  /// The plan is never replayed under the new identity. A server idempotency
  /// record proves what actually committed (recorded under the original
  /// account only); otherwise the plan stays uncertain and the caller gets an
  /// explicit stale error. An already-succeeded plan is returned above this
  /// point without any network send, so recovery resends nothing.
  Future<SendOutcome> _reconcileStalePlan(
    AuthIdentity captured,
    String account,
    ChatOperationRecord record,
    List<OutgoingPart> content,
  ) async {
    final OperationResult? resolved = await _operationFor(
      captured,
      record.operationId,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    if (resolved?.message != null) {
      await _succeed(account, record, resolved!.message!);
      return SendOutcome(
        operationId: record.operationId,
        message: resolved.message,
        part: content,
      );
    }
    await _markUncertain(account, record);
    throw staleIdentity;
  }

  Future<SendOutcome> _reconcileStaleAttachment(
    AuthIdentity captured,
    String account,
    ChatOperationRecord record,
    OutgoingAttachment attachment,
  ) async {
    final OperationResult? resolved = await _operationFor(
      captured,
      record.operationId,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    if (resolved?.message != null) {
      await _succeed(account, record, resolved!.message!);
      return SendOutcome(
        operationId: record.operationId,
        message: resolved.message,
        attachment: attachment,
      );
    }
    await _markUncertain(account, record);
    throw staleIdentity;
  }

  Future<void> _succeed(
    String account,
    ChatOperationRecord record,
    ChatMessage message,
  ) async {
    await ledger.saveOperation(
      account,
      record.copyWith(
        state: 'succeeded',
        message: _associatedMessage(
          message,
          account,
          record.operationId,
          target: record.targetAccount,
          kind: record.kind == 'attachment'
              ? ChatMessageKind.attachment
              : ChatMessageKind.body,
        ),
        updatedAt: _clock(),
      ),
    );
  }

  Future<void> _markUncertain(
    String account,
    ChatOperationRecord record,
  ) async {
    await ledger.saveOperation(
      account,
      record.copyWith(
        state: 'uncertain',
        attempts: record.attempts + 1,
        updatedAt: _clock(),
      ),
    );
  }

  Future<void> _markFailed(
    String account,
    ChatOperationRecord record,
    AuthFailure failure,
  ) async {
    await ledger.saveOperation(
      account,
      record.copyWith(
        state: 'failed',
        errorCode: failure.code,
        errorStatus: failure.status,
        errorMessage: failure.message,
        attempts: record.attempts + 1,
        updatedAt: _clock(),
      ),
    );
  }

  // ------------------------------------------------------------------ read --

  Future<VisibleMessagePage> readMessages({
    required String peerAccount,
    required String consumerSession,
    int afterPosition = 0,
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    _validateConsumer(consumerSession);
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureBinding(consumerSession);
    final AuthIdentity captured = context.identity;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final MessagePage page = await api.conversation(
      token: captured.token,
      account: peerAccount,
      afterPosition: afterPosition,
      limit: limit.clamp(1, 100),
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    final List<VisibleMessage> visible = <VisibleMessage>[];
    for (final ChatMessage message in page.items) {
      visible.add(
        await _visible(
          captured,
          context.binding,
          consumerSession,
          peerAccount,
          message,
        ),
      );
      if (!session.isCurrent(captured)) {
        throw unauthenticated;
      }
    }
    return VisibleMessagePage(
      items: List<VisibleMessage>.unmodifiable(visible),
      nextPosition: page.nextPosition,
      hasMore: page.hasMore,
    );
  }

  Future<VisibleMessagePage> waitMessages({
    required String peerAccount,
    required String consumerSession,
    required int seenPosition,
    int timeoutSeconds = 60,
    CancelToken? cancel,
    ExpectedIdentity? expectedIdentity,
  }) async {
    _validateConsumer(consumerSession);
    if (seenPosition < 0) {
      throw _validation('seen_position 不能为负');
    }
    if (!const <int>{30, 60, 120}.contains(timeoutSeconds)) {
      throw _validation('timeout 只能是 30、60 或 120 秒');
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureBinding(consumerSession);
    final AuthIdentity captured = context.identity;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final ConsumerBinding binding = context.binding;
    bool bindingStillCurrent(ConsumerBinding current) =>
        current.bindingRevision == binding.bindingRevision &&
        current.consumerId == binding.consumerId &&
        current.account == binding.account;
    final DateTime deadline = DateTime.now().add(
      Duration(seconds: timeoutSeconds),
    );
    while (true) {
      if (cancel?.cancelled ?? false) {
        return VisibleMessagePage(
          items: const <VisibleMessage>[],
          nextPosition: seenPosition,
          hasMore: false,
          reason: 'cancelled',
        );
      }
      final AuthIdentity? current = session.identity;
      if (current == null) {
        return VisibleMessagePage(
          items: const <VisibleMessage>[],
          nextPosition: seenPosition,
          hasMore: false,
          reason: 'logout',
        );
      }
      if (!captured.sameAs(current)) {
        return VisibleMessagePage(
          items: const <VisibleMessage>[],
          nextPosition: seenPosition,
          hasMore: false,
          reason: 'cancelled',
        );
      }
      final MessagePage page = await api.conversation(
        token: captured.token,
        account: peerAccount,
        afterPosition: seenPosition,
        limit: 50,
      );
      if (!session.isCurrent(captured)) {
        final bool loggedOut = session.identity == null;
        return VisibleMessagePage(
          items: const <VisibleMessage>[],
          nextPosition: seenPosition,
          hasMore: false,
          reason: loggedOut ? 'logout' : 'cancelled',
        );
      }
      if (page.items.isNotEmpty) {
        final ConsumerBinding? rebound = await ledger.consumerBinding(
          binding.consumerId,
        );
        if (rebound == null || !bindingStillCurrent(rebound)) {
          // The consumer was rebound while this wait was in flight: the
          // result belongs to the previous identity and must not be handed to
          // the new binding.
          return VisibleMessagePage(
            items: const <VisibleMessage>[],
            nextPosition: seenPosition,
            hasMore: false,
            reason: 'cancelled',
          );
        }
        final List<VisibleMessage> visible = <VisibleMessage>[];
        for (final ChatMessage message in page.items) {
          visible.add(
            await _visible(
              captured,
              binding,
              consumerSession,
              peerAccount,
              message,
            ),
          );
          if (!session.isCurrent(captured)) {
            final bool loggedOut = session.identity == null;
            return VisibleMessagePage(
              items: const <VisibleMessage>[],
              nextPosition: seenPosition,
              hasMore: false,
              reason: loggedOut ? 'logout' : 'cancelled',
            );
          }
        }
        return VisibleMessagePage(
          items: List<VisibleMessage>.unmodifiable(visible),
          nextPosition: page.nextPosition,
          hasMore: page.hasMore,
          reason: 'messages',
        );
      }
      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return VisibleMessagePage(
          items: const <VisibleMessage>[],
          nextPosition: seenPosition,
          hasMore: false,
          reason: 'timeout',
        );
      }
      const Duration slice = Duration(milliseconds: 400);
      await Future<void>.delayed(remaining < slice ? remaining : slice);
    }
  }

  Future<VisibleMessage> _visible(
    AuthIdentity captured,
    ConsumerBinding binding,
    String consumerSession,
    String peerAccount,
    ChatMessage message,
  ) async {
    final QueryVisibleMessage result = await _buildVisible(
      captured,
      binding,
      consumerSession,
      peerAccount,
      message,
      tolerateMissingMedia: false,
    );
    return result.item;
  }

  /// Builds a query-time visible message.
  ///
  /// Unlike the v1 read path, a missing image/cover is reported in
  /// [QueryVisibleMessage.missingMediaIds] and the item gets no presentation
  /// receipt. Network failures and unsupported upstream answers are not turned
  /// into "missing media".
  Future<QueryVisibleMessage> visibleMessageForQuery({
    required AuthIdentity captured,
    required ConsumerBinding binding,
    required String peerAccount,
    required ChatMessage message,
    Set<String>? createdReceiptIds,
    GroupConversationItem? groupMembership,
  }) {
    return _buildVisible(
      captured,
      binding,
      binding.sessionId,
      peerAccount,
      message,
      tolerateMissingMedia: true,
      createdReceiptIds: createdReceiptIds,
      groupMembership: groupMembership,
    );
  }

  Future<QueryVisibleMessage> _buildVisible(
    AuthIdentity captured,
    ConsumerBinding binding,
    String consumerSession,
    String peerAccount,
    ChatMessage message, {
    required bool tolerateMissingMedia,
    Set<String>? createdReceiptIds,
    GroupConversationItem? groupMembership,
  }) async {
    if (groupMembership == null) {
      await ledger.observeMessageAssociations(captured.account, [message], peerAccount: peerAccount);
    } else if (message.conversation != groupMembership.conversation) {
      throw upstreamMalformed;
    }
    if (!session.isCurrent(captured)) throw staleIdentity;

    if (!captured.sameAs(session.identity)) {
      throw unauthenticated;
    }
    final List<VisibleBlock> blocks = <VisibleBlock>[];
    final List<String> missing = <String>[];
    if (message.isSystem) {
      final text = message.systemText;
      if (text == null) throw upstreamMalformed;
      blocks.add(VisibleTextBlock(text));
    } else if (message.kind == ChatMessageKind.body) {
      for (final MessagePart part in message.parts) {
        if (part is TextPart) {
          blocks.add(VisibleTextBlock(part.text));
        } else if (part is ImagePart) {
          try {
            final MediaResponse media = await api.fetchMedia(
              token: captured.token,
              mediaId: part.mediaId,
            );
            blocks.add(
              VisibleImageBlock(
                data: base64Encode(media.bytes),
                mimeType: _imageMime(media.mimeType),
              ),
            );
          } on AuthFailure catch (failure) {
            if (!tolerateMissingMedia || !_isMissingMedia(failure)) {
              rethrow;
            }
            missing.add(part.mediaId);
          }
        }
      }
    } else {
      final Attachment? attachment = message.attachment;
      if (attachment == null) {
        throw upstreamMalformed;
      }
      blocks.add(VisibleTextBlock(_attachmentSummary(attachment)));
      if (attachment.kind == AttachmentKind.video &&
          attachment.coverMediaId != null) {
        try {
          final MediaResponse cover = await api.fetchMedia(
            token: captured.token,
            mediaId: attachment.coverMediaId!,
          );
          blocks.add(
            VisibleImageBlock(
              data: base64Encode(cover.bytes),
              mimeType: _imageMime(cover.mimeType),
            ),
          );
        } on AuthFailure catch (failure) {
          if (!tolerateMissingMedia || !_isMissingMedia(failure)) {
            rethrow;
          }
          missing.add(attachment.coverMediaId!);
        }
      }
    }
    if (missing.isNotEmpty ||
        (groupMembership != null && message.position <= groupMembership.historyThrough)) {
      return QueryVisibleMessage(
        item: VisibleMessage(
          message: message,
          blocks: List<VisibleBlock>.unmodifiable(blocks),
        ),
        missingMediaIds: List<String>.unmodifiable(missing),
      );
    }
    final String digest = _messageDigest(message);
    final PresentationReceipt receipt = await ledger.prepareReceipt(
      account: captured.account,
      consumerId: binding.consumerId,
      consumerSession: consumerSession,
      peerAccount: peerAccount,
      messageId: message.id,
      position: message.position,
      contentDigest: digest,
      createdReceiptIds: createdReceiptIds,
    );
    return QueryVisibleMessage(
      item: VisibleMessage(
        message: message,
        blocks: List<VisibleBlock>.unmodifiable(blocks),
        presentation: receipt,
      ),
      missingMediaIds: const <String>[],
    );
  }

  static bool _isMissingMedia(AuthFailure failure) {
    return failure.status == 404 || failure.status == 415;
  }

  // ------------------------------------------------------------- receipts ----

  Future<List<String>> confirmPresentation({
    required String consumerSession,
    required String attemptId,
    required String requestDigest,
    required List<String> receiptIds,
    ExpectedIdentity? expectedIdentity,
  }) async {
    _validateConsumer(consumerSession);
    if (attemptId.trim().isEmpty) {
      throw _validation('attempt_id 不能为空');
    }
    if (requestDigest.trim().isEmpty) {
      throw _validation('request_digest 不能为空');
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureBinding(consumerSession, create: false);
    final AuthIdentity captured = context.identity;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final groupKeys = <String, String>{};
    for (final receiptId in receiptIds.toSet()) {
      final receipt = await ledger.receipt(captured.account, receiptId);
      final key = receipt?.peerAccount;
      if (key == null || !key.startsWith('group:')) continue;
      groupKeys[key] = key.split('@').first;
    }
    if (groupKeys.isNotEmpty) {
      final groups = await _activeGroups(captured, ids: groupKeys.values.toSet());
      for (final entry in groupKeys.entries) {
        final revision = groups[entry.value]?.membershipRevision;
        if (revision is! int || entry.key != groupConsumptionKey(entry.value, revision)) {
          throw const AuthFailure(status: 404, code: 'not_found', message: '群展示凭据已失效');
        }
      }
    }
    final List<String> confirmed = await ledger.confirmPresentationAttempt(
      account: captured.account,
      consumerId: context.binding.consumerId,
      consumerSession: consumerSession,
      attemptId: attemptId,
      requestDigest: requestDigest,
      receiptIds: receiptIds,
      expectedIdentity: expectedIdentity ?? context.binding.identity,
      stillCurrent: () => session.isCurrent(captured),
      beforeCommit: beforeCommit,
    );
    // The confirmation was only written while the captured identity was
    // current. A switch during the flush keeps the original account's fact but
    // must not report success to the new context.
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    return confirmed;
  }

  // ------------------------------------------------------------------ ACK ----

  Future<int> ackMessages({
    required String peerAccount,
    required String consumerSession,
    required int throughPosition,
    ExpectedIdentity? expectedIdentity,
  }) async {
    _validateConsumer(consumerSession);
    if (throughPosition < 0) {
      throw _validation('through_position 不能为负');
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureBinding(consumerSession, create: false);
    final AuthIdentity captured = context.identity;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final member = isGroupId(peerAccount) ? await requireGroup(captured, peerAccount) : null;
    final key = member == null ? peerAccount :
        groupConsumptionKey(peerAccount, member.membershipRevision);
    if (member != null && throughPosition > member.latestPosition) {
      throw consumptionGap('请求位置超出群会话范围');
    }
    // Everything below happens inside one ledger lock: identity and binding are
    // re-verified, the gap is recomputed and only then is the watermark
    // written. A switch at the commit pause cannot advance any cursor.
    final int committed = await ledger.commitAck(
      account: captured.account,
      consumerSession: consumerSession,
      consumerId: context.binding.consumerId,
      peerAccount: key,
      historyThrough: (member?.historyThrough) ?? 0,
      throughPosition: throughPosition,
      expectedIdentity: expectedIdentity ?? context.binding.identity,
      stillCurrent: () => session.isCurrent(captured),
      beforeCommit: beforeCommit,
    );
    // The fact is scoped to the captured account. Reporting success to a
    // different login would leak it into the new context.
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
    return committed;
  }

  // ----------------------------------------------------------------- media --

  String get _cacheServer => api.baseUri.toString();

  /// Cache identity is server + account + media + variant, so switching any
  /// of them can never reuse another context's bytes.
  String _mediaCacheKey(String account, String mediaId, String variant) {
    return '$_cacheServer\u0001$account\u0001$mediaId\u0001$variant';
  }

  Future<Uint8List> mediaBytes(String mediaId) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final String cacheKey = _mediaCacheKey(
      captured.account,
      mediaId,
      'original',
    );
    final Uint8List? cached = _mediaCache[cacheKey];
    if (cached != null) {
      return cached;
    }
    final MediaResponse media = await api.fetchMedia(
      token: captured.token,
      mediaId: mediaId,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    if (media.bytes.length <= _maxCachedMediaBytes) {
      _mediaCache[cacheKey] = media.bytes;
      _mediaCacheOrder.add(cacheKey);
      while (_mediaCacheOrder.length > _maxCachedMediaEntries) {
        final String evicted = _mediaCacheOrder.removeAt(0);
        _mediaCache.remove(evicted);
      }
    }
    return media.bytes;
  }

  /// Bytes the list should show for [mediaId].
  ///
  /// Metadata decides between the original (at or below the configured
  /// boundary) and the server's bounded thumbnail. Metadata failure is
  /// surfaced as an error, never as an implicit original download.
  Future<Uint8List> loadListPreview(String mediaId) async {
    final Attachment metadata = await loadMediaMetadata(mediaId);
    if (mediaNeedsExplicitOriginal(metadata.byteSize)) {
      return loadThumbnail(mediaId);
    }
    return mediaBytes(mediaId);
  }

  /// Original media metadata from `GET /media/{id}/metadata`.
  ///
  /// Historical body images only carry a media id, so this is how the client
  /// learns the original size before deciding to request a thumbnail.
  Future<Attachment> loadMediaMetadata(String mediaId) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final String key = _mediaCacheKey(captured.account, mediaId, 'metadata');
    final Attachment? cached = _mediaMetadata[key];
    if (cached != null) {
      return cached;
    }
    final Attachment metadata = await api.fetchMediaMetadata(
      token: captured.token,
      mediaId: mediaId,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    _mediaMetadata[key] = metadata;
    _mediaMetadataOrder.add(key);
    while (_mediaMetadataOrder.length > _maxCachedMetadataEntries) {
      final String evicted = _mediaMetadataOrder.removeAt(0);
      _mediaMetadata.remove(evicted);
    }
    return metadata;
  }

  /// Bounded `?variant=thumb` bytes. Kept apart from the original cache.
  Future<Uint8List> loadThumbnail(String mediaId) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final String cacheKey = _mediaCacheKey(captured.account, mediaId, 'thumb');
    final Uint8List? cached = _thumbnailCache[cacheKey];
    if (cached != null) {
      return cached;
    }
    final MediaResponse media = await api.fetchMedia(
      token: captured.token,
      mediaId: mediaId,
      variant: 'thumb',
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    if (media.bytes.length <= _maxCachedThumbnailBytes) {
      _thumbnailCache[cacheKey] = media.bytes;
      _thumbnailCacheOrder.add(cacheKey);
      while (_thumbnailCacheOrder.length > _maxCachedThumbnailEntries) {
        final String evicted = _thumbnailCacheOrder.removeAt(0);
        _thumbnailCache.remove(evicted);
      }
    }
    return media.bytes;
  }

  /// Best bytes for one viewer slot.
  ///
  /// [thumbnail] true requests the bounded derivative; false returns the
  /// original bytes (small images, or an explicit original action).
  Future<MediaPreview> loadMediaPreview(
    String mediaId, {
    bool thumbnail = false,
  }) async {
    if (thumbnail) {
      final Uint8List bytes = await loadThumbnail(mediaId);
      return MediaPreview(bytes: bytes, isDerivative: true);
    }
    final Uint8List bytes = await mediaBytes(mediaId);
    return MediaPreview(bytes: bytes, isDerivative: false);
  }

  Future<String> saveAs({required String mediaId, required String targetPath}) {
    return downloads.saveAsCopy(mediaId: mediaId, targetPath: targetPath);
  }

  /// Explicit original fetch used only after a human action (viewer "原图" /
  /// save). Deliberately not cached in memory: the point of the lazy path is
  /// to keep large originals out of the shared preview cache.
  Future<MediaResponse> fetchOriginalMedia(
    String mediaId, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final MediaResponse media = await api.fetchMedia(
      token: captured.token,
      mediaId: mediaId,
      onProgress: onProgress,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    return media;
  }

  /// Called only from the human play action. The returned loopback URL streams
  /// authorized ranges on demand; callers must close the handle when playback
  /// stops.
  Future<MediaStreamHandle> openMediaStream(String mediaId) {
    selfAccount;
    return mediaStreams.open(mediaId);
  }

  Future<void> subscribeEvents({
    required String consumerSession,
    required String peerAccount,
    ExpectedIdentity? expectedIdentity,
  }) async {
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureBinding(consumerSession);
    _expectCurrentIdentity(expectedIdentity, context.binding, context.identity);
    await eventFeed.subscribe(
      consumerSession: consumerSession,
      peerAccount: peerAccount,
    );
  }

  Future<LocalEventPage> readEvents({
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
  }) {
    return eventFeed.read(
      consumerSession: consumerSession,
      afterCursor: afterCursor,
      limit: limit,
    );
  }

  Future<LocalEventPage> waitEvents({
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
    int timeoutSeconds = 60,
  }) {
    if (!const <int>{30, 60, 120}.contains(timeoutSeconds)) {
      throw _validation('timeout 只能是 30、60 或 120 秒');
    }
    return eventFeed.wait(
      consumerSession: consumerSession,
      afterCursor: afterCursor,
      limit: limit,
      timeout: Duration(seconds: timeoutSeconds),
    );
  }

  // ------------------------------------------------------------- internals ---

  List<Map<String, dynamic>> _storedParts(
    List<OutgoingPart> content,
    List<String> mediaIds,
  ) {
    int imageIndex = 0;
    final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
    for (final OutgoingPart part in content) {
      if (part is OutgoingText) {
        parts.add(<String, dynamic>{'type': 'text', 'text': part.text});
      } else if (part is OutgoingImage) {
        parts.add(<String, dynamic>{
          'type': 'image',
          'source': part.source.toJson(),
          if (imageIndex < mediaIds.length && mediaIds[imageIndex].isNotEmpty)
            'media_id': mediaIds[imageIndex],
        });
        imageIndex += 1;
      }
    }
    return parts;
  }

  int _imagePos(List<OutgoingPart> content, int partIndex) {
    int imageIndex = 0;
    for (int i = 0; i < partIndex; i++) {
      if (content[i] is OutgoingImage) {
        imageIndex += 1;
      }
    }
    return imageIndex;
  }

  void _expectPartsMatch(
    List<Map<String, dynamic>> stored,
    List<OutgoingPart> content,
  ) {
    if (stored.length != content.length) {
      throw _conflict('operation_id 的内容与首次提交不同');
    }
    for (int i = 0; i < content.length; i++) {
      final OutgoingPart part = content[i];
      if (part is OutgoingText) {
        if (stored[i]['type'] != 'text' || stored[i]['text'] != part.text) {
          throw _conflict('operation_id 的内容与首次提交不同');
        }
      } else if (part is OutgoingImage) {
        if (stored[i]['type'] != 'image') {
          throw _conflict('operation_id 的内容与首次提交不同');
        }
        final Object? source = stored[i]['source'];
        if (source is! Map<String, dynamic> ||
            _canonical(source) != _canonical(part.source.toJson())) {
          throw _conflict('operation_id 的内容与首次提交不同');
        }
      }
    }
  }

  void _expectSameOperation(
    ChatOperationRecord record,
    String targetAccount,
    String sourceDigest,
    String kind,
  ) {
    if (record.targetAccount != targetAccount ||
        record.sourceDigest != sourceDigest ||
        record.kind != kind) {
      throw _conflict('operation_id 已用于另一份发送内容');
    }
  }

  Future<ResolvedMedia?> _resolveCover(
    OutgoingAttachment attachment,
    ResolvedMedia video,
  ) async {
    if (attachment.cover != null) {
      return _resolver.resolve(attachment.cover!);
    }
    final String? path = attachment.source.path;
    if (path == null || path.isEmpty) {
      return null;
    }
    return _coverExtractor.extract(path: path, filename: video.filename);
  }

  String _digestOfBody(String targetAccount, List<OutgoingPart> content) {
    final List<Map<String, dynamic>> canonical = <Map<String, dynamic>>[
      for (final OutgoingPart part in content)
        if (part is OutgoingText)
          <String, dynamic>{'type': 'text', 'text': part.text}
        else if (part is OutgoingImage)
          <String, dynamic>{'type': 'image', 'source': part.source.toJson()},
    ];
    return sha256Hex(
      utf8.encode(
        _canonical(<String, dynamic>{
          'kind': 'message',
          'target': targetAccount,
          'content': canonical,
        }),
      ),
    );
  }

  String _digestOfAttachment(
    String targetAccount,
    OutgoingAttachment attachment,
  ) {
    return sha256Hex(
      utf8.encode(
        _canonical(<String, dynamic>{
          'kind': 'attachment',
          'target': targetAccount,
          'source': attachment.source.toJson(),
          'cover': attachment.cover?.toJson(),
        }),
      ),
    );
  }

  String _messageDigest(ChatMessage message) {
    final String parts = message.kind == ChatMessageKind.body
        ? MessagePart.digestOf(message.parts)
        : 'attachment:${message.attachment?.mediaId ?? ''}';
    return sha256Hex(
      utf8.encode(
        <String>[
          message.id,
          '${message.position}',
          message.kind.wire,
          parts,
        ].join('\u0001'),
      ),
    );
  }

  static String _attachmentSummary(Attachment attachment) {
    return '${attachment.kind.previewLabel} ${attachment.filename}'
        '（${_formatBytes(attachment.byteSize)}，${attachment.mimeType}）';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _imageMime(String mime) {
    if (mime == 'image/png' || mime == 'image/jpeg' || mime == 'image/webp') {
      return mime;
    }
    if (mime == 'image/jpg') {
      return 'image/jpeg';
    }
    throw const AuthFailure(
      status: 415,
      code: 'unsupported_media_type',
      message: '图片格式不受支持',
    );
  }

  static bool _isUncertain(AuthFailure failure) {
    return failure.status == 502 || failure.status == 504;
  }

  static AuthFailure _storedFailure(ChatOperationRecord record) {
    return AuthFailure(
      status: record.errorStatus ?? 502,
      code: record.errorCode ?? 'operation_failed',
      message: record.errorMessage ?? '该操作已失败，请用新的 operation_id 重试',
    );
  }

  static final RegExp _accountPattern = RegExp(r'^[1-9][0-9]{7}$');

  static final RegExp _operationIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static void _validateOperationId(String operationId) {
    if (!_operationIdPattern.hasMatch(operationId)) {
      throw _validation('operation_id 只能包含 A-Z a-z 0-9 _ -，长度 1–128');
    }
  }

  static void _validateConsumer(String consumerSession) {
    if (consumerSession.trim().isEmpty) {
      throw _validation('consumer_session 不能为空');
    }
    if (consumerSession.length > 200) {
      throw _validation('consumer_session 过长');
    }
  }

  static AuthFailure _validation(String message) => AuthFailure(
    status: 422,
    code: 'validation_error',
    message: message,
    fields: <AuthFieldError>[
      AuthFieldError(field: 'request', code: 'invalid', message: message),
    ],
  );

  static AuthFailure _conflict(String message) =>
      AuthFailure(status: 409, code: 'conflict', message: message);

  static String _canonical(Object? value) {
    Object? normalize(Object? node) {
      if (node is Map) {
        final List<String> keys = node.keys.map((Object? k) => '$k').toList()
          ..sort();
        return <String, Object?>{
          for (final String key in keys) key: normalize(node[key]),
        };
      }
      if (node is List) {
        return node.map(normalize).toList();
      }
      return node;
    }

    return jsonEncode(normalize(value));
  }
}

/// Stable operation identifier: allowed by the server's `OperationId` regex.
String newOperationId(String prefix) {
  final int now = DateTime.now().microsecondsSinceEpoch;
  final int salt = Random.secure().nextInt(1 << 32);
  return '$prefix-$now-${salt.toRadixString(36)}';
}

/// Cooperative cancellation for a local wait request.
class CancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class _SharedConversationSnapshot {
  const _SharedConversationSnapshot({
    required this.identity,
    required this.order,
    required this.unreadOnly,
    required this.expires,
    required this.rows,
  });

  final ExpectedIdentity identity;
  final String order;
  final bool unreadOnly;
  final DateTime expires;
  final List<Map<String, dynamic>> rows;
}
