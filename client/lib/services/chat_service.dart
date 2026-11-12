import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show Uint8List;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'chat_ledger.dart';
import 'client_identity.dart';
import 'download_manager.dart';
import 'event_feed.dart';
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
  }) : _resolver = resolver ?? MediaSourceResolver(),
       _coverExtractor = coverExtractor ?? FfmpegVideoCoverExtractor(),
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    eventFeed = EventFeed(
      api: api,
      session: session,
      ledger: ledger,
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

  late final EventFeed eventFeed;
  late DownloadManager downloads;
  late MediaStreamProxy mediaStreams;

  final Map<String, Uint8List> _mediaCache = <String, Uint8List>{};
  final List<String> _mediaCacheOrder = <String>[];
  static const int _maxCachedMediaEntries = 48;
  static const int _maxCachedMediaBytes = 6 * 1024 * 1024;

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

  /// Consumer-scoped consumption plus legacy migration state.
  Future<({int consumedThrough, String migration})> consumptionFor({
    required ExpectedIdentity expectedIdentity,
    required String peerAccount,
  }) async {
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await requireIdentity(expectedIdentity);
    final int consumed = await ledger.consumedThrough(
      context.identity.account,
      peerAccount,
      consumerId: context.binding.consumerId,
    );
    return (consumedThrough: consumed, migration: context.binding.migration);
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
    if (record.state == 'succeeded' && record.message != null) {
      return OperationResult(
        operationId: operationId,
        kind: record.kind,
        status: OperationStatus.succeeded,
        message: record.message,
      );
    }
    final OperationResult? remote = await api.getOperation(
      token: context.identity.token,
      operationId: operationId,
    );
    if (remote != null) {
      if (remote.status == OperationStatus.succeeded &&
          remote.message != null) {
        await _succeed(account, record, remote.message!);
      }
      return remote;
    }
    return OperationResult(
      operationId: operationId,
      kind: record.kind,
      status: switch (record.state) {
        'succeeded' => OperationStatus.succeeded,
        'failed' => OperationStatus.failed,
        'uncertain' => OperationStatus.uncertain,
        _ => OperationStatus.pending,
      },
      message: record.message,
      errorCode: record.errorCode,
    );
  }

  Future<void> subscribeEventsFor({
    required ExpectedIdentity expectedIdentity,
    required String peerAccount,
  }) async {
    await requireIdentity(expectedIdentity);
    await eventFeed.subscribe(
      consumerSession: expectedIdentity.consumerId,
      peerAccount: peerAccount,
    );
  }

  Future<LocalEventPage> readEventsFor({
    required ExpectedIdentity expectedIdentity,
    required int afterCursor,
    int limit = 50,
  }) async {
    await requireIdentity(expectedIdentity);
    return eventFeed.read(
      consumerSession: expectedIdentity.consumerId,
      afterCursor: afterCursor,
      limit: limit,
    );
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
    await requireIdentity(expectedIdentity);
    return eventFeed.wait(
      consumerSession: expectedIdentity.consumerId,
      afterCursor: afterCursor,
      limit: limit,
      timeout: Duration(seconds: timeoutSeconds),
    );
  }

  /// Current client-issued identity metadata for one consumer alias.
  ///
  /// This is what a v2 caller echoes back as `expected_identity`; it contains
  /// no token.
  Future<ExpectedIdentity> identityFor(String consumerSession) async {
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        await _captureBinding(consumerSession);
    return context.binding.identity;
  }

  /// Captures the login identity and resolves the stable consumer binding in
  /// one business-layer step.
  ///
  /// The returned pair is the only source of account/consumer for the rest of
  /// the operation: later steps never re-read the mutable session to decide
  /// which account's row to write or which token to use.
  Future<({AuthIdentity identity, ConsumerBinding binding})> _captureBinding(
    String consumerSession,
  ) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final ConsumerBinding binding = await ledger.bindConsumer(
      account: captured.account,
      authGeneration: captured.authGeneration,
      consumerSession: consumerSession,
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

  Future<UserPage> listUsers({String afterAccount = '', int limit = 50}) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final UserPage page = await api.listUsers(
      token: captured.token,
      afterAccount: afterAccount,
      limit: limit.clamp(1, 100),
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    return page;
  }

  Future<MessagePage> loadConversation({
    required String peerAccount,
    int afterPosition = 0,
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
      limit: limit.clamp(1, 100),
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
    if (record == null) {
      // The server's own idempotency record may be the only evidence left
      // after a process crashed before persisting a local result.
      return api.getOperation(token: captured.token, operationId: operationId);
    }
    if (record.state == 'succeeded' && record.message != null) {
      return OperationResult(
        operationId: operationId,
        kind: 'message',
        status: OperationStatus.succeeded,
        message: record.message,
        errorCode: record.errorCode,
      );
    }
    // A local non-terminal record is not proof of failure. Ask the server
    // before reporting anything, and never mint a new operation id.
    final OperationResult? remote = await api.getOperation(
      token: captured.token,
      operationId: operationId,
    );
    if (remote != null) {
      return remote;
    }
    return OperationResult(
      operationId: operationId,
      kind: 'message',
      status: switch (record.state) {
        'failed' => OperationStatus.failed,
        'succeeded' => OperationStatus.succeeded,
        _ => OperationStatus.pending,
      },
      message: record.message,
      errorCode: record.errorCode,
    );
  }

  // ------------------------------------------------------------------ send --

  /// Sends an ordered body. The same [operationId] always maps to the same
  /// server message; retries reuse it and never resend a success under a new ID.
  Future<SendOutcome> sendBody({
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
        ? await _captureBinding(_humanSession(maybeCurrent.account))
        : await requireIdentity(expectedIdentity);
    final AuthIdentity captured = context.identity;
    final String account = captured.account;
    final String token = captured.token;
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
      _expectSameOperation(record, targetAccount, sourceDigest, 'message');
      if (record.state == 'succeeded' && record.message != null) {
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
        return _reconcileStalePlan(captured, account, record, cleaned);
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
        final Attachment uploaded = await api.uploadMedia(
          token: token,
          targetAccount: targetAccount,
          bytes: media.bytes,
          filename: media.filename,
          mimeType: media.mimeType,
        );
        mediaIds[imageIndex] = uploaded.mediaId;
        if (!session.isCurrent(captured)) {
          throw unauthenticated;
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
      throw unauthenticated;
    }
    return _submitBody(captured, account, record, cleaned, mediaIds);
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
        return await api.sendMessage(
          token: captured.token,
          targetAccount: targetAccount,
          clientNonce: clientNonce,
          content: content,
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
            throw unauthenticated;
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
        return await api.sendAttachment(
          token: captured.token,
          targetAccount: targetAccount,
          clientNonce: clientNonce,
          mediaId: mediaId,
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
            throw unauthenticated;
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
      throw unauthenticated;
    }
    if (record.state == 'uncertain') {
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
      // this call's result into 401, it must not turn a committed send into a
      // lost local fact.
      await _succeed(account, record, message);
      if (!session.isCurrent(captured)) {
        throw unauthenticated;
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
          throw unauthenticated;
        }
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
            throw unauthenticated;
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
  }) async {
    final AuthIdentity? maybeCurrent = session.identity;
    if (maybeCurrent == null) {
      throw unauthenticated;
    }
    final ({AuthIdentity identity, ConsumerBinding binding}) context =
        expectedIdentity == null
        ? await _captureBinding(_humanSession(maybeCurrent.account))
        : await requireIdentity(expectedIdentity);
    final AuthIdentity captured = context.identity;
    final String account = captured.account;
    final String token = captured.token;
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
      _expectSameOperation(record, targetAccount, sourceDigest, 'attachment');
      if (record.state == 'succeeded' && record.message != null) {
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
        return _reconcileStaleAttachment(captured, account, record, attachment);
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
          final Attachment uploadedCover = await api.uploadMedia(
            token: token,
            targetAccount: targetAccount,
            bytes: cover.bytes,
            filename: cover.filename,
            mimeType: cover.mimeType,
          );
          coverId = uploadedCover.mediaId;
          if (!session.isCurrent(captured)) {
            throw unauthenticated;
          }
        }
      }
      final Attachment uploaded = await api.uploadMedia(
        token: token,
        targetAccount: targetAccount,
        bytes: media.bytes,
        filename: filename,
        mimeType: mimeType,
        coverMediaId: coverId,
      );
      mediaId = uploaded.mediaId;
      if (!session.isCurrent(captured)) {
        throw unauthenticated;
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
      throw unauthenticated;
    }
    return _submitAttachment(captured, account, record, attachment);
  }

  Future<SendOutcome> _submitAttachment(
    AuthIdentity captured,
    String account,
    ChatOperationRecord record,
    OutgoingAttachment attachment,
  ) async {
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    if (record.state == 'uncertain') {
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
        throw unauthenticated;
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
          throw unauthenticated;
        }
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
        try {
          final ChatMessage message = await _sendAttachmentWithStorageRetry(
            captured: captured,
            targetAccount: record.targetAccount,
            clientNonce: record.operationId,
            mediaId: record.resolvedMediaId!,
          );
          await _succeed(account, record, message);
          if (!session.isCurrent(captured)) {
            throw unauthenticated;
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
        message: message,
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
    if (!captured.sameAs(session.identity)) {
      throw unauthenticated;
    }
    final List<VisibleBlock> blocks = <VisibleBlock>[];
    if (message.kind == ChatMessageKind.body) {
      for (final MessagePart part in message.parts) {
        if (part is TextPart) {
          blocks.add(VisibleTextBlock(part.text));
        } else if (part is ImagePart) {
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
      }
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
    );
    return VisibleMessage(
      message: message,
      blocks: List<VisibleBlock>.unmodifiable(blocks),
      presentation: receipt,
    );
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
        await _captureBinding(consumerSession);
    final AuthIdentity captured = context.identity;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final List<String> confirmed = await ledger.confirmPresentationAttempt(
      account: captured.account,
      consumerId: context.binding.consumerId,
      consumerSession: consumerSession,
      attemptId: attemptId,
      requestDigest: requestDigest,
      receiptIds: receiptIds,
    );
    // An in-flight request must never be applied to a different account after
    // a login switch. The write above is already scoped to the captured
    // account; this check makes such a switch observable to the caller.
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
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
        await _captureBinding(consumerSession);
    final AuthIdentity captured = context.identity;
    _expectCurrentIdentity(expectedIdentity, context.binding, captured);
    final String consumerId = context.binding.consumerId;
    final String account = captured.account;
    // Scope validation (above) happens before the idempotent short-circuit: a
    // consumer without receipts can never inherit another consumer's cursor.
    final int consumed = await ledger.consumedThrough(
      account,
      peerAccount,
      consumerId: consumerId,
    );
    if (throughPosition <= consumed) {
      return consumed;
    }
    final List<PresentationReceipt> receipts = await ledger.receiptsForPeer(
      account: account,
      consumerSession: consumerSession,
      peerAccount: peerAccount,
      consumerId: consumerId,
    );
    final Map<int, bool> confirmedByPosition = <int, bool>{
      for (final PresentationReceipt receipt in receipts)
        if (receipt.consumerId == consumerId ||
            (receipt.consumerId == null &&
                receipt.consumerSession == consumerSession))
          receipt.position: receipt.confirmed,
    };
    final List<int> gaps = <int>[
      for (int position = consumed + 1; position <= throughPosition; position++)
        if (confirmedByPosition[position] != true) position,
    ];
    if (gaps.isNotEmpty) {
      final Map<String, dynamic>? legacy = await ledger.legacyMigrationForPeer(
        account,
        peerAccount,
      );
      final int? legacyWatermark = legacy?['legacy_watermark'] is int
          ? legacy!['legacy_watermark'] as int
          : null;
      if (legacy != null &&
          legacy['outcome'] == 'migration_required' &&
          legacyWatermark != null &&
          gaps.any((int position) => position <= legacyWatermark)) {
        // The legacy watermark exists but cannot be proven for this consumer:
        // keep it preserved, advance nothing, and report migration.
        throw migrationRequired(
          '旧消费水位无法从可验证 receipts 迁移，请显式迁移或重新确认',
          fields: <AuthFieldError>[
            AuthFieldError(
              field: 'through_position',
              code: migrationRequiredCode,
              message: '位置 ${_summarize(gaps)} 缺少可迁移的展示凭据',
            ),
          ],
        );
      }
      throw consumptionGap(
        '消费水位存在未确认展示的位置',
        fields: <AuthFieldError>[
          AuthFieldError(
            field: 'through_position',
            code: 'gap',
            message: '缺少展示确认的位置：${_summarize(gaps)}',
          ),
        ],
      );
    }
    await ledger.setConsumedThrough(
      account,
      peerAccount,
      throughPosition,
      consumerId: consumerId,
    );
    if (!session.isCurrent(captured)) {
      throw unauthenticated;
    }
    return throughPosition;
  }

  // ----------------------------------------------------------------- media --

  Future<Uint8List> mediaBytes(String mediaId) async {
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final String cacheKey = '${captured.account}\u0001$mediaId';
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

  Future<String> saveAs({required String mediaId, required String targetPath}) {
    return downloads.saveAsCopy(mediaId: mediaId, targetPath: targetPath);
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

  static String _summarize(List<int> positions) {
    if (positions.length <= 5) {
      return positions.join(', ');
    }
    return '${positions.take(4).join(', ')}… (${positions.length})';
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
