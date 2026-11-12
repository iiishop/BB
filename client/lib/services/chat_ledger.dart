import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/auth_models.dart';
import '../models/chat_models.dart';

/// Client-owned immutable operation record.
///
/// It is written before any retry so a re-upload cannot silently change the
/// message parameters of an already-submitted operation.
class ChatOperationRecord {
  const ChatOperationRecord({
    required this.operationId,
    required this.kind,
    required this.targetAccount,
    required this.state,
    required this.sourceDigest,
    required this.parts,
    this.attachmentSource,
    this.resolvedMediaIds = const <String>[],
    this.resolvedMediaId,
    this.resolvedCoverMediaId,
    this.message,
    this.errorCode,
    this.errorStatus,
    this.errorMessage,
    this.attempts = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String operationId;
  final String kind;
  final String targetAccount;
  final String state;
  final String sourceDigest;

  /// Persisted ordered content for body operations.
  final List<Map<String, dynamic>> parts;

  /// Persisted original source for attachment operations.
  final Map<String, dynamic>? attachmentSource;

  /// Persisted media IDs for image body parts, one per image in order.
  final List<String> resolvedMediaIds;
  final String? resolvedMediaId;
  final String? resolvedCoverMediaId;
  final ChatMessage? message;
  final String? errorCode;
  final int? errorStatus;
  final String? errorMessage;
  final int attempts;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  ChatOperationRecord copyWith({
    String? state,
    List<String>? resolvedMediaIds,
    String? resolvedMediaId,
    String? resolvedCoverMediaId,
    ChatMessage? message,
    String? errorCode,
    int? errorStatus,
    String? errorMessage,
    int? attempts,
    DateTime? updatedAt,
  }) {
    return ChatOperationRecord(
      operationId: operationId,
      kind: kind,
      targetAccount: targetAccount,
      state: state ?? this.state,
      sourceDigest: sourceDigest,
      parts: parts,
      attachmentSource: attachmentSource,
      resolvedMediaIds: resolvedMediaIds ?? this.resolvedMediaIds,
      resolvedMediaId: resolvedMediaId ?? this.resolvedMediaId,
      resolvedCoverMediaId: resolvedCoverMediaId ?? this.resolvedCoverMediaId,
      message: message ?? this.message,
      errorCode: errorCode ?? this.errorCode,
      errorStatus: errorStatus ?? this.errorStatus,
      errorMessage: errorMessage ?? this.errorMessage,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'operation_id': operationId,
    'kind': kind,
    'target_account': targetAccount,
    'state': state,
    'source_digest': sourceDigest,
    'parts': parts,
    'attachment_source': attachmentSource,
    'resolved_media_ids': resolvedMediaIds,
    'resolved_media_id': resolvedMediaId,
    'resolved_cover_media_id': resolvedCoverMediaId,
    'message': message == null ? null : messageToJson(message!),
    'error_code': errorCode,
    'error_status': errorStatus,
    'error_message': errorMessage,
    'attempts': attempts,
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
  };

  factory ChatOperationRecord.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['operation_id'] is! String ||
        json['kind'] is! String ||
        json['target_account'] is! String ||
        json['state'] is! String ||
        json['source_digest'] is! String) {
      throw const FormatException('operation record has invalid fields');
    }
    final Object? rawParts = json['parts'];
    final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
    if (rawParts is List) {
      for (final Object? part in rawParts) {
        if (part is Map<String, dynamic>) {
          parts.add(Map<String, dynamic>.from(part));
        }
      }
    }
    final Object? rawMessage = json['message'];
    final List<String> resolvedMediaIds = <String>[
      if (json['resolved_media_ids'] is List)
        for (final Object? id in json['resolved_media_ids'] as List)
          if (id is String) id,
    ];
    return ChatOperationRecord(
      operationId: json['operation_id'] as String,
      kind: json['kind'] as String,
      targetAccount: json['target_account'] as String,
      state: json['state'] as String,
      sourceDigest: json['source_digest'] as String,
      parts: parts,
      attachmentSource: json['attachment_source'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(
              json['attachment_source'] as Map<String, dynamic>,
            )
          : null,
      resolvedMediaIds: resolvedMediaIds,
      resolvedMediaId: json['resolved_media_id'] as String?,
      resolvedCoverMediaId: json['resolved_cover_media_id'] as String?,
      message: rawMessage == null ? null : ChatMessage.fromJson(rawMessage),
      errorCode: json['error_code'] as String?,
      errorStatus: json['error_status'] is int
          ? json['error_status'] as int
          : null,
      errorMessage: json['error_message'] as String?,
      attempts: json['attempts'] is int ? json['attempts'] as int : 0,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] is String
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
    );
  }
}

/// Durable, account-scoped client ledger.
///
/// One JSON document with atomic rename writes. In-memory mode exists so tests
/// and preview tools do not need the filesystem; production always uses a file
/// under the client data directory.
class ChatLedger {
  ChatLedger._(this._file, Map<String, dynamic> initial) : _data = initial;

