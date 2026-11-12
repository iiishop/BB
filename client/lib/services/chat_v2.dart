import 'dart:convert';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_query.dart';
import 'chat_service.dart';
import 'client_identity.dart';
import 'media_source.dart';

/// Local-client v2 protocol (shared contract `dea467-local-v2`).
///
/// Only the client LocalAuthServer implements these routes; `server/contract`
/// is where the machine-readable wire schema lives. Requests are parsed
/// strictly before any side effect: unknown fields, explicit null and wrong
/// types are 422, then 401, then expected_auth/expected_identity, then the
/// owner capability, then business validation.
class ChatV2Router {
  ChatV2Router({required this.session, required this.chat});

  final AuthSession session;
  final ChatService? chat;

  static const String _contract = v2Contract;
  static const String _ownerHeader = v2OwnerHeader;

  static const Map<String, Set<String>> _fields = <String, Set<String>>{
    '/v2/protocol/negotiate': <String>{'supported_versions'},
    '/v2/status': <String>{},
    '/v2/consumers/create': <String>{'expected_auth', 'session_id'},
    '/v2/consumers/get': <String>{'expected_auth', 'consumer_id'},
    '/v2/consumers/bind': <String>{
      'expected_auth',
      'consumer_id',
      'expected_binding_revision',
      'session_id',
    },
    '/v2/chat/list_conversations': <String>{
      'expected_identity',
      'after_account',
      'limit',
    },
    '/v2/chat/get_message': <String>{'expected_identity', 'message_id'},
    '/v2/chat/get_context': <String>{
      'expected_identity',
      'message_id',
      'before_limit',
      'after_limit',
    },
    '/v2/chat/list_users': <String>{
      'expected_identity',
      'after_account',
      'limit',
    },
    '/v2/chat/send_message': <String>{
      'expected_identity',
      'target_account',
      'operation_id',
      'content',
    },
    '/v2/chat/send_attachment': <String>{
      'expected_identity',
      'target_account',
      'operation_id',
      'source',
      'cover',
    },
    '/v2/chat/read_messages': <String>{
      'expected_identity',
      'account',
      'after_position',
      'before_position',
      'limit',
    },
    '/v2/chat/wait_messages': <String>{
      'expected_identity',
      'account',
      'seen_position',
      'timeout',
    },
    '/v2/chat/ack_messages': <String>{
      'expected_identity',
      'account',
      'through_position',
    },
    '/v2/chat/consumption': <String>{'expected_identity', 'account'},
    '/v2/chat/confirm_presentation': <String>{
      'expected_identity',
      'attempt_id',
      'request_digest',
      'receipt_ids',
    },
    '/v2/operations/get': <String>{'expected_identity', 'operation_id'},
    '/v2/downloads/start': <String>{
      'expected_identity',
      'operation_id',
      'media_id',
      'directory',
    },
    '/v2/downloads/get': <String>{'expected_identity', 'task_id'},
    '/v2/events/subscribe': <String>{'expected_identity', 'peer_account'},
    '/v2/events/read': <String>{
      'expected_identity',
      'after_cursor',
      'limit',
    },
    '/v2/events/wait': <String>{
      'expected_identity',
      'after_cursor',
      'limit',
      'timeout',
    },
  };

  static const Map<String, int> _statusByCode = <String, int>{
    'validation_error': 422,
    'unsupported_version': 426,
    'unauthenticated': 401,
    'stale_identity': 409,
    'stale_binding': 409,
    'consumption_gap': 409,
    'migration_required': 409,
    'idempotency_conflict': 409,
    'not_found': 404,
    'storage_unavailable': 503,
    'upstream_unavailable': 502,
    'upstream_timeout': 504,
    'payload_too_large': 413,
    'unsupported_media_type': 415,
  };

  static const Map<String, String> _messageByCode = <String, String>{
    'validation_error': '输入有误',
    'unsupported_version': '没有共同协议版本',
    'unauthenticated': '请重新登录',
    'stale_identity': '身份已变化，请重新登录或显式重绑',
    'stale_binding': '消费者能力或绑定不匹配',
    'consumption_gap': '该消费者缺少连续展示确认',
    'migration_required': '旧消费记录无法证明，需要迁移',
    'idempotency_conflict': '同一操作 ID 的意图已改变',
    'not_found': '当前范围内不存在',
    'storage_unavailable': '客户端存储不可用',
    'upstream_unavailable': '上游结果不确定，请先对账',
    'upstream_timeout': '上游超时，结果不确定',
    'payload_too_large': '请求体过大',
    'unsupported_media_type': '媒体格式不受支持',
  };

