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
      onEvent: (LocalEvent event) => eventFeed.appendEvent(event),
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

  String get _token {
    final String? token = session.tokenForRequest;
    if (token == null || token.isEmpty) {
      throw unauthenticated;
    }
    return token;
  }

  // --------------------------------------------------------------- account --

  Future<UserPage> listUsers({String afterAccount = '', int limit = 50}) {
    return api.listUsers(
      token: _token,
      afterAccount: afterAccount,
      limit: limit.clamp(1, 100),
    );
  }

  Future<MessagePage> loadConversation({
    required String peerAccount,
    int afterPosition = 0,
    int limit = 50,
  }) {
    selfAccount;
    return api.conversation(
      token: _token,
      account: peerAccount,
      afterPosition: afterPosition,
      limit: limit.clamp(1, 100),
    );
  }

  Future<OperationResult?> getOperation(String operationId) async {
    _validateOperationId(operationId);
    final String account = selfAccount;
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
      // Fall back to the server's own idempotency record (a previous process
      // may have submitted without persisting the local result).
      final OperationResult? remote = await api.getOperation(
        token: _token,
        operationId: operationId,
      );
      return remote;
    }
    return OperationResult(
      operationId: operationId,
      kind: 'message',
      status: switch (record.state) {
        'succeeded' => OperationStatus.succeeded,
        'failed' => OperationStatus.failed,
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
  }) async {
    final String account = selfAccount;
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
          token: _token,
          targetAccount: targetAccount,
          bytes: media.bytes,
          filename: media.filename,
          mimeType: media.mimeType,
        );
        mediaIds[imageIndex] = uploaded.mediaId;
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
    );
    await ledger.saveOperation(account, record);
    return _submitBody(account, record, cleaned, mediaIds);
  }

  Future<SendOutcome> _submitBody(
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
    if (record.state == 'uncertain') {
      final OperationResult? resolved = await getOperation(record.operationId);
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
      final ChatMessage message = await api.sendMessage(
        token: _token,
        targetAccount: record.targetAccount,
        clientNonce: record.operationId,
        content: parts,
      );
      await _succeed(account, record, message);
      return SendOutcome(
        operationId: record.operationId,
        message: message,
        part: content,
      );
    } on AuthFailure catch (failure) {
      if (_isUncertain(failure)) {
        await _markUncertain(account, record);
        final OperationResult? resolved = await getOperation(
          record.operationId,
        );
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
          final ChatMessage message = await api.sendMessage(
            token: _token,
            targetAccount: record.targetAccount,
            clientNonce: record.operationId,
            content: parts,
          );
          await _succeed(account, record, message);
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
          await _markFailed(account, record, again);
          rethrow;
        }
      }
      await _markFailed(account, record, failure);
      rethrow;
    }
  }

  Future<SendOutcome> sendAttachment({
    required String targetAccount,
    required OutgoingAttachment attachment,
    String? operationId,
  }) async {
    final String account = selfAccount;
    final String opId = operationId ?? newOperationId('a');
    _validateOperationId(opId);
    final String sourceDigest = _digestOfAttachment(targetAccount, attachment);
    ChatOperationRecord? record = await ledger.operation(account, opId);
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
            token: _token,
            targetAccount: targetAccount,
            bytes: cover.bytes,
            filename: cover.filename,
            mimeType: cover.mimeType,
          );
          coverId = uploadedCover.mediaId;
        }
      }
      final Attachment uploaded = await api.uploadMedia(
        token: _token,
        targetAccount: targetAccount,
        bytes: media.bytes,
        filename: filename,
        mimeType: mimeType,
        coverMediaId: coverId,
      );
      mediaId = uploaded.mediaId;
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
    );
    await ledger.saveOperation(account, record);
    return _submitAttachment(account, record, attachment);
  }

  Future<SendOutcome> _submitAttachment(
    String account,
    ChatOperationRecord record,
    OutgoingAttachment attachment,
  ) async {
    if (record.state == 'uncertain') {
      final OperationResult? resolved = await getOperation(record.operationId);
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
      final ChatMessage message = await api.sendAttachment(
        token: _token,
        targetAccount: record.targetAccount,
        clientNonce: record.operationId,
        mediaId: record.resolvedMediaId!,
      );
      await _succeed(account, record, message);
      return SendOutcome(
        operationId: record.operationId,
        message: message,
        attachment: attachment,
      );
    } on AuthFailure catch (failure) {
      if (_isUncertain(failure)) {
        await _markUncertain(account, record);
        final OperationResult? resolved = await getOperation(
          record.operationId,
        );
        if (resolved?.message != null) {
          await _succeed(account, record, resolved!.message!);
          return SendOutcome(
            operationId: record.operationId,
            message: resolved.message,
            attachment: attachment,
          );
        }
        try {
          final ChatMessage message = await api.sendAttachment(
            token: _token,
            targetAccount: record.targetAccount,
            clientNonce: record.operationId,
            mediaId: record.resolvedMediaId!,
          );
          await _succeed(account, record, message);
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
          await _markFailed(account, record, again);
          rethrow;
        }
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
    final String seed = operationSeed ?? newOperationId('x');
    SendOutcome? bodyOutcome;
    final List<SendOutcome> outcomes = <SendOutcome>[];
    final List<OutgoingPart> cleaned = <OutgoingPart>[
      for (final OutgoingPart part in body)
        if (part is! OutgoingText || part.text.isNotEmpty) part,
    ];
    if (cleaned.isNotEmpty) {
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
    for (int i = 0; i < attachments.length; i++) {
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
  }) async {
    _validateConsumer(consumerSession);
    final MessagePage page = await loadConversation(
      peerAccount: peerAccount,
      afterPosition: afterPosition,
      limit: limit,
    );
    final List<VisibleMessage> visible = <VisibleMessage>[];
    for (final ChatMessage message in page.items) {
      visible.add(await _visible(peerAccount, consumerSession, message));
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
  }) async {
    _validateConsumer(consumerSession);
    if (seenPosition < 0) {
      throw _validation('seen_position 不能为负');
    }
    if (!const <int>{30, 60, 120}.contains(timeoutSeconds)) {
      throw _validation('timeout 只能是 30、60 或 120 秒');
    }
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
      if (!session.hasToken) {
        return VisibleMessagePage(
          items: const <VisibleMessage>[],
          nextPosition: seenPosition,
          hasMore: false,
          reason: 'logout',
        );
      }
      final MessagePage page = await loadConversation(
        peerAccount: peerAccount,
        afterPosition: seenPosition,
        limit: 50,
      );
      if (page.items.isNotEmpty) {
        final List<VisibleMessage> visible = <VisibleMessage>[];
        for (final ChatMessage message in page.items) {
          visible.add(await _visible(peerAccount, consumerSession, message));
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
    String peerAccount,
    String consumerSession,
    ChatMessage message,
  ) async {
    final String account = selfAccount;
    final List<VisibleBlock> blocks = <VisibleBlock>[];
    if (message.kind == ChatMessageKind.body) {
      for (final MessagePart part in message.parts) {
        if (part is TextPart) {
          blocks.add(VisibleTextBlock(part.text));
        } else if (part is ImagePart) {
          final MediaResponse media = await api.fetchMedia(
            token: _token,
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
          token: _token,
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
      account: account,
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
  }) async {
    _validateConsumer(consumerSession);
    if (attemptId.trim().isEmpty) {
      throw _validation('attempt_id 不能为空');
    }
    if (requestDigest.trim().isEmpty) {
      throw _validation('request_digest 不能为空');
    }
    final String account = selfAccount;
    final List<String> confirmed = await ledger.confirmPresentationAttempt(
      account: account,
      consumerSession: consumerSession,
      attemptId: attemptId,
      requestDigest: requestDigest,
      receiptIds: receiptIds,
    );
    // An in-flight request must never be applied to a different account after
    // a login switch. The write above is already scoped to the captured
    // account; this check makes such a switch observable to the caller.
    if (session.user?.account != account || !session.hasToken) {
      throw unauthenticated;
    }
    return confirmed;
  }

  // ------------------------------------------------------------------ ACK ----

  Future<int> ackMessages({
    required String peerAccount,
    required String consumerSession,
    required int throughPosition,
  }) async {
    _validateConsumer(consumerSession);
    if (throughPosition < 0) {
      throw _validation('through_position 不能为负');
    }
    final String account = selfAccount;
    final int consumed = await ledger.consumedThrough(account, peerAccount);
    if (throughPosition <= consumed) {
      return consumed;
    }
    final List<PresentationReceipt> receipts = await ledger.receiptsForPeer(
      account: account,
      consumerSession: consumerSession,
      peerAccount: peerAccount,
    );
    final Map<int, bool> confirmedByPosition = <int, bool>{
      for (final PresentationReceipt receipt in receipts)
        receipt.position: receipt.confirmed,
    };
    final List<int> gaps = <int>[
      for (int position = consumed + 1; position <= throughPosition; position++)
        if (confirmedByPosition[position] != true) position,
    ];
    if (gaps.isNotEmpty) {
      throw AuthFailure(
        status: 409,
        code: 'consumption_gap',
        message: '消费水位存在未确认展示的位置',
        fields: <AuthFieldError>[
          AuthFieldError(
            field: 'through_position',
            code: 'gap',
            message: '缺少展示确认的位置：${_summarize(gaps)}',
          ),
        ],
      );
    }
    await ledger.setConsumedThrough(account, peerAccount, throughPosition);
    return throughPosition;
  }

  // ----------------------------------------------------------------- media --

  Future<Uint8List> mediaBytes(String mediaId) async {
    final Uint8List? cached = _mediaCache[mediaId];
    if (cached != null) {
      return cached;
    }
    final MediaResponse media = await api.fetchMedia(
      token: _token,
      mediaId: mediaId,
    );
    if (media.bytes.length <= _maxCachedMediaBytes) {
      _mediaCache[mediaId] = media.bytes;
      _mediaCacheOrder.add(mediaId);
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
  }) {
    return eventFeed.subscribe(
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