  factory ChatLedger.atPath(String path) {
    final File file = File(path);
    return ChatLedger._(file, <String, dynamic>{});
  }

  factory ChatLedger.inMemory([Map<String, dynamic>? initial]) {
    return ChatLedger._(null, initial ?? <String, dynamic>{});
  }

  static const int _version = 1;
  final File? _file;
  Map<String, dynamic> _data;
  bool _loaded = false;
  Future<void> _tail = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() action) {
    final Completer<void> gate = Completer<void>();
    final Future<void> previous = _tail;
    _tail = gate.future;
    return previous.then((_) async {
      try {
        await _ensureLoaded();
        return await action();
      } finally {
        gate.complete();
      }
    });
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    final File? file = _file;
    if (file == null) {
      return;
    }
    if (!await file.exists()) {
      _data = _empty();
      return;
    }
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic> && decoded['version'] == _version) {
        _data = decoded;
        final Object? accounts = _data['accounts'];
        if (accounts is! Map<String, dynamic>) {
          throw const FormatException('chat ledger accounts are invalid');
        }
      } else {
        // An unknown newer/older document is never silently rewritten.
        throw const FormatException('unsupported chat ledger version');
      }
    } catch (_) {
      // Fail closed on every later call instead of silently starting empty.
      _loaded = false;
      rethrow;
    }
  }

  Map<String, dynamic> _empty() => <String, dynamic>{
    'version': _version,
    'accounts': <String, dynamic>{},
  };

  Map<String, dynamic> _account(String account) {
    final Map<String, dynamic> accounts =
        _data['accounts'] as Map<String, dynamic>;
    final Map<String, dynamic> value = accounts.putIfAbsent(
      account,
      () => <String, dynamic>{},
    ) as Map<String, dynamic>;
    // Older documents may lack a key added later; fill it without discarding
    // anything that is already there.
    value.putIfAbsent('server_event_cursor', () => 0);
    value.putIfAbsent('subscriptions', () => <String, dynamic>{});
    value.putIfAbsent('operations', () => <String, dynamic>{});
    value.putIfAbsent('downloads', () => <String, dynamic>{});
    value.putIfAbsent('download_operations', () => <String, dynamic>{});
    value.putIfAbsent('consumption', () => <String, dynamic>{});
    value.putIfAbsent('receipts', () => <String, dynamic>{});
    value.putIfAbsent('events', () => <String, dynamic>{});
    value.putIfAbsent('confirmations', () => <String, dynamic>{});
    return value;
  }

  Future<void> _flush() async {
    final File? file = _file;
    if (file == null) {
      return;
    }
    final Directory directory = file.parent;
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final File temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    final RandomAccessFile handle = await temporary.open(mode: FileMode.write);
    try {
      await handle.writeString(jsonEncode(_data));
      await handle.flush();
    } finally {
      await handle.close();
    }
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      // Windows cannot rename over an existing file; this fallback is still
      // write-then-replace, never an in-place partial overwrite.
      if (await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
    }
  }

  // --------------------------------------------------------- server cursor --

  Future<int> serverEventCursor(String account) {
    return _locked(() async {
      final Object? value = _account(account)['server_event_cursor'];
      return value is int ? value : 0;
    });
  }

  Future<void> setServerEventCursor(String account, int cursor) {
    return _locked(() async {
      _account(account)['server_event_cursor'] = cursor;
      await _flush();
    });
  }

  /// Per-consumer source cursor. A new consumer starts at 0 so it can recover
  /// its own pre-registration backlog; another consumer's progress is never
  /// treated as acceptance for this one.
  Future<int> consumerEventCursor(String account, String consumerSession) {
    return _locked(() async {
      final Object? feed =
          (_account(account)['events']
              as Map<String, dynamic>)[consumerSession];
      if (feed is! Map<String, dynamic>) {
        return 0;
      }
      final Object? value = feed['server_cursor'];
      return value is int ? value : 0;
    });
  }

  Future<void> setConsumerEventCursor(
    String account,
    String consumerSession,
    int cursor,
  ) {
    return _locked(() async {
      final Map<String, dynamic> events =
          _account(account)['events'] as Map<String, dynamic>;
      final Map<String, dynamic> feed = events.putIfAbsent(
        consumerSession,
        () => <String, dynamic>{
          'next_cursor': 1,
          'entries': <dynamic>[],
          'source_event_ids': <String>[],
          'server_cursor': 0,
        },
      ) as Map<String, dynamic>;
      final int current = feed['server_cursor'] is int
          ? feed['server_cursor'] as int
          : 0;
      if (cursor > current) {
        feed['server_cursor'] = cursor;
        await _flush();
      }
    });
  }

  // ----------------------------------------------------------- subscription --

  Future<void> subscribe(
    String account,
    String consumerSession,
    String peerAccount,
  ) {
    return _locked(() async {
      final Map<String, dynamic> subscriptions =
          _account(account)['subscriptions'] as Map<String, dynamic>;
      final Map<String, dynamic> events =
          _account(account)['events'] as Map<String, dynamic>;
      final Map<String, dynamic>? prior =
          subscriptions[consumerSession] as Map<String, dynamic>?;
      if (prior != null && prior['peer_account'] != peerAccount) {
        throw const AuthFailure(
          status: 409,
          code: 'conflict',
          message: 'consumer_session 已绑定另一个 peer',
        );
      }
      final bool feedExisted = events.containsKey(consumerSession);
      final Map<String, dynamic> feed = events.putIfAbsent(
        consumerSession,
        () => <String, dynamic>{
          'next_cursor': 1,
          'entries': <dynamic>[],
          'source_event_ids': <String>[],
          'server_cursor': 0,
        },
      ) as Map<String, dynamic>;
      feed.putIfAbsent('server_cursor', () => 0);
      final bool sameBinding =
          prior != null && prior['peer_account'] == peerAccount;
      if (sameBinding && feedExisted) {
        return;
      }
      subscriptions[consumerSession] = <String, dynamic>{
        'peer_account': peerAccount,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      await _flush();
    });
  }

  Future<Map<String, String>> subscriptions(String account) {
    return _locked(() async {
      final Map<String, dynamic> raw =
          _account(account)['subscriptions'] as Map<String, dynamic>;
      return <String, String>{
        for (final MapEntry<String, dynamic> entry in raw.entries)
          if (entry.value is Map<String, dynamic> &&
              (entry.value as Map<String, dynamic>)['peer_account'] is String)
            entry.key:
                (entry.value as Map<String, dynamic>)['peer_account'] as String,
      };
    });
  }

  // -------------------------------------------------------------- operations --

  Future<ChatOperationRecord?> operation(String account, String operationId) {
    return _locked(() async {
      final Object? raw =
          (_account(account)['operations']
              as Map<String, dynamic>)[operationId];
      return raw is Map<String, dynamic>
          ? ChatOperationRecord.fromJson(raw)
          : null;
    });
  }

  Future<void> saveOperation(String account, ChatOperationRecord record) {
    return _locked(() async {
      (_account(account)['operations']
          as Map<String, dynamic>)[record.operationId] = record
          .toJson();
      await _flush();
    });
  }

  Future<List<ChatOperationRecord>> operations(String account) {
    return _locked(() async {
      final Map<String, dynamic> raw =
          _account(account)['operations'] as Map<String, dynamic>;
      final List<ChatOperationRecord> items = <ChatOperationRecord>[];
      for (final Object? value in raw.values) {
        if (value is Map<String, dynamic>) {
          items.add(ChatOperationRecord.fromJson(value));
        }
      }
      return items;
    });
  }

  // --------------------------------------------------------------- downloads --

  Future<void> saveDownload(String account, DownloadTask task) {
    return _locked(() async {
      (_account(account)['downloads'] as Map<String, dynamic>)[task.taskId] =
          task.toJson();
      await _flush();
    });
  }

  Future<DownloadTask?> download(String account, String taskId) {
    return _locked(() async {
      final Object? raw =
          (_account(account)['downloads'] as Map<String, dynamic>)[taskId];
      return raw is Map<String, dynamic> ? DownloadTask.fromJson(raw) : null;
    });
  }

  Future<List<DownloadTask>> downloads(String account) {
    return _locked(() async {
      final Map<String, dynamic> raw =
          _account(account)['downloads'] as Map<String, dynamic>;
      return <DownloadTask>[
        for (final Object? value in raw.values)
          if (value is Map<String, dynamic>) DownloadTask.fromJson(value),
      ];
    });
  }

  Future<void> saveDownloadOperation(
    String account,
    String operationId,
    String taskId,
  ) {
    return _locked(() async {
      (_account(account)['download_operations']
              as Map<String, dynamic>)[operationId] =
          taskId;
      await _flush();
    });
  }

  Future<String?> downloadTaskForOperation(String account, String operationId) {
    return _locked(() async {
      final Object? value =
          (_account(account)['download_operations']
              as Map<String, dynamic>)[operationId];
      return value is String ? value : null;
    });
  }

  // ------------------------------------------------------------ consumption --

  Future<int> consumedThrough(String account, String peerAccount) {
    return _locked(() async {
      final Object? value =
          (_account(account)['consumption']
              as Map<String, dynamic>)[peerAccount];
      return value is int ? value : 0;
    });
  }

  Future<void> setConsumedThrough(
    String account,
    String peerAccount,
    int position,
  ) {
    return _locked(() async {
      final Map<String, dynamic> consumption =
          _account(account)['consumption'] as Map<String, dynamic>;
      final int current = consumption[peerAccount] is int
          ? consumption[peerAccount] as int
          : 0;
      if (position > current) {
        consumption[peerAccount] = position;
        await _flush();
      }
    });
  }

  // ---------------------------------------------------------------- receipts --

  Future<PresentationReceipt> prepareReceipt({
    required String account,
    required String consumerSession,
    required String peerAccount,
    required String messageId,
    required int position,
    required String contentDigest,
  }) {
    return _locked(() async {
      final String receiptId = receiptIdFor(
        account: account,
        consumerSession: consumerSession,
        peerAccount: peerAccount,
        messageId: messageId,
        position: position,
        contentDigest: contentDigest,
      );
      final Map<String, dynamic> receipts =
          _account(account)['receipts'] as Map<String, dynamic>;
      final Object? raw = receipts[receiptId];
      if (raw is Map<String, dynamic>) {
        return PresentationReceipt.fromJson(raw);
      }
      final PresentationReceipt receipt = PresentationReceipt(
        receiptId: receiptId,
        account: account,
        consumerSession: consumerSession,
        peerAccount: peerAccount,
        messageId: messageId,
        position: position,
        contentDigest: contentDigest,
      );
      receipts[receiptId] = receipt.toJson();
      await _flush();
      return receipt;
    });
  }

  Future<PresentationReceipt?> receipt(String account, String receiptId) {
    return _locked(() async {
      final Object? raw =
          (_account(account)['receipts'] as Map<String, dynamic>)[receiptId];
      return raw is Map<String, dynamic>
          ? PresentationReceipt.fromJson(raw)
          : null;
    });
  }

  Future<List<PresentationReceipt>> receiptsForPeer({
    required String account,
    required String consumerSession,
    required String peerAccount,
  }) {
    return _locked(() async {
      final Map<String, dynamic> raw =
          _account(account)['receipts'] as Map<String, dynamic>;
      final List<PresentationReceipt> items = <PresentationReceipt>[];
      for (final Object? value in raw.values) {
        if (value is! Map<String, dynamic>) {
          continue;
        }
        final PresentationReceipt receipt = PresentationReceipt.fromJson(value);
        if (receipt.consumerSession == consumerSession &&
            receipt.peerAccount == peerAccount) {
          items.add(receipt);
        }
      }
      items.sort(
        (PresentationReceipt a, PresentationReceipt b) =>
            a.position.compareTo(b.position),
      );
      return items;
    });
  }

  /// Atomically validates an attempt binding and confirms every member.
  ///
  /// Validation completes before any receipt or attempt is mutated. The attempt
  /// record and all receipt confirmations are then written in one locked
  /// mutation and flushed once. Any conflict/invalid member leaves the ledger
  /// unchanged, so an ACK cannot cross the original gap.
  Future<List<String>> confirmPresentationAttempt({
    required String account,
    required String consumerSession,
    required String attemptId,
    required String requestDigest,
    required List<String> receiptIds,
  }) {
    return _locked(() async {
      final Map<String, dynamic> state = _account(account);
      final Map<String, dynamic> confirmations =
          state['confirmations'] as Map<String, dynamic>;
      final Map<String, dynamic> receipts =
          state['receipts'] as Map<String, dynamic>;
      final List<String> ids = receiptIds.toSet().toList()..sort();

      final Object? existing = confirmations[attemptId];
      if (existing is Map<String, dynamic>) {
        final List<String> existingIds =
            (existing['receipt_ids'] as List<dynamic>? ?? <dynamic>[])
                .whereType<String>()
                .toList()
              ..sort();
        final bool sameBinding =
            existing['consumer_session'] == consumerSession &&
            existing['request_digest'] == requestDigest;
        final bool sameMembers =
            existingIds.length == ids.length &&
            <String>{...existingIds}.containsAll(ids);
        if (sameBinding && sameMembers) {
          return existingIds;
        }
        throw const AuthFailure(
          status: 409,
          code: 'conflict',
          message: 'attempt 已绑定另一个 consumer/digest/receipt 成员',
        );
      }

      final List<PresentationReceipt> validated = <PresentationReceipt>[];
      for (final String id in ids) {
        final Object? raw = receipts[id];
        if (raw is! Map<String, dynamic>) {
          throw const AuthFailure(
            status: 404,
            code: 'not_found',
            message: '展示凭据不存在',
          );
        }
        final PresentationReceipt receipt = PresentationReceipt.fromJson(raw);
        if (receipt.consumerSession != consumerSession) {
          throw const AuthFailure(
            status: 409,
            code: 'conflict',
            message: '展示凭据属于另一个会话',
          );
        }
        // A receipt can legitimately be re-presented by a later model request
        // under a new attempt. Its display fact stays valid; the attempt record
        // below binds this request's member set. Only the same attempt changing
        // its binding is a conflict.
        validated.add(receipt);
      }

      final Object previousConfirmations = jsonDecode(
        jsonEncode(confirmations),
      );
      final Object previousReceipts = jsonDecode(jsonEncode(receipts));
      try {
        for (final PresentationReceipt receipt in validated) {
          receipts[receipt.receiptId] = receipt
              .copyWith(
                confirmed: true,
                attemptId: receipt.attemptId ?? attemptId,
              )
              .toJson();
        }
        confirmations[attemptId] = <String, dynamic>{
          'consumer_session': consumerSession,
          'request_digest': requestDigest,
          'receipt_ids': ids,
          'confirmed_at': DateTime.now().toUtc().toIso8601String(),
        };
        await _flush();
      } catch (_) {
        // The atomic rename failed: restore the in-memory view so a retry
        // cannot observe a half-applied confirmation.
        state['confirmations'] = previousConfirmations;
        state['receipts'] = previousReceipts;
        rethrow;
      }
      return ids;
    });
  }

  Future<List<String>> confirmReceipts({
    required String account,
    required List<String> receiptIds,
  }) {
    return _locked(() async {
      final Map<String, dynamic> receipts =
          _account(account)['receipts'] as Map<String, dynamic>;
      final List<String> confirmed = <String>[];
      for (final String id in receiptIds) {
        final Object? raw = receipts[id];
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final PresentationReceipt receipt = PresentationReceipt.fromJson(raw);
        if (!receipt.confirmed) {
          receipts[id] = receipt.copyWith(confirmed: true).toJson();
        }
        confirmed.add(id);
      }
      if (confirmed.isNotEmpty) {
        await _flush();
      }
      return confirmed;
    });
  }

  // -------------------------------------------------------------- confirmation --

  Future<void> recordConfirmation({
    required String account,
    required String consumerSession,
    required String attemptId,
    required String requestDigest,
    required List<String> receiptIds,
  }) {
    return _locked(() async {
      final Map<String, dynamic> confirmations =
          _account(account)['confirmations'] as Map<String, dynamic>;
      confirmations[attemptId] = <String, dynamic>{
        'consumer_session': consumerSession,
        'request_digest': requestDigest,
        'receipt_ids': receiptIds,
        'confirmed_at': DateTime.now().toUtc().toIso8601String(),
      };
      await _flush();
    });
  }

  Future<Map<String, dynamic>?> confirmation(String account, String attemptId) {
    return _locked(() async {
      final Object? value =
          (_account(account)['confirmations']
              as Map<String, dynamic>)[attemptId];
      return value is Map<String, dynamic>
          ? Map<String, dynamic>.from(value)
          : null;
    });
  }

  // ------------------------------------------------------------ local events --

  Future<LocalEventEntry?> appendLocalEvent({
    required String account,
    required String consumerSession,
    required LocalEvent event,
  }) {
    return _locked(() async {
      final Map<String, dynamic> events =
          _account(account)['events'] as Map<String, dynamic>;
      final Map<String, dynamic> feed = events.putIfAbsent(
        consumerSession,
        () => <String, dynamic>{
          'next_cursor': 1,
          'entries': <dynamic>[],
          'source_event_ids': <String>[],
          'server_cursor': 0,
        },
      ) as Map<String, dynamic>;
      final List<String> sourceIds = (feed['source_event_ids'] as List<dynamic>)
          .cast<String>();
      if (sourceIds.contains(event.eventId)) {
        return null;
      }
      final int cursor = feed['next_cursor'] as int;
      final LocalEventEntry entry = LocalEventEntry(
        cursor: cursor,
        event: event,
      );
      final List<dynamic> entries = feed['entries'] as List<dynamic>;
      entries.add(entry.toJson());
      sourceIds.add(event.eventId);
      feed['next_cursor'] = cursor + 1;
      await _flush();
      return entry;
    });
  }

  Future<LocalEventPage> readLocalEvents({
    required String account,
    required String consumerSession,
    required int afterCursor,
    int limit = 50,
  }) {
    return _locked(() async {
      final Map<String, dynamic> events =
          _account(account)['events'] as Map<String, dynamic>;
      final Map<String, dynamic>? feed =
          events[consumerSession] as Map<String, dynamic>?;
      if (feed == null) {
        return LocalEventPage(
          items: const <LocalEventEntry>[],
          nextCursor: afterCursor,
          hasMore: false,
        );
      }
      final List<LocalEventEntry> all =
          <LocalEventEntry>[
            for (final Object? raw in feed['entries'] as List<dynamic>)
              if (raw is Map<String, dynamic>) LocalEventEntry.fromJson(raw),
          ]..sort(
            (LocalEventEntry a, LocalEventEntry b) =>
                a.cursor.compareTo(b.cursor),
          );
      final List<LocalEventEntry> page = all
          .where((LocalEventEntry entry) => entry.cursor > afterCursor)
          .take(limit)
          .toList();
      final int nextCursor = page.isEmpty ? afterCursor : page.last.cursor;
      final bool hasMore = all.any(
        (LocalEventEntry entry) => entry.cursor > nextCursor,
      );
      return LocalEventPage(
        items: List<LocalEventEntry>.unmodifiable(page),
        nextCursor: nextCursor,
        hasMore: hasMore,
      );
    });
  }

  Future<int> localEventHead(String account, String consumerSession) {
    return _locked(() async {
      final Object? feed =
          (_account(account)['events']
              as Map<String, dynamic>)[consumerSession];
      if (feed is! Map<String, dynamic>) {
        return 0;
      }
      final int current = (feed['next_cursor'] as int) - 1;
      return current;
    });
  }
}

/// Stable receipt identity for the same binding. Re-reading the same message
/// for the same consumer therefore reuses one receipt.
String receiptIdFor({
  required String account,
  required String consumerSession,
  required String peerAccount,
  required String messageId,
  required int position,
  required String contentDigest,
}) {
  final String raw = <String>[
    account,
    consumerSession,
    peerAccount,
    messageId,
    '$position',
    contentDigest,
  ].join('\u0001');
  return sha256.convert(utf8.encode(raw)).toString().substring(0, 32);
}

/// Lowercase hex SHA-256 used for operation/source digests.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