  /// Handles one strict v2 request. The returned body is already the contract
  /// envelope: `{identity,result}`, a bootstrap DTO, or `{error:{...}}`.
  Future<({int status, Map<String, dynamic> body})> handle({
    required String path,
    required String? ownerKey,
    required Map<String, dynamic> body,
  }) async {
    try {
      return await _dispatch(path, ownerKey, body);
    } on _V2Error catch (failure) {
      return (status: failure.status, body: _error(failure));
    } on AuthFailure catch (failure) {
      return _fromFailure(failure, path);
    } on FormatException {
      return (
        status: 422,
        body: _error(
          _V2Error(422, 'validation_error', _messageByCode['validation_error']!),
        ),
      );
    } catch (_) {
      return (
        status: 503,
        body: _error(
          _V2Error(
            503,
            'storage_unavailable',
            _messageByCode['storage_unavailable']!,
          ),
        ),
      );
    }
  }

  Future<({int status, Map<String, dynamic> body})> _dispatch(
    String path,
    String? ownerKey,
    Map<String, dynamic> raw,
  ) async {
    final Set<String> allowed = _fields[path] ?? const <String>{};
    if (!_fields.containsKey(path)) {
      throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
    }
    final _Request request = _Request(raw, allowed);
    // Strict schema first: unknown keys and every required/typed field are
    // validated before any auth or side effect.
    request.check();

    if (path == '/v2/protocol/negotiate') {
      final List<dynamic> versions = request.list('supported_versions', 1, 8);
      final List<int> parsed = <int>[];
      for (final Object? value in versions) {
        if (value is! int) {
          throw _V2Error(
            422,
            'validation_error',
            _messageByCode['validation_error']!,
            <String>['supported_versions'],
          );
        }
        parsed.add(value);
      }
      if (!parsed.contains(2)) {
        throw _V2Error(
          426,
          'unsupported_version',
          _messageByCode['unsupported_version']!,
        );
      }
      return (
        status: 200,
        body: <String, dynamic>{
          'selected_version': 2,
          'contract': _contract,
          'owner_header': _ownerHeader,
        },
      );
    }

    if (path == '/v2/status') {
      final AuthIdentity? identity = session.identity;
      return (
        status: 200,
        body: <String, dynamic>{
          'protocol_version': 2,
          'auth': identity == null
              ? null
              : <String, dynamic>{
                  'account': identity.account,
                  'auth_generation': identity.authGeneration,
                },
        },
      );
    }

    final _Args args = _parse(path, request);
    final ChatService service = _requireChat();
    final AuthIdentity current = _requireLogin();
    if (path.startsWith('/v2/consumers/')) {
      final _ExpectedAuth expectedAuth = args.expectedAuth!;
      if (expectedAuth.account != current.account ||
          expectedAuth.authGeneration != current.authGeneration) {
        throw staleIdentity;
      }
    }
    final String ownerHash = _ownerHash(ownerKey);

    if (path == '/v2/consumers/create') {
      final ConsumerBinding binding = await service.enrollConsumer(
        ownerKeyHash: ownerHash,
        sessionId: args.sessionId!,
      );
      return (status: 200, body: _binding(binding, current));
    }
    if (path == '/v2/consumers/get') {
      final ConsumerBinding binding = await service.consumerForOwner(
        ownerKeyHash: ownerHash,
        consumerId: args.consumerId!,
      );
      return (status: 200, body: _binding(binding, current));
    }
    if (path == '/v2/consumers/bind') {
      final ConsumerBinding binding = await service.bindConsumerOwner(
        ownerKeyHash: ownerHash,
        consumerId: args.consumerId!,
        expectedBindingRevision: args.revision!,
        sessionId: args.sessionId!,
      );
      return (status: 200, body: _binding(binding, current));
    }

    // All business routes carry the four-field expected_identity.
    final ExpectedIdentity expected = args.expectedIdentity!;
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await service.requireIdentity(expected);
    // Consumer id alone is not authority: business calls must prove the same
    // local owner capability that enrolled the consumer.
    if (context.binding.ownerKeyHash.isEmpty ||
        context.binding.ownerKeyHash != ownerHash) {
      throw staleBinding('消费者能力或归属不匹配');
    }

    switch (path) {
      case '/v2/chat/list_conversations':
        final ConversationPage page = await service.query.listConversations(
          afterAccount: (args.values['after_account'] as String?) ?? '',
          limit: (args.values['limit'] as int?) ?? 50,
          consumerId: context.binding.consumerId,
        );
        _ensureCurrent(context.identity);
        return _reply(expected, page.toJson());
      case '/v2/chat/get_message':
        final ChatMessage? message = await service.query.messageById(
          args.values['message_id'] as String,
        );
        if (message == null) {
          throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
        }
        final QueryVisibleMessage visible =
            await service.visibleMessageForQuery(
              captured: context.identity,
              binding: context.binding,
              peerAccount: _peerOf(message, context.identity.account),
              message: message,
            );
        _ensureCurrent(context.identity);
        return _reply(expected, <String, dynamic>{
          'item': visible.item.toJson(),
          'missing_media_ids': visible.missingMediaIds,
        });
      case '/v2/chat/get_context':
        final ContextResult? contextResult = await service.query.getContext(
          messageId: args.values['message_id'] as String,
          beforeLimit: (args.values['before_limit'] as int?) ?? 10,
          afterLimit: (args.values['after_limit'] as int?) ?? 10,
        );
        if (contextResult == null) {
          throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
        }
        final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
        final Set<String> missing = <String>{};
        for (final ChatMessage message in contextResult.items) {
          final QueryVisibleMessage visible =
              await service.visibleMessageForQuery(
                captured: context.identity,
                binding: context.binding,
                peerAccount: contextResult.peerAccount,
                message: message,
              );
          items.add(visible.item.toJson());
          missing.addAll(visible.missingMediaIds);
        }
        _ensureCurrent(context.identity);
        return _reply(expected, <String, dynamic>{
          'peer_account': contextResult.peerAccount,
          'anchor_message_id': contextResult.anchorMessageId,
          'range': <String, dynamic>{
            'start_position': contextResult.startPosition,
            'end_position': contextResult.endPosition,
          },
          'before_has_more': contextResult.beforeHasMore,
          'after_has_more': contextResult.afterHasMore,
          'missing_positions': contextResult.missingPositions,
          'missing_truncated': contextResult.missingTruncated,
          'reply_relations': contextResult.replyRelations,
          'items': items,
          'missing_media_ids': missing.take(9900).toList(),
        });
      case '/v2/chat/list_users':
        final UserPage page = await service.listUsers(
          afterAccount: (args.values['after_account'] as String?) ?? '',
          limit: (args.values['limit'] as int?) ?? 50,
        );
        return _reply(expected, page.toJson());
      case '/v2/chat/send_message':
        final SendOutcome outcome = await service.sendBody(
          targetAccount: args.values['target_account'] as String,
          content: args.content!,
          operationId: args.values['operation_id'] as String,
          expectedIdentity: expected,
        );
        final ChatMessage message = outcome.message ?? (throw upstreamMalformed);
        return _reply(expected, messageToJson(message));
      case '/v2/chat/send_attachment':
        final SendOutcome outcome = await service.sendAttachment(
          targetAccount: args.values['target_account'] as String,
          attachment: args.attachment!,
          operationId: args.values['operation_id'] as String,
          expectedIdentity: expected,
        );
        final ChatMessage message = outcome.message ?? (throw upstreamMalformed);
        return _reply(expected, messageToJson(message));
      case '/v2/chat/read_messages':
        final String peer = args.values['account'] as String;
        final HistoryPage history = await service.query.readHistory(
          peerAccount: peer,
          afterPosition: args.values['after_position'] as int?,
          beforePosition: args.values['before_position'] as int?,
          limit: (args.values['limit'] as int?) ?? 50,
        );
        final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
        for (final ChatMessage message in history.items) {
          final QueryVisibleMessage visible =
              await service.visibleMessageForQuery(
                captured: context.identity,
                binding: context.binding,
                peerAccount: peer,
                message: message,
              );
          items.add(visible.item.toJson());
        }
        _ensureCurrent(context.identity);
        return _reply(expected, <String, dynamic>{
          'items': items,
          'next_position': history.nextPosition,
          'has_more': history.hasMore,
        });
      case '/v2/chat/wait_messages':
        final VisibleMessagePage page = await service.waitMessages(
          peerAccount: args.values['account'] as String,
          consumerSession: context.binding.sessionId,
          seenPosition: args.values['seen_position'] as int,
          timeoutSeconds: (args.values['timeout'] as int?) ?? 60,
          expectedIdentity: expected,
        );
        return _reply(expected, page.toJson());
      case '/v2/chat/ack_messages':
        final int consumed = await service.ackMessages(
          peerAccount: args.values['account'] as String,
          consumerSession: context.binding.sessionId,
          throughPosition: args.values['through_position'] as int,
          expectedIdentity: expected,
        );
        return _reply(expected, <String, dynamic>{
          'consumed_through': consumed,
        });
      case '/v2/chat/consumption':
        final ({int consumedThrough, String migration}) consumption =
            await service.consumptionFor(
              expectedIdentity: expected,
              peerAccount: args.values['account'] as String,
            );
        return _reply(expected, <String, dynamic>{
          'consumed_through': consumption.consumedThrough,
          'migration': consumption.migration,
        });
      case '/v2/chat/confirm_presentation':
        final List<String> confirmed = await service.confirmPresentation(
          consumerSession: context.binding.sessionId,
          attemptId: args.values['attempt_id'] as String,
          requestDigest: args.values['request_digest'] as String,
          receiptIds: args.values['receipt_ids'] as List<String>,
          expectedIdentity: expected,
        );
        return _reply(expected, <String, dynamic>{
          'confirmed_receipt_ids': confirmed,
        });
      case '/v2/operations/get':
        final OperationResult? result = await service.operationForIdentity(
          expected,
          args.values['operation_id'] as String,
        );
        if (result == null) {
          throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
        }
        return _reply(expected, result.toJson());
      case '/v2/downloads/start':
        final DownloadTask task = await service.downloads.start(
          operationId: args.values['operation_id'] as String,
          consumerSession: context.binding.consumerId,
          mediaId: args.values['media_id'] as String,
          directory: args.values['directory'] as String?,
          expectedIdentity: expected,
        );
        return _reply(expected, _download(task), status: 202);
      case '/v2/downloads/get':
        final DownloadTask? task = await service.downloads.get(
          taskId: args.values['task_id'] as String,
          consumerSession: context.binding.consumerId,
        );
        if (task == null) {
          throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
        }
        return _reply(expected, _download(task));
      case '/v2/events/subscribe':
        final String peer = args.values['peer_account'] as String;
        await service.subscribeEventsFor(
          expectedIdentity: expected,
          peerAccount: peer,
        );
        return _reply(expected, <String, dynamic>{'peer_account': peer});
      case '/v2/events/read':
        final LocalEventPage page = await service.readEventsFor(
          expectedIdentity: expected,
          afterCursor: (args.values['after_cursor'] as int?) ?? 0,
          limit: (args.values['limit'] as int?) ?? 50,
        );
        return _reply(expected, _eventPage(page));
      case '/v2/events/wait':
        final LocalEventPage page = await service.waitEventsFor(
          expectedIdentity: expected,
          afterCursor: (args.values['after_cursor'] as int?) ?? 0,
          limit: (args.values['limit'] as int?) ?? 50,
          timeoutSeconds: (args.values['timeout'] as int?) ?? 60,
        );
        return _reply(expected, _eventPage(page, wait: true));
    }

    throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
  }

