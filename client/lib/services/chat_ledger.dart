import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'client_identity.dart';

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
    this.expectedIdentity,
  });

  final String operationId;
  final String kind;
  final String targetAccount;
  final String state;
  final String sourceDigest;

  /// Identity captured when the plan was accepted (persisted before any
  /// network attempt). Null only for records written by an older client.
  final ExpectedIdentity? expectedIdentity;

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
    ExpectedIdentity? expectedIdentity,
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
      expectedIdentity: expectedIdentity ?? this.expectedIdentity,
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
    'expected_identity': expectedIdentity?.toJson(),
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
      expectedIdentity: ExpectedIdentity.tryParse(json['expected_identity']),
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
    final Map<String, dynamic> data = <String, dynamic>{
      'version': _version,
      'accounts': <String, dynamic>{},
      'consumers': <String, dynamic>{},
      'consumer_owners': <String, dynamic>{},
    };
    if (initial != null) {
      data.addAll(initial);
    }
    data.putIfAbsent('accounts', () => <String, dynamic>{});
    data.putIfAbsent('consumers', () => <String, dynamic>{});
    data.putIfAbsent('consumer_owners', () => <String, dynamic>{});
    return ChatLedger._(null, data);
  }

  /// Current document version. Version 1 stored account+peer consumption
  /// watermarks; version 2 stores consumer-scoped consumption plus the
  /// client-owned consumer registry.
  static const int _version = 2;
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
      final String raw = await file.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('chat ledger must be an object');
      }
      final Object? version = decoded['version'];
      if (version == _version) {
        _data = decoded;
        final Object? accounts = _data['accounts'];
        if (accounts is! Map<String, dynamic>) {
          throw const FormatException('chat ledger accounts are invalid');
        }
        final Object? consumers = _data['consumers'];
        if (consumers is! Map<String, dynamic>) {
          throw const FormatException('chat ledger consumers are invalid');
        }
        _data.putIfAbsent('consumer_owners', () => <String, dynamic>{});
      } else {
        // The single supported document version. Old pre-v2 documents are
        // rejected rather than migrated: there is no deployed v1 user to serve.
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
    'consumers': <String, dynamic>{},
    'consumer_owners': <String, dynamic>{},
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
    value.putIfAbsent('consumption_by_consumer', () => <String, dynamic>{});
    value.putIfAbsent('consumer_aliases', () => <String, dynamic>{});
    value.putIfAbsent('receipts', () => <String, dynamic>{});
    value.putIfAbsent('events', () => <String, dynamic>{});
    value.putIfAbsent('confirmations', () => <String, dynamic>{});
    value.putIfAbsent('pending_events', () => <String, dynamic>{});
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

  /// Account that owns an operation id, if it is known to this client.
  ///
  /// Operation facts belong to the original account: a switched account must
  /// never resume or read another account's plan through a reused id.
  Future<String?> accountForOperation(String operationId) {
    return _locked(() async {
      final Map<String, dynamic> accounts =
          _data['accounts'] as Map<String, dynamic>;
      for (final MapEntry<String, dynamic> entry in accounts.entries) {
        final Object? state = entry.value;
        if (state is! Map<String, dynamic>) {
          continue;
        }
        final Object? operations = state['operations'];
        if (operations is Map<String, dynamic> &&
            operations.containsKey(operationId)) {
          return entry.key;
        }
      }
      return null;
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

  // ------------------------------------------------------------- consumers --

  /// Stable client-owned consumer registry, keyed by opaque consumer id.
  Map<String, dynamic> get _consumers =>
      _data['consumers'] as Map<String, dynamic>;

  String? _consumerIdForAliasLocked(String account, String consumerSession) {
    final Object? value =
        (_account(account)['consumer_aliases']
            as Map<String, dynamic>)[consumerSession];
    return value is String ? value : null;
  }

  /// A session alias may belong to exactly one consumer across every account.
  /// Returning the owner here lets create/bind refuse to re-point an existing
  /// alias at a new identity, including a cross-account reuse.
  String? _consumerIdForAliasAnyAccountLocked(String consumerSession) {
    final Object? rawAccounts = _data['accounts'];
    if (rawAccounts is! Map<String, dynamic>) {
      return null;
    }
    for (final Object? rawAccount in rawAccounts.values) {
      if (rawAccount is! Map<String, dynamic>) {
        continue;
      }
      final Object? aliases = rawAccount['consumer_aliases'];
      if (aliases is Map<String, dynamic>) {
        final Object? value = aliases[consumerSession];
        if (value is String) {
          return value;
        }
      }
    }
    return null;
  }

  /// Creates the one-to-one alias for [consumerSession] the first time it is
  /// seen. The consumer id is random and persisted, never derived from a
  /// credential or a transient session.
  String _ensureConsumerLocked({
    required String account,
    required String consumerSession,
    String authGeneration = '',
  }) {
    final String? existing = _consumerIdForAliasLocked(
      account,
      consumerSession,
    );
    if (existing != null) {
      return existing;
    }
    final String consumerId = newConsumerId();
    final String now = DateTime.now().toUtc().toIso8601String();
    _consumers[consumerId] = <String, dynamic>{
      'account': account,
      'auth_generation': authGeneration,
      'binding_revision': 1,
      'aliases': <String, dynamic>{consumerSession: true},
      'created_at': now,
      'updated_at': now,
    };
    (_account(account)['consumer_aliases']
        as Map<String, dynamic>)[consumerSession] =
        consumerId;
    return consumerId;
  }

  ConsumerBinding? _bindingLocked(String consumerId) {
    final Object? raw = _consumers[consumerId];
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final Object? aliases = raw['aliases'];
    final String account = raw['account'] is String
        ? raw['account'] as String
        : '';
    return ConsumerBinding(
      consumerId: consumerId,
      account: account,
      authGeneration: raw['auth_generation'] is String
          ? raw['auth_generation'] as String
          : '',
      bindingRevision: raw['binding_revision'] is int
          ? raw['binding_revision'] as int
          : 1,
      aliases: <String>{
        if (aliases is Map<String, dynamic>)
          for (final String alias in aliases.keys) alias,
      },
      sessionId: raw['session_id'] is String
          ? raw['session_id'] as String
          : '',
      ownerKeyHash: raw['owner_key_hash'] is String
          ? raw['owner_key_hash'] as String
          : '',
    );
  }

  /// Origin identity for an event feed keyed by a legacy alias or a stable
  /// consumer id. Feeds created before v2 return their stored binding snapshot.
  Future<ExpectedIdentity?> originIdentityForFeed(
    String account,
    String feedKey,
  ) {
    return _locked(() async {
      final ConsumerBinding? binding = _bindingLocked(feedKey);
      if (binding == null || binding.account != account) {
        return null;
      }
      return binding.identity;
    });
  }

  /// Persist-before-enroll consumer creation.
  ///
  /// The owner capability reservation is written and flushed before the
  /// consumer exists, so a crash can only leave a recoverable pending record;
  /// the same `(account, key hash)` retry finishes enrollment. Once ready, a
  /// retry with another session id returns the original binding unchanged.
  Future<ConsumerBinding> enrollConsumer({
    required String account,
    required String authGeneration,
    required String ownerKeyHash,
    required String sessionId,
  }) {
    return _locked(() async {
      final Map<String, dynamic> owners =
          _data['consumer_owners'] as Map<String, dynamic>;
      final Object? existingOwner = owners[ownerKeyHash];
      if (existingOwner is Map<String, dynamic>) {
        if (existingOwner['account'] != account) {
          throw staleBinding('该 capability 已属于另一个账号');
        }
        final Object? existingId = existingOwner['consumer_id'];
        if (existingId is String) {
          final ConsumerBinding? binding = _bindingLocked(existingId);
          if (binding == null) {
            throw staleBinding('消费者记录已失效');
          }
          // Enrollment retries never rebind, rotate the generation or adopt a
          // newer session id.
          return _withActive(binding);
        }
      } else {
        owners[ownerKeyHash] = <String, dynamic>{
          'account': account,
          'consumer_id': null,
          'status': 'pending',
          'session_id': sessionId,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        };
        await _flush();
      }
      // A legacy/previous session alias is evidence of its existing owner.
      // Creating a new owner for the same string would silently transfer that
      // consumer's receipts and stable binding, so it is a binding conflict.
      final String? aliased = _consumerIdForAliasAnyAccountLocked(sessionId);
      if (aliased != null) {
        throw staleBinding('该会话已绑定其他消费者，请使用新会话或先解决迁移');
      }
      final String consumerId = newConsumerId();
      final String now = DateTime.now().toUtc().toIso8601String();
      _consumers[consumerId] = <String, dynamic>{
        'account': account,
        'auth_generation': authGeneration,
        'binding_revision': 1,
        'session_id': sessionId,
        'owner_key_hash': ownerKeyHash,
        'aliases': <String, dynamic>{sessionId: true},
        'created_at': now,
        'updated_at': now,
      };
      (_account(account)['consumer_aliases']
          as Map<String, dynamic>)[sessionId] =
          consumerId;
      owners[ownerKeyHash] = <String, dynamic>{
        ...(owners[ownerKeyHash] as Map<String, dynamic>),
        'consumer_id': consumerId,
        'status': 'ready',
      };
      await _flush();
      return _withActive(_bindingLocked(consumerId)!);
    });
  }

  ConsumerBinding _withActive(ConsumerBinding binding) => binding;

  /// Owner-verified consumer read. A wrong capability, another account or an
  /// unknown consumer is indistinguishable `stale_binding`.
  Future<ConsumerBinding> consumerForOwner({
    required String account,
    required String ownerKeyHash,
    required String consumerId,
  }) {
    return _locked(() async {
      final Object? raw = _consumers[consumerId];
      if (raw is! Map<String, dynamic> ||
          raw['account'] != account ||
          raw['owner_key_hash'] != ownerKeyHash) {
        throw staleBinding('消费者能力或归属不匹配');
      }
      return _bindingLocked(consumerId)!;
    });
  }

  /// Owner-verified revision CAS bind.
  ///
  /// Matching `expectedBindingRevision` is required even for the same session;
  /// exactly one of two competing owners can pass.
  Future<ConsumerBinding> bindConsumerOwner({
    required String account,
    required String authGeneration,
    required String ownerKeyHash,
    required String consumerId,
    required int expectedBindingRevision,
    required String sessionId,
  }) {
    return _locked(() async {
      final Object? raw = _consumers[consumerId];
      if (raw is! Map<String, dynamic> ||
          raw['account'] != account ||
          raw['owner_key_hash'] != ownerKeyHash) {
        throw staleBinding('消费者能力或归属不匹配');
      }
      final Map<String, dynamic> record = raw;
      final int revision = record['binding_revision'] is int
          ? record['binding_revision'] as int
          : 1;
      if (revision != expectedBindingRevision) {
        throw staleBinding('消费者绑定版本已变化');
      }
      final String? aliased = _consumerIdForAliasAnyAccountLocked(sessionId);
      if (aliased != null && aliased != consumerId) {
        throw staleBinding('该会话已绑定其他消费者，不能重新指向');
      }
      final Map<String, dynamic> aliases = <String, dynamic>{
        ...((record['aliases'] as Map<String, dynamic>?) ??
            <String, dynamic>{}),
        sessionId: true,
      };
      _consumers[consumerId] = <String, dynamic>{
        ...record,
        'auth_generation': authGeneration,
        'binding_revision': revision + 1,
        'session_id': sessionId,
        'aliases': aliases,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      (_account(account)['consumer_aliases']
          as Map<String, dynamic>)[sessionId] =
          consumerId;
      await _flush();
      return _bindingLocked(consumerId)!;
    });
  }

  /// Read-only binding lookup by consumer id (used by business calls).
  Future<ConsumerBinding?> bindingById(String consumerId) {
    return _locked(() async => _bindingLocked(consumerId));
  }

  /// Binds the current login to a consumer.
  ///
  /// * a first `(account, consumer_session)` is a new consumer with revision 1;
  /// * a new authentication generation on an existing alias rotates the
  ///   binding and bumps the revision, so every previously issued identity is
  ///   stale;
  /// * adopting another alias's consumer requires the exact
  ///   [expectedBindingRevision] — a consumer id alone cannot take it over, and
  ///   a consumer of another account can never be adopted.
  Future<ConsumerBinding> bindConsumer({
    required String account,
    required String authGeneration,
    required String consumerSession,
    String? consumerId,
    int? expectedBindingRevision,
    bool allowGenerationRotation = false,
    bool requireExisting = false,
  }) {
    return _locked(() async {
      String? resolved = consumerId;
      if (resolved != null) {
        final ConsumerBinding? target = _bindingLocked(resolved);
        if (target == null) {
          throw staleBinding('消费者不存在或已失效');
        }
        if (target.account != account) {
          throw staleBinding('该消费者属于另一个账号');
        }
        final String? aliased = _consumerIdForAliasLocked(
          account,
          consumerSession,
        );
        if (aliased != resolved) {
          if (expectedBindingRevision == null ||
              expectedBindingRevision != target.bindingRevision) {
            throw staleBinding('接管消费者需要匹配的绑定版本');
          }
        } else if (expectedBindingRevision != null &&
            expectedBindingRevision != target.bindingRevision) {
          throw staleBinding('消费者绑定版本已变化');
        }
      } else {
        resolved = _consumerIdForAliasLocked(account, consumerSession);
        if (resolved == null && requireExisting) {
          // Consumption/confirmation never mints a consumer: an unknown alias
          // is an old-identity request, not a registration.
          throw staleIdentity;
        }
        if (resolved != null) {
          final ConsumerBinding? target = _bindingLocked(resolved);
          if (target != null && target.account != account) {
            throw staleBinding('该消费者已绑定另一个账号');
          }
        }
      }

      if (resolved == null) {
        resolved = _ensureConsumerLocked(
          account: account,
          consumerSession: consumerSession,
          authGeneration: authGeneration,
        );
        await _flush();
        return _bindingLocked(resolved)!;
      }

      ConsumerBinding binding = _bindingLocked(resolved)!;
      if (expectedBindingRevision != null &&
          expectedBindingRevision != binding.bindingRevision) {
        throw staleBinding('消费者绑定版本已变化');
      }
      final String? aliased = _consumerIdForAliasAnyAccountLocked(
        consumerSession,
      );
      if (aliased != null && aliased != resolved) {
        throw staleBinding('该会话已绑定其他消费者，不能重新指向');
      }
      final Map<String, dynamic> aliases = <String, dynamic>{
        ...((_consumers[resolved] as Map<String, dynamic>)['aliases']
                as Map<String, dynamic>? ??
            <String, dynamic>{}),
        consumerSession: true,
      };
      final bool generationChanged =
          authGeneration.isNotEmpty && binding.authGeneration != authGeneration;
      if (generationChanged) {
        // Re-login does not silently re-point an existing alias at a new
        // identity. Only the first binding of a never-authenticated consumer,
        // the client-owned human alias, or an explicit revision-matching
        // rebind may rotate the generation.
        final bool firstBinding = binding.authGeneration.isEmpty;
        final bool explicitRebind =
            expectedBindingRevision != null &&
            expectedBindingRevision == binding.bindingRevision;
        if (!firstBinding && !allowGenerationRotation && !explicitRebind) {
          throw staleIdentity;
        }
      }
      final bool aliasAdded = !binding.aliases.contains(consumerSession);
      if (generationChanged || aliasAdded) {
        final bool firstBinding =
            generationChanged && binding.authGeneration.isEmpty;
        _consumers[resolved] = <String, dynamic>{
          ...(_consumers[resolved] as Map<String, dynamic>),
          'auth_generation': generationChanged
              ? authGeneration
              : binding.authGeneration,
          'binding_revision': generationChanged && !firstBinding
              ? binding.bindingRevision + 1
              : binding.bindingRevision,
          'aliases': aliases,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };
        (_account(account)['consumer_aliases']
            as Map<String, dynamic>)[consumerSession] =
            resolved;
        await _flush();
        binding = _bindingLocked(resolved)!;
      }
      return binding;
    });
  }

  Future<ConsumerBinding?> consumerBinding(String consumerId) {
    return _locked(() async {
      final ConsumerBinding? binding = _bindingLocked(consumerId);
      return binding;
    });
  }

  // ------------------------------------------------------------ consumption --

  /// Consumer-scoped consumption watermark. Another consumer of the same
  /// account and peer can never advance or inherit it.
  Future<int> consumedThrough(
    String account,
    String peerAccount, {
    required String consumerId,
  }) {
    return _locked(() async {
      final Object? perConsumer =
          (_account(account)['consumption_by_consumer']
              as Map<String, dynamic>)[consumerId];
      if (perConsumer is! Map<String, dynamic>) {
        return 0;
      }
      final Object? value = perConsumer[peerAccount];
      return value is int ? value : 0;
    });
  }

  Future<void> setConsumedThrough(
    String account,
    String peerAccount,
    int position, {
    required String consumerId,
  }) {
    return _locked(() async {
      final Map<String, dynamic> scopes =
          _account(account)['consumption_by_consumer']
              as Map<String, dynamic>;
      final Map<String, dynamic> consumption =
          (scopes[consumerId] as Map<String, dynamic>?) ??
          <String, dynamic>{};
      final int current = consumption[peerAccount] is int
          ? consumption[peerAccount] as int
          : 0;
      if (position > current) {
        consumption[peerAccount] = position;
        scopes[consumerId] = consumption;
        await _flush();
      }
    });
  }

  int _consumedLocked(String account, String consumerId, String peerAccount) {
    final Object? perConsumer =
        (_account(account)['consumption_by_consumer']
            as Map<String, dynamic>)[consumerId];
    if (perConsumer is! Map<String, dynamic>) {
      return 0;
    }
    final Object? value = perConsumer[peerAccount];
    return value is int ? value : 0;
  }

  /// Atomic ACK commit: identity/binding re-check, gap validation, optional
  /// fault-injection pause, a second identity re-check, then the durable write.
  ///
  /// The watermark is never written before the identity and scope checks pass.
  /// [stillCurrent] is synchronous and evaluated inside the ledger lock, so a
  /// login switch between the check and the write is observed.
  Future<int> commitAck({
    required String account,
    required String consumerSession,
    required String consumerId,
    required String peerAccount,
    required int throughPosition,
    required ExpectedIdentity expectedIdentity,
    required bool Function() stillCurrent,
    Future<void> Function()? beforeCommit,
  }) {
    return _locked(() async {
      ConsumerBinding? binding = _bindingLocked(consumerId);
      if (binding == null ||
          binding.account != account ||
          !expectedIdentity.matches(binding.identity)) {
        throw staleBinding('消费者绑定版本已变化');
      }
      if (!stillCurrent()) {
        throw staleIdentity;
      }
      final int consumed = _consumedLocked(account, consumerId, peerAccount);
      if (throughPosition <= consumed) {
        if (!stillCurrent()) {
          throw staleIdentity;
        }
        return consumed;
      }
      final Map<String, dynamic> receipts =
          _account(account)['receipts'] as Map<String, dynamic>;
      final Map<int, bool> confirmedByPosition = <int, bool>{};
      for (final Object? value in receipts.values) {
        if (value is! Map<String, dynamic>) {
          continue;
        }
        final PresentationReceipt receipt = PresentationReceipt.fromJson(value);
        final bool sameConsumer = receipt.consumerId != null
            ? receipt.consumerId == consumerId
            : receipt.consumerSession == consumerSession;
        if (sameConsumer && receipt.peerAccount == peerAccount) {
          confirmedByPosition[receipt.position] = receipt.confirmed;
        }
      }
      final List<int> gaps = <int>[
        for (int position = consumed + 1; position <= throughPosition; position++)
          if (confirmedByPosition[position] != true) position,
      ];
      if (gaps.isNotEmpty) {
        throw consumptionGap(
          '消费水位存在未确认展示的位置',
          fields: <AuthFieldError>[
            AuthFieldError(
              field: 'through_position',
              code: 'gap',
              message: '缺少展示确认的位置',
            ),
          ],
        );
      }
      if (beforeCommit != null) {
        await beforeCommit();
      }
      if (!stillCurrent()) {
        throw staleIdentity;
      }
      // A rebind could have completed while the pause was awaited: re-check the
      // exact binding snapshot before the durable write.
      binding = _bindingLocked(consumerId);
      if (binding == null || !expectedIdentity.matches(binding.identity)) {
        throw staleBinding('消费者绑定版本已变化');
      }
      final Map<String, dynamic> scopes =
          _account(account)['consumption_by_consumer']
              as Map<String, dynamic>;
      final Map<String, dynamic> consumption =
          (scopes[consumerId] as Map<String, dynamic>?) ?? <String, dynamic>{};
      if (throughPosition > _consumedLocked(account, consumerId, peerAccount)) {
        consumption[peerAccount] = throughPosition;
        scopes[consumerId] = consumption;
        await _flush();
      }
      return throughPosition;
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
    String? consumerId,
    Set<String>? createdReceiptIds,
  }) {
    return _locked(() async {
      final String resolvedConsumer =
          consumerId ??
          _consumerIdForAliasLocked(account, consumerSession) ??
          _ensureConsumerLocked(
            account: account,
            consumerSession: consumerSession,
          );
      // Receipt identity follows the stable consumer, so a host-session
      // rebuild or explicit rebind keeps the same display facts.
      final String receiptId = receiptIdForConsumer(
        account: account,
        consumerId: resolvedConsumer,
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
        consumerId: resolvedConsumer,
        peerAccount: peerAccount,
        messageId: messageId,
        position: position,
        contentDigest: contentDigest,
      );
      receipts[receiptId] = receipt.toJson();
      createdReceiptIds?.add(receiptId);
      await _flush();
      return receipt;
    });
  }

  /// Removes only freshly prepared, unconfirmed and unbound receipts.
  ///
  /// Used when a query becomes stale before its result is exposed, so a
  /// replacement binding cannot consume a presentation that was never
  /// delivered. Confirmed receipts and receipts bound to an attempt are
  /// preserved as durable evidence.
  Future<void> discardUnconfirmedReceipts(
    String account,
    Iterable<String> receiptIds,
  ) {
    return _locked(() async {
      final Map<String, dynamic> receipts =
          _account(account)['receipts'] as Map<String, dynamic>;
      bool changed = false;
      for (final String id in receiptIds.toSet()) {
        final Object? raw = receipts[id];
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final PresentationReceipt receipt = PresentationReceipt.fromJson(raw);
        if (receipt.confirmed || receipt.attemptId != null) {
          continue;
        }
        receipts.remove(id);
        changed = true;
      }
      if (changed) {
        await _flush();
      }
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
    String? consumerId,
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
        // A consumer keeps its display history across host-session rebuilds,
        // so the stable consumer id wins whenever it is known.
        final bool sameConsumer = consumerId != null
            ? receipt.consumerId == consumerId
            : receipt.consumerSession == consumerSession;
        if (sameConsumer && receipt.peerAccount == peerAccount) {
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
    String? consumerId,
    ExpectedIdentity? expectedIdentity,
    bool Function()? stillCurrent,
    Future<void> Function()? beforeCommit,
  }) {
    return _locked(() async {
      final Map<String, dynamic> state = _account(account);
      final String resolvedConsumer =
          consumerId ??
          _consumerIdForAliasLocked(account, consumerSession) ??
          _ensureConsumerLocked(
            account: account,
            consumerSession: consumerSession,
          );
      final Map<String, dynamic> confirmations =
          state['confirmations'] as Map<String, dynamic>;
      final Map<String, dynamic> receipts =
          state['receipts'] as Map<String, dynamic>;
      final List<String> ids = receiptIds.toSet().toList()..sort();
      // Identity and binding are validated inside the same lock as the write:
      // an invalidated binding can never confirm, and no confirmation is
      // written before this check.
      if (expectedIdentity != null) {
        final ConsumerBinding? binding = _bindingLocked(resolvedConsumer);
        if (binding == null ||
            binding.account != account ||
            !expectedIdentity.matches(binding.identity)) {
          throw staleBinding('消费者绑定版本已变化');
        }
      }
      if (stillCurrent != null && !stillCurrent()) {
        throw staleIdentity;
      }
      // Attempt idempotency is scoped to the consumer: distinct consumers may
      // reuse the same logical attempt id without sharing confirmation state.
      final String attemptKey = '$resolvedConsumer\u0001$attemptId';

      final Object? existing = confirmations[attemptKey];
      if (existing is Map<String, dynamic>) {
        final List<String> existingIds =
            (existing['receipt_ids'] as List<dynamic>? ?? <dynamic>[])
                .whereType<String>()
                .toList()
              ..sort();
        final Object? existingConsumer = existing['consumer_id'];
        final bool sameBinding =
            (existingConsumer == null
                ? existing['consumer_session'] == consumerSession
                : existingConsumer == resolvedConsumer) &&
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
        final bool sameConsumer = receipt.consumerId != null
            ? receipt.consumerId == resolvedConsumer
            : receipt.consumerSession == consumerSession;
        if (!sameConsumer) {
          throw const AuthFailure(
            status: 409,
            code: 'conflict',
            message: '展示凭据属于另一个消费者',
          );
        }
        // A receipt can legitimately be re-presented by a later model request
        // under a new attempt. Its display fact stays valid; the attempt record
        // below binds this request's member set. Only the same attempt changing
        // its binding is a conflict.
        validated.add(receipt);
      }

      if (beforeCommit != null) {
        await beforeCommit();
      }
      if (stillCurrent != null && !stillCurrent()) {
        throw staleIdentity;
      }
      if (expectedIdentity != null) {
        final ConsumerBinding? binding = _bindingLocked(resolvedConsumer);
        if (binding == null || !expectedIdentity.matches(binding.identity)) {
          throw staleBinding('消费者绑定版本已变化');
        }
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
        confirmations[attemptKey] = <String, dynamic>{
          'attempt_id': attemptId,
          'consumer_session': consumerSession,
          'consumer_id': resolvedConsumer,
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
      final String? consumer = _consumerIdForAliasLocked(
        account,
        consumerSession,
      );
      confirmations['${consumer ?? consumerSession}\u0001$attemptId'] =
          <String, dynamic>{
            'attempt_id': attemptId,
            'consumer_session': consumerSession,
            'consumer_id': consumer,
            'request_digest': requestDigest,
            'receipt_ids': receiptIds,
            'confirmed_at': DateTime.now().toUtc().toIso8601String(),
          };
      await _flush();
    });
  }

  Future<Map<String, dynamic>?> confirmation(
    String account,
    String attemptId, {
    String? consumerId,
  }) {
    return _locked(() async {
      final Map<String, dynamic> confirmations =
          _account(account)['confirmations'] as Map<String, dynamic>;
      if (consumerId != null) {
        final Object? value = confirmations['$consumerId\u0001$attemptId'];
        return value is Map<String, dynamic>
            ? Map<String, dynamic>.from(value)
            : null;
      }
      final Object? legacy = confirmations[attemptId];
      if (legacy is Map<String, dynamic>) {
        return Map<String, dynamic>.from(legacy);
      }
      for (final Object? value in confirmations.values) {
        if (value is Map<String, dynamic> && value['attempt_id'] == attemptId) {
          return Map<String, dynamic>.from(value);
        }
      }
      return null;
    });
  }

  // ------------------------------------------------------- pending delivery --

  /// Atomically stores the terminal download task and its event delivery.
  ///
  /// The fact is owned by the task's original account+consumer, not by whoever
  /// is currently logged in. If the event cannot be appended immediately it
  /// stays in `pending_events` and is delivered on the account's next read/wait
  /// or process restart. A failed flush rolls back and never changes a
  /// successfully saved file into a business failure.
  Future<void> finishDownload({
    required String account,
    required DownloadTask task,
    required LocalEvent event,
  }) {
    return _locked(() async {
      final Map<String, dynamic> state = _account(account);
      final Map<String, dynamic> downloads =
          state['downloads'] as Map<String, dynamic>;
      final Map<String, dynamic> pending =
          state['pending_events'] as Map<String, dynamic>;
      final Map<String, dynamic> feeds =
          state['events'] as Map<String, dynamic>;
      final Map<String, dynamic>? feed =
          feeds[event.consumerSession] as Map<String, dynamic>?;
      final Set<String> delivered = <String>{
        if (feed != null)
          ...(feed['source_event_ids'] as List<dynamic>).whereType<String>(),
      };
      final Object previousDownloads = jsonDecode(jsonEncode(downloads));
      final Object previousPending = jsonDecode(jsonEncode(pending));
      try {
        downloads[task.taskId] = task.toJson();
        if (delivered.contains(event.eventId)) {
          pending.remove(event.eventId);
        } else {
          pending[event.eventId] = event.toJson();
        }
        await _flush();
      } catch (_) {
        state['downloads'] = previousDownloads;
        state['pending_events'] = previousPending;
        rethrow;
      }
    });
  }

  /// Moves this account's pending events into their consumer feeds. The event
  /// and its pending marker change in one locked, single-flush operation.
  Future<int> deliverPendingEvents(String account) {
    return _locked(() async {
      final Map<String, dynamic> state = _account(account);
      final Map<String, dynamic> pending =
          state['pending_events'] as Map<String, dynamic>;
      if (pending.isEmpty) {
        return 0;
      }
      final Map<String, dynamic> events =
          state['events'] as Map<String, dynamic>;
      final Object previousPending = jsonDecode(jsonEncode(pending));
      final Object previousEvents = jsonDecode(jsonEncode(events));
      int delivered = 0;
      try {
        for (final MapEntry<String, dynamic> entry
            in pending.entries.toList()) {
          if (entry.value is! Map<String, dynamic>) {
            pending.remove(entry.key);
            continue;
          }
          final LocalEvent event = LocalEvent.fromJson(entry.value);
          final Map<String, dynamic> feed = events.putIfAbsent(
            event.consumerSession,
            () => <String, dynamic>{
              'next_cursor': 1,
              'entries': <dynamic>[],
              'source_event_ids': <String>[],
              'server_cursor': 0,
            },
          ) as Map<String, dynamic>;
          feed.putIfAbsent('server_cursor', () => 0);
          final List<String> sourceIds =
              (feed['source_event_ids'] as List<dynamic>).cast<String>();
          if (!sourceIds.contains(event.eventId)) {
            final int cursor = feed['next_cursor'] as int;
            (feed['entries'] as List<dynamic>).add(
              LocalEventEntry(cursor: cursor, event: event).toJson(),
            );
            sourceIds.add(event.eventId);
            feed['next_cursor'] = cursor + 1;
          }
          pending.remove(entry.key);
          delivered += 1;
        }
        if (delivered > 0) {
          await _flush();
        }
        return delivered;
      } catch (_) {
        state['pending_events'] = previousPending;
        state['events'] = previousEvents;
        rethrow;
      }
    });
  }

  Future<bool> hasDeliveredEvent({
    required String account,
    required String consumerSession,
    required String eventId,
  }) {
    return _locked(() async {
      final Map<String, dynamic> events =
          _account(account)['events'] as Map<String, dynamic>;
      final Map<String, dynamic>? feed =
          events[consumerSession] as Map<String, dynamic>?;
      if (feed == null) {
        return false;
      }
      return (feed['source_event_ids'] as List<dynamic>)
          .whereType<String>()
          .contains(eventId);
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

/// Stable receipt identity for one consumer binding. It deliberately excludes
/// the transient consumer_session so a rebind keeps the same display facts.
String receiptIdForConsumer({
  required String account,
  required String consumerId,
  required String peerAccount,
  required String messageId,
  required int position,
  required String contentDigest,
}) {
  final String raw = <String>[
    account,
    consumerId,
    peerAccount,
    messageId,
    '$position',
    contentDigest,
  ].join('\u0001');
  return sha256.convert(utf8.encode(raw)).toString().substring(0, 32);
}

/// Lowercase hex SHA-256 used for operation/source digests.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