  _Args _parse(String path, _Request request) {
    final _Args args = _Args();
    if (path.startsWith('/v2/consumers/')) {
      args.expectedAuth = _expectedAuth(request);
      if (path != '/v2/consumers/create') {
        args.consumerId = request.opaque('consumer_id');
      }
      if (path == '/v2/consumers/bind') {
        args.revision = request.integer(
          'expected_binding_revision',
          1,
          maxBindingRevision,
        );
      }
      if (path != '/v2/consumers/get') {
        args.sessionId = request.opaque('session_id');
      }
      return args;
    }

    args.expectedIdentity = _expectedIdentity(request);
    switch (path) {
      case '/v2/chat/list_conversations':
        args.values['after_account'] =
            request.optionalPattern(
              'after_account',
              RegExp(r'^([1-9][0-9]{7})?$'),
            ) ??
            '';
        args.values['limit'] = request.optionalInteger('limit', 1, 100);
      case '/v2/chat/get_message':
        args.values['message_id'] = request.pattern(
          'message_id',
          RegExp(r'^[A-Za-z0-9_-]{1,200}$'),
        );
      case '/v2/chat/get_context':
        args.values['message_id'] = request.pattern(
          'message_id',
          RegExp(r'^[A-Za-z0-9_-]{1,200}$'),
        );
        args.values['before_limit'] = request.optionalInteger(
          'before_limit',
          0,
          49,
        );
        args.values['after_limit'] = request.optionalInteger(
          'after_limit',
          0,
          49,
        );
      case '/v2/chat/list_users':
        args.values['after_account'] = request.optionalString(
          'after_account',
          allowEmpty: true,
        );
        args.values['limit'] = request.optionalInteger('limit', 1, 100);
      case '/v2/chat/send_message':
        args.values['target_account'] = request.account('target_account');
        args.values['operation_id'] = request.operationId('operation_id');
        args.content = _content(request);
      case '/v2/chat/send_attachment':
        args.values['target_account'] = request.account('target_account');
        args.values['operation_id'] = request.operationId('operation_id');
        args.attachment = _attachment(request);
      case '/v2/chat/read_messages':
        args.values['account'] = request.account('account');
        final int? after = request.nullableInteger(
          'after_position',
          0,
          maxBindingRevision,
        );
        final int? before = request.nullableInteger(
          'before_position',
          1,
          maxBindingRevision,
        );
        if (after != null && before != null) {
          throw _validation('before_position');
        }
        args.values['after_position'] = after;
        args.values['before_position'] = before;
        args.values['limit'] = request.optionalInteger('limit', 1, 100);
      case '/v2/chat/wait_messages':
        args.values['account'] = request.account('account');
        args.values['seen_position'] = request.integer(
          'seen_position',
          0,
          maxBindingRevision,
        );
        args.values['timeout'] = request.timeout();
      case '/v2/chat/ack_messages':
        args.values['account'] = request.account('account');
        args.values['through_position'] = request.integer(
          'through_position',
          0,
          maxBindingRevision,
        );
      case '/v2/chat/consumption':
        args.values['account'] = request.account('account');
      case '/v2/chat/confirm_presentation':
        args.values['attempt_id'] = request.opaque('attempt_id');
        args.values['request_digest'] = request.pattern(
          'request_digest',
          RegExp(r'^[a-f0-9]{64}$'),
        );
        args.values['receipt_ids'] = request.opaqueList('receipt_ids', 1, 100);
      case '/v2/operations/get':
        args.values['operation_id'] = request.operationId('operation_id');
      case '/v2/downloads/start':
        args.values['operation_id'] = request.operationId('operation_id');
        args.values['media_id'] = request.string(
          'media_id',
          minLength: 1,
          maxLength: 200,
        );
        args.values['directory'] = request.optionalString(
          'directory',
          nullable: true,
        );
      case '/v2/downloads/get':
        args.values['task_id'] = request.opaque('task_id');
      case '/v2/events/subscribe':
        args.values['peer_account'] = request.account('peer_account');
      case '/v2/events/read':
        args.values['after_cursor'] = request.optionalInteger(
          'after_cursor',
          0,
          maxBindingRevision,
        );
        args.values['limit'] = request.optionalInteger('limit', 1, 100);
      case '/v2/events/wait':
        args.values['after_cursor'] = request.optionalInteger(
          'after_cursor',
          0,
          maxBindingRevision,
        );
        args.values['limit'] = request.optionalInteger('limit', 1, 100);
        args.values['timeout'] = request.timeout();
      default:
        throw _V2Error(404, 'not_found', _messageByCode['not_found']!);
    }
    return args;
  }

  ChatService _requireChat() {
    final ChatService? service = chat;
    if (service == null) {
      throw _V2Error(
        503,
        'storage_unavailable',
        _messageByCode['storage_unavailable']!,
      );
    }
    return service;
  }

  AuthIdentity _requireLogin() {
    final AuthIdentity? identity = session.identity;
    if (identity == null) {
      throw unauthenticated;
    }
    return identity;
  }

  _ExpectedAuth _expectedAuth(_Request request) {
    final Map<String, dynamic> value = request.object(
      'expected_auth',
      const <String>{'account', 'auth_generation'},
    );
    return _ExpectedAuth(
      account: _accountValue(value['account'], 'expected_auth'),
      authGeneration: _opaqueValue(value['auth_generation'], 'expected_auth'),
    );
  }

  ExpectedIdentity _expectedIdentity(_Request request) {
    final Map<String, dynamic> value = request.object(
      'expected_identity',
      const <String>{
        'account',
        'auth_generation',
        'consumer_id',
        'binding_revision',
      },
    );
    final Object? revision = value['binding_revision'];
    if (revision is! int ||
        revision < 1 ||
        revision > maxBindingRevision) {
      throw _validation('expected_identity');
    }
    try {
      return ExpectedIdentity(
        account: _accountValue(value['account'], 'expected_identity'),
        authGeneration: _opaqueValue(
          value['auth_generation'],
          'expected_identity',
        ),
        consumerId: _opaqueValue(value['consumer_id'], 'expected_identity'),
        bindingRevision: revision,
      );
    } on FormatException {
      throw _validation('expected_identity');
    }
  }

  String _ownerHash(String? ownerKey) {
    if (ownerKey == null || !isValidOwnerKey(ownerKey)) {
      throw staleBinding('缺少或无效的消费者能力');
    }
    return ownerKeyHash(ownerKey);
  }

  Map<String, dynamic> _binding(ConsumerBinding binding, AuthIdentity current) {
    return <String, dynamic>{
      'identity': binding.identity.toJson(),
      'session_id': binding.sessionId,
      'active':
          binding.account == current.account &&
          binding.authGeneration == current.authGeneration,
      'migration': binding.migration,
    };
  }

  void _ensureCurrent(AuthIdentity captured) {
    if (!session.isCurrent(captured)) {
      throw staleIdentity;
    }
  }

  String _peerOf(ChatMessage message, String selfAccount) {
    return message.senderAccount == selfAccount
        ? message.targetAccount
        : message.senderAccount;
  }

  ({int status, Map<String, dynamic> body}) _reply(
    ExpectedIdentity identity,
    Map<String, dynamic> result, {
    int status = 200,
  }) {
    return (
      status: status,
      body: <String, dynamic>{
        'identity': identity.toJson(),
        'result': result,
      },
    );
  }

  Map<String, dynamic> _download(DownloadTask task) {
    final Map<String, dynamic>? originJson = task.originIdentity;
    final ExpectedIdentity? origin = originJson == null
        ? null
        : ExpectedIdentity.tryParse(originJson);
    if (origin == null) {
      // A task admitted before v2 has no provable origin; never re-label it
      // with the caller's new binding.
      throw _V2Error(
        409,
        'migration_required',
        _messageByCode['migration_required']!,
      );
    }
    return <String, dynamic>{
      'task_id': task.taskId,
      'operation_id': task.operationId,
      'origin_identity': origin.toJson(),
      'status': task.status.wire,
      'planned_path': task.plannedPath,
      'actual_path': task.status == DownloadStatus.succeeded
          ? task.actualPath
          : null,
      'error_code': task.errorCode,
    };
  }

  Map<String, dynamic> _eventPage(LocalEventPage page, {bool wait = false}) {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final LocalEventEntry entry in page.items) {
      items.add(<String, dynamic>{
        'cursor': entry.cursor,
        'event': _event(entry.event),
      });
    }
    return <String, dynamic>{
      'items': items,
      'next_cursor': page.nextCursor,
      'has_more': page.hasMore,
      if (wait) 'reason': _waitReason(page.reason),
    };
  }

  Map<String, dynamic> _event(LocalEvent event) {
    final Map<String, dynamic>? originJson = event.originIdentity;
    final ExpectedIdentity? origin = originJson == null
        ? null
        : ExpectedIdentity.tryParse(originJson);
    if (origin == null) {
      // History without a provable origin cannot be rewritten to a new
      // binding; keep the cursor and report migration.
      throw _V2Error(
        409,
        'migration_required',
        _messageByCode['migration_required']!,
      );
    }
    final String eventId = base64Url
        .encode(utf8.encode(event.eventId))
        .replaceAll('=', '');
    final Map<String, dynamic> base = <String, dynamic>{
      'version': 2,
      'event_id': eventId,
      'origin_identity': origin.toJson(),
    };
    switch (event.type) {
      case LocalEventType.messageAvailable:
        final String? peer = event.peerAccount;
        final int? position = event.position;
        if (peer == null || position == null) {
          throw _V2Error(
            409,
            'migration_required',
            _messageByCode['migration_required']!,
          );
        }
        return <String, dynamic>{
          ...base,
          'type': 'message.available',
          'peer_account': peer,
          'position': position,
        };
      case LocalEventType.downloadSucceeded:
        final String? taskId = event.taskId;
        final String? operationId = event.operationId;
        final String? path = event.actualPath;
        if (taskId == null || operationId == null || path == null) {
          throw _V2Error(
            409,
            'migration_required',
            _messageByCode['migration_required']!,
          );
        }
        return <String, dynamic>{
          ...base,
          'type': 'download.succeeded',
          'task_id': taskId,
          'operation_id': operationId,
          'actual_path': path,
        };
      case LocalEventType.downloadFailed:
        final String? taskId = event.taskId;
        final String? operationId = event.operationId;
        final String? code = event.errorCode;
        if (taskId == null || operationId == null || code == null) {
          throw _V2Error(
            409,
            'migration_required',
            _messageByCode['migration_required']!,
          );
        }
        return <String, dynamic>{
          ...base,
          'type': 'download.failed',
          'task_id': taskId,
          'operation_id': operationId,
          'error_code': code,
        };
    }
  }

  String _waitReason(String? reason) {
    return switch (reason) {
      'events' => 'events',
      'timeout' => 'timeout',
      'cancelled' || 'logout' => 'cancelled',
      'disconnected' => 'disconnected',
      _ => 'events',
    };
  }

  List<OutgoingPart> _content(_Request request) {
    final List<dynamic> raw = request.list('content', 1, 100);
    final List<OutgoingPart> parts = <OutgoingPart>[];
    for (final Object? entry in raw) {
      if (entry is! Map<String, dynamic>) {
        throw _validation('content');
      }
      final Object? type = entry['type'];
      if (type == 'text') {
        _expectKeys(entry, const <String>{'type', 'text'}, 'content');
        final String text = _textValue(entry['text']);
        parts.add(OutgoingText(text));
        continue;
      }
      if (type == 'image') {
        _expectKeys(entry, const <String>{'type', 'source'}, 'content');
        final Object? source = entry['source'];
        if (source is! Map<String, dynamic>) {
          throw _validation('content');
        }
        _expectKeys(
          source,
          const <String>{'base64', 'path', 'url', 'mime_type', 'filename'},
          'content',
        );
        _validateSource(source, 'content');
        parts.add(OutgoingImage(MediaSource.fromJson(source)));
        continue;
      }
      throw _validation('content');
    }
    return parts;
  }

  OutgoingAttachment _attachment(_Request request) {
    if (!request.contains('cover')) {
      throw _validation('cover');
    }
    final Map<String, dynamic> source = request.object(
      'source',
      const <String>{'base64', 'path', 'url', 'mime_type', 'filename'},
    );
    _validateSource(source, 'source');
    Map<String, dynamic>? cover;
    if (request.raw['cover'] != null) {
      cover = request.object(
        'cover',
        const <String>{'base64', 'path', 'url', 'mime_type', 'filename'},
      );
      _validateSource(cover, 'cover');
    }
    return OutgoingAttachment(
      source: MediaSource.fromJson(source),
      cover: cover == null ? null : MediaSource.fromJson(cover),
    );
  }

  void _validateSource(Map<String, dynamic> source, String field) {
    final bool hasBase64 = source['base64'] is String;
    final bool hasPath = source['path'] is String;
    final bool hasUrl = source['url'] is String;
    if ((hasBase64 ? 1 : 0) + (hasPath ? 1 : 0) + (hasUrl ? 1 : 0) != 1) {
      throw _validation(field);
    }
    for (final String key in <String>['mime_type', 'filename']) {
      final Object? value = source[key];
      if (value is! String || value.isEmpty) {
        throw _validation(field);
      }
    }
  }

  String _textValue(Object? value) {
    if (value is! String || value.isEmpty || value.length > 20000) {
      throw _validation('content');
    }
    return value;
  }

  String _accountValue(Object? value, String field) {
    if (value is! String || !ExpectedIdentity.isValidAccount(value)) {
      throw _validation(field);
    }
    return value;
  }

  String _opaqueValue(Object? value, String field) {
    if (value is! String || !ExpectedIdentity.isValidOpaque(value)) {
      throw _validation(field);
    }
    return value;
  }

  void _expectKeys(Map<String, dynamic> value, Set<String> allowed, String field) {
    if (value.keys.any((String key) => !allowed.contains(key))) {
      throw _validation(field);
    }
  }

  _V2Error _validation(String field) => _V2Error(
    422,
    'validation_error',
    _messageByCode['validation_error']!,
    <String>[field],
  );

  ({int status, Map<String, dynamic> body}) _fromFailure(
    AuthFailure failure,
    String path,
  ) {
    String code = failure.code == 'conflict'
        ? idempotencyConflictCode
        : failure.code;
    if (!_statusByCode.containsKey(code)) {
      code = 'upstream_unavailable';
    }
    final Set<String> known = <String>{
      ...(_fields[path] ?? const <String>{}),
      'body',
    };
    final List<String> fields = <String>[];
    for (final AuthFieldError item in failure.fields) {
      if (known.contains(item.field) && !fields.contains(item.field)) {
        fields.add(item.field);
      }
      if (fields.length >= 20) {
        break;
      }
    }
    return (
      status: _statusByCode[code]!,
      body: _error(
        _V2Error(
          _statusByCode[code]!,
          code,
          _messageByCode[code] ?? '请求未完成',
          fields,
        ),
      ),
    );
  }

  Map<String, dynamic> _error(_V2Error failure) {
    return <String, dynamic>{
      'error': <String, dynamic>{
        'code': failure.code,
        'message': failure.message,
        'fields': failure.fields,
      },
    };
  }
}

class _V2Error implements Exception {
  const _V2Error(this.status, this.code, this.message, [this.fields = const <String>[]]);

  final int status;
  final String code;
  final String message;
  final List<String> fields;
}

class _Args {
  _ExpectedAuth? expectedAuth;
  ExpectedIdentity? expectedIdentity;
  String? consumerId;
  int? revision;
  String? sessionId;
  final Map<String, Object?> values = <String, Object?>{};
  List<OutgoingPart>? content;
  OutgoingAttachment? attachment;
}

class _ExpectedAuth {
  const _ExpectedAuth({required this.account, required this.authGeneration});

  final String account;
  final String authGeneration;
}

/// Strict request accessor: unknown keys and explicit null are rejected.
class _Request {
  _Request(this.raw, this.allowed);

  final Map<String, dynamic> raw;
  final Set<String> allowed;

  bool contains(String field) => raw.containsKey(field);

  void check() {
    for (final String key in raw.keys) {
      if (!allowed.contains(key)) {
        throw _V2Error(
          422,
          'validation_error',
          '输入有误',
          <String>['body'],
        );
      }
    }
  }

  Map<String, dynamic> object(String field, Set<String> keys) {
    if (!raw.containsKey(field)) {
      throw _missing(field);
    }
    final Object? value = raw[field];
    if (value is! Map<String, dynamic>) {
      throw _invalid(field);
    }
    for (final String key in value.keys) {
      if (!keys.contains(key)) {
        throw _invalid(field);
      }
    }
    return value;
  }

  List<dynamic> list(String field, int min, int max) {
    if (!raw.containsKey(field)) {
      throw _missing(field);
    }
    final Object? value = raw[field];
    if (value is! List || value.length < min || value.length > max) {
      throw _invalid(field);
    }
    return value;
  }

  String account(String field) {
    final Object? value = raw[field];
    if (value is! String || !ExpectedIdentity.isValidAccount(value)) {
      throw raw.containsKey(field) ? _invalid(field) : _missing(field);
    }
    return value;
  }

  String opaque(String field) {
    final Object? value = raw[field];
    if (value is! String || !ExpectedIdentity.isValidOpaque(value)) {
      throw raw.containsKey(field) ? _invalid(field) : _missing(field);
    }
    return value;
  }

  String operationId(String field) {
    final Object? value = raw[field];
    if (value is! String ||
        value.isEmpty ||
        value.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw raw.containsKey(field) ? _invalid(field) : _missing(field);
    }
    return value;
  }

  String pattern(String field, RegExp pattern) {
    final Object? value = raw[field];
    if (value is! String || !pattern.hasMatch(value)) {
      throw raw.containsKey(field) ? _invalid(field) : _missing(field);
    }
    return value;
  }

  String? string(
    String field, {
    bool allowEmpty = false,
    int minLength = 0,
    int? maxLength,
    bool nullable = false,
  }) {
    if (!raw.containsKey(field)) {
      throw _missing(field);
    }
    final Object? value = raw[field];
    if (value == null && nullable) {
      return null;
    }
    if (value is! String ||
        value.length < minLength ||
        (value.isEmpty && !allowEmpty) ||
        (maxLength != null && value.length > maxLength)) {
      throw _invalid(field);
    }
    return value;
  }

  int? integer(String field, int min, int max) {
    if (!raw.containsKey(field)) {
      throw _missing(field);
    }
    final Object? value = raw[field];
    if (value is! int || value < min || value > max) {
      throw _invalid(field);
    }
    return value;
  }

  int? timeout() {
    if (!raw.containsKey('timeout')) {
      return null;
    }
    final Object? value = raw['timeout'];
    if (value is! int || !const <int>{30, 60, 120}.contains(value)) {
      throw _invalid('timeout');
    }
    return value;
  }

  List<String> opaqueList(String field, int min, int max) {
    final List<dynamic> rawList = list(field, min, max);
    final List<String> result = <String>[];
    for (final Object? entry in rawList) {
      if (entry is! String || !ExpectedIdentity.isValidOpaque(entry)) {
        throw _invalid(field);
      }
      result.add(entry);
    }
    return result;
  }

  int? nullableInteger(String field, int min, int max) {
    if (!raw.containsKey(field) || raw[field] == null) {
      return null;
    }
    final Object? value = raw[field];
    if (value is! int || value < min || value > max) {
      throw _invalid(field);
    }
    return value;
  }

  String? optionalPattern(String field, RegExp pattern) {
    if (!raw.containsKey(field) || raw[field] == null) {
      return null;
    }
    final Object? value = raw[field];
    if (value is! String || !pattern.hasMatch(value)) {
      throw _invalid(field);
    }
    return value;
  }

  String? optionalString(
    String field, {
    bool allowEmpty = false,
    bool nullable = false,
  }) {
    if (!raw.containsKey(field)) {
      return null;
    }
    final Object? value = raw[field];
    if (value == null && nullable) {
      return null;
    }
    if (value is! String || (value.isEmpty && !allowEmpty)) {
      throw _invalid(field);
    }
    return value;
  }

  int? optionalInteger(String field, int min, int max) {
    if (!raw.containsKey(field)) {
      return null;
    }
    final Object? value = raw[field];
    if (value is! int || value < min || value > max) {
      throw _invalid(field);
    }
    return value;
  }

  _V2Error _missing(String field) =>
      _V2Error(422, 'validation_error', '输入有误', <String>[field]);

  _V2Error _invalid(String field) =>
      _V2Error(422, 'validation_error', '输入有误', <String>[field]);
}
