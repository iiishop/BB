import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_client/config/media_policy.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/chat_api_client.dart';
import 'package:bb_client/services/chat_ledger.dart';
import 'package:bb_client/services/chat_service.dart';
import 'package:bb_client/services/client_identity.dart';
import 'package:bb_client/services/download_manager.dart';
import 'package:bb_client/services/media_stream_proxy.dart';

/// In-memory ChatService double for Flutter widget tests.
///
/// It never opens a socket. The local control API and real REST chain have
/// their own tests; this exists so screen behaviour is deterministic under the
/// widget-test fake clock.
class FakeChatService extends ChatService {
  FakeChatService({
    required this.self,
    required List<ChatUser> users,
    Map<String, List<ChatMessage>>? conversations,
    Uint8List? png,
    this.pageSize,
    this.userPageSize,
    this.gateAtPosition,
    this.gate,
  }) : users = List<ChatUser>.from(users),
       conversations = conversations ?? <String, List<ChatMessage>>{},
       pngBytes = png ?? base64Decode(_pngBase64),
       super(
         api: ChatApiClient(baseUri: Uri.parse('http://127.0.0.1:1')),
         session: AuthSession()
           ..establish(
             token: 'widget-token',
             user: AuthUser(account: self.account, username: self.username),
           ),
         ledger: ChatLedger.inMemory(),
         cacheRoot: Directory.systemTemp,
         webSocketHints: false,
       ) {
    downloads = FakeDownloads(
      api: api,
      session: session,
      ledger: ledger,
      cacheRoot: Directory.systemTemp,
      onEvent: (LocalEvent _) async {},
    );
  }

  final AuthUser self;
  final List<ChatUser> users;
  final Map<String, List<ChatMessage>> conversations;
  final Uint8List pngBytes;
  final Uint8List greenBytes = base64Decode(_greenPngBase64);
  final List<String> savedPaths = <String>[];
  final List<String> sentTexts = <String>[];
  final List<int> conversationCalls = <int>[];

  /// Boundary of each backward (`before_position`) fetch, null for forward.
  final List<int?> beforeCalls = <int?>[];
  final List<String> mediaBytesCalls = <String>[];
  final List<String> sendSeeds = <String>[];
  final List<String> bodyOperationIds = <String>[];
  int sendCalls = 0;

  /// Blocks [sendComposed] until completed, so tests can observe the local
  /// "sending" bubble before the server commits.
  Completer<void>? sendGate;

  /// Blocks the response after the body was appended, while attachments are
  /// still being handled: the partial-success window.
  Completer<void>? attachmentGate;

  /// Blocks the response after every item was appended (server accepted) but
  /// before the caller sees the result.
  Completer<void>? responseGate;

  /// Per-operation response gates for out-of-order return tests.
  bool holdResponses = false;
  final Map<String, Completer<void>> _responseGates =
      <String, Completer<void>>{};

  /// Answer for the authoritative operation lookup used when a send failed.
  OperationResult? operationResult;
  final List<String> operationQueries = <String>[];

  Completer<void> responseGateFor(String seed) {
    return _responseGates.putIfAbsent(seed, () => Completer<void>());
  }

  /// Thrown from [sendComposed] after [sendGate] completes.
  Object? sendFailure;

  /// Returns a failed body outcome instead of committing it.
  bool failBody = false;

  /// Fails the retry path in [sendBody].
  bool failBodyRetry = false;

  final List<String> previewCalls = <String>[];
  final List<bool> previewThumbnailFlags = <bool>[];
  final List<String> listPreviewCalls = <String>[];
  final List<String> metadataCalls = <String>[];
  final List<String> originalCalls = <String>[];
  final List<int> originalProgress = <int>[];

  bool previewFails = false;
  bool metadataFails = false;
  bool listPreviewFails = false;
  Object? originalFailure;
  Completer<void>? originalGate;
  Uint8List? originalBytes;
  Attachment metadata = const Attachment(
    mediaId: 'metadata',
    kind: AttachmentKind.image,
    filename: 'probe.jpg',
    mimeType: 'image/jpeg',
    byteSize: 40 * 1024,
  );

  final List<String> openMediaStreamCalls = <String>[];
  FakeMediaStreamHandle? lastStreamHandle;
  final List<OutgoingPart> lastSentBody = <OutgoingPart>[];
  final List<OutgoingAttachment> lastSentAttachments = <OutgoingAttachment>[];
  final int? pageSize;

  /// Test-only directory page cap so two-page list paths stay cheap.
  final int? userPageSize;

  /// Mutable so a test can hold a poll that starts after the initial load.
  int? gateAtPosition;
  Completer<void>? gate;
  int _seq = 100;

  /// Reply gate for a presence refresh. Tests open the page first, then gate so
  /// the initial list load is not held up.
  Completer<void>? listUsersGate;

  /// Makes the next list/presence reads fail like an unreachable server.
  bool listUsersFails = false;

  /// Every `GET /users` this double served, in call order.
  final List<({String afterAccount, int limit})> listUsersCalls =
      <({String afterAccount, int limit})>[];

  @override
  String get selfAccount => self.account;

  @override
  Future<UserPage> listUsers({
    String afterAccount = '',
    int limit = 50,
    ExpectedIdentity? expectedIdentity,
  }) async {
    listUsersCalls.add((afterAccount: afterAccount, limit: limit));
    final Completer<void>? waiting = listUsersGate;
    if (waiting != null) {
      await waiting.future;
    }
    if (listUsersFails) {
      throw const AuthFailure(
        status: 502,
        code: 'upstream_unavailable',
        message: 'presence unavailable',
      );
    }
    final List<ChatUser> accounts =
        users
            .where((ChatUser user) => user.account != self.account)
            .where(
              (ChatUser user) =>
                  afterAccount.isEmpty ||
                  user.account.compareTo(afterAccount) > 0,
            )
            .toList()
          ..sort((ChatUser a, ChatUser b) => a.account.compareTo(b.account));
    final int cap = userPageSize != null && userPageSize! < limit
        ? userPageSize!
        : limit;
    final int take = cap.clamp(1, 100);
    final List<ChatUser> page = accounts.take(take).toList();
    return UserPage(
      items: page,
      nextCursor: accounts.length > page.length ? page.last.account : null,
    );
  }

  /// Inbound message ids this double has already shown to the reader.
  ///
  /// Widget tests construct this double in `setUp`, outside the fake-async
  /// zone, so chaining the real ledger's serial queue there would never be
  /// flushed by `pump`. Modelling the display fact in plain memory keeps the
  /// widget behaviour under test (badge count and clearing) and leaves ledger
  /// durability to the service tests.
  final Set<String> viewedMessageIds = <String>{};

  /// Same rule as the real service: inbound messages minus display facts.
  @override
  Future<Map<String, int>> incomingUnreadByPeer({int limit = 100}) async {
    return <String, int>{
      for (final MapEntry<String, List<ChatMessage>> entry
          in conversations.entries)
        entry.key: entry.value
            .where(
              (ChatMessage message) =>
                  message.targetAccount == self.account &&
                  !viewedMessageIds.contains(message.id),
            )
            .length,
    };
  }

  /// Records inbound message ids as viewed, mirroring the service's entry
  /// rule: an opened conversation clears every seeded inbound message.
  @override
  Future<int> markConversationViewed(String peerAccount) {
    return recordDisplayedIncoming(
      peerAccount: peerAccount,
      messages: conversations[peerAccount] ?? const <ChatMessage>[],
    );
  }

  @override
  Future<int> recordDisplayedIncoming({
    required String peerAccount,
    required Iterable<ChatMessage> messages,
  }) async {
    int recorded = 0;
    for (final ChatMessage message in messages) {
      if (message.targetAccount == self.account &&
          viewedMessageIds.add(message.id)) {
        recorded += 1;
      }
    }
    return recorded;
  }

  @override
  Future<MessagePage> loadConversation({
    required String peerAccount,
    int? afterPosition,
    int? beforePosition,
    int limit = 50,
  }) async {
    final List<ChatMessage> all =
        List<ChatMessage>.from(conversations[peerAccount] ?? <ChatMessage>[])
          ..sort((ChatMessage a, ChatMessage b) {
            return a.position.compareTo(b.position);
          });
    conversationCalls.add(afterPosition ?? 0);
    beforeCalls.add(beforePosition);
    final int effectiveLimit = pageSize != null && pageSize! < limit
        ? pageSize!
        : limit;
    final bool backward = beforePosition != null;
    final List<ChatMessage> candidates = backward
        ? all
              .where((ChatMessage message) => message.position < beforePosition)
              .toList()
        : all
              .where(
                (ChatMessage message) =>
                    message.position > (afterPosition ?? 0),
              )
              .toList();
    // Backward pages keep the newest slice of everything before the boundary.
    final int start = candidates.length > effectiveLimit
        ? candidates.length - effectiveLimit
        : 0;
    final List<ChatMessage> page = backward
        ? candidates.sublist(start)
        : candidates.take(effectiveLimit).toList();
    if (gate != null && gateAtPosition == (afterPosition ?? 0)) {
      await gate!.future;
    }
    return MessagePage(
      items: page,
      nextPosition: page.isEmpty
          ? (backward ? beforePosition : (afterPosition ?? 0))
          : (backward ? page.first.position : page.last.position),
      hasMore: candidates.length > page.length,
    );
  }

  @override
  Future<ComposedSendResult> sendComposed({
    required String targetAccount,
    required List<OutgoingPart> body,
    required List<OutgoingAttachment> attachments,
    String? operationSeed,
  }) async {
    final String seed = operationSeed ?? 'fake-${++_seq}';
    sendCalls += 1;
    sendSeeds.add(seed);
    final Completer<void>? gate = sendGate;
    if (gate != null) {
      await gate.future;
    }
    final Object? failure = sendFailure;
    if (failure != null) {
      throw failure;
    }
    lastSentBody
      ..clear()
      ..addAll(body);
    lastSentAttachments
      ..clear()
      ..addAll(attachments);
    final List<ChatMessage> target = conversations.putIfAbsent(
      targetAccount,
      () => <ChatMessage>[],
    );
    SendOutcome? bodyOutcome;
    if (body.isNotEmpty && failBody) {
      bodyOutcome = SendOutcome(
        operationId: '$seed-b',
        failure: const AuthFailure(
          status: 503,
          code: 'storage_busy',
          message: '稍后重试',
        ),
        part: body,
      );
    } else if (body.isNotEmpty) {
      final List<MessagePart> parts = <MessagePart>[];
      for (final OutgoingPart part in body) {
        if (part is OutgoingText) {
          parts.add(TextPart(part.text));
          sentTexts.add(part.text);
        } else if (part is OutgoingImage) {
          parts.add(ImagePart('fake-image-${++_seq}'));
        }
      }
      if (parts.isNotEmpty) {
        final ChatMessage message = _append(
          target,
          targetAccount,
          ChatMessageKind.body,
          parts: parts,
          operationId: '$seed-b',
        );
        bodyOutcome = SendOutcome(
          operationId: '$seed-b',
          message: message,
          part: body,
        );
      }
    }
    final Completer<void>? attachmentGate = this.attachmentGate;
    if (attachmentGate != null) {
      await attachmentGate.future;
    }
    final List<SendOutcome> outcomes = <SendOutcome>[];
    for (int i = 0; i < attachments.length; i++) {
      final OutgoingAttachment attachment = attachments[i];
      final String mime;
      final String filename;
      if (attachment.source.path != null) {
        filename =
            attachment.source.filename ??
            attachment.source.path!.split(Platform.pathSeparator).last;
        mime = attachment.source.mimeType ?? 'application/octet-stream';
      } else {
        filename = attachment.source.filename ?? 'attachment';
        mime = attachment.source.mimeType ?? 'application/octet-stream';
      }
      final ChatMessage message = _append(
        target,
        targetAccount,
        ChatMessageKind.attachment,
        operationId: '$seed-a$i',
        attachment: Attachment(
          mediaId: 'fake-media-${++_seq}',
          kind: mime.startsWith('video/')
              ? AttachmentKind.video
              : mime == 'application/pdf'
              ? AttachmentKind.document
              : AttachmentKind.other,
          filename: filename,
          mimeType: mime,
          byteSize: 1024,
          coverMediaId: attachment.cover == null ? null : 'fake-cover-$_seq',
        ),
      );
      outcomes.add(
        SendOutcome(
          operationId: '$seed-a$i',
          message: message,
          attachment: attachment,
        ),
      );
    }
    final Completer<void>? responseGate = this.responseGate;
    if (responseGate != null) {
      await responseGate.future;
    }
    if (holdResponses) {
      await responseGateFor(seed).future;
    }
    return ComposedSendResult(
      body: bodyOutcome,
      attachments: outcomes,
      operationSeed: seed,
    );
  }

  ChatMessage _append(
    List<ChatMessage> list,
    String target,
    ChatMessageKind kind, {
    List<MessagePart> parts = const <MessagePart>[],
    Attachment? attachment,
    String? operationId,
  }) {
    final ChatMessage message = ChatMessage(
      id: 'fake-${++_seq}',
      position: list.length + 1,
      senderAccount: self.account,
      targetAccount: target,
      createdAt: DateTime.now().toUtc(),
      kind: kind,
      parts: parts,
      attachment: attachment,
      operationId: operationId,
    );
    list.add(message);
    // Mirror the server fact `GET /users` derives its directory row from: a
    // committed message moves the pair's last contact time and preview. The
    // home list can then be asserted against the same DTO the real route
    // returns, without tests hand-editing their own sort input.
    final int index = users.indexWhere(
      (ChatUser user) => user.account == target,
    );
    if (index >= 0) {
      final ChatUser previous = users[index];
      users[index] = ChatUser(
        account: previous.account,
        username: previous.username,
        avatarUrl: previous.avatarUrl,
        avatarVersion: previous.avatarVersion,
        presence: previous.presence,
        lastContactAt: message.createdAt,
        lastMessage: UserPreview(
          id: message.id,
          senderAccount: self.account,
          senderUsername: self.username,
          previewBody: _previewBody(kind, parts, attachment),
        ),
      );
    }
    return message;
  }

  String _previewBody(
    ChatMessageKind kind,
    List<MessagePart> parts,
    Attachment? attachment,
  ) {
    if (kind == ChatMessageKind.body) {
      final String text = parts
          .map(
            (MessagePart part) => switch (part) {
              TextPart(:final String text) => text,
              ImagePart() => '[图片]',
            },
          )
          .join();
      return text.isEmpty ? '[消息]' : text;
    }
    return attachment == null ? '[附件]' : '[文件]${attachment.filename}';
  }

  @override
  Future<OperationResult?> getOperation(String operationId) async {
    operationQueries.add(operationId);
    return operationResult;
  }

  @override
  Future<SendOutcome> sendBody({
    required String targetAccount,
    required List<OutgoingPart> content,
    String? operationId,
    ExpectedIdentity? expectedIdentity,
  }) async {
    bodyOperationIds.add(operationId ?? '');
    if (failBodyRetry) {
      return SendOutcome(
        operationId: operationId ?? 'retry',
        failure: const AuthFailure(
          status: 503,
          code: 'storage_busy',
          message: '稍后重试',
        ),
        part: content,
      );
    }
    final List<MessagePart> parts = <MessagePart>[
      for (final OutgoingPart part in content)
        if (part is OutgoingText)
          TextPart(part.text)
        else if (part is OutgoingImage)
          ImagePart('fake-image-${++_seq}'),
    ];
    final List<ChatMessage> target = conversations.putIfAbsent(
      targetAccount,
      () => <ChatMessage>[],
    );
    final ChatMessage message = _append(
      target,
      targetAccount,
      ChatMessageKind.body,
      parts: parts,
      operationId: operationId,
    );
    return SendOutcome(
      operationId: operationId ?? 'retry',
      message: message,
      part: content,
    );
  }

  @override
  Future<Uint8List> mediaBytes(String mediaId) async {
    mediaBytesCalls.add(mediaId);
    return mediaId.contains('2') ? greenBytes : pngBytes;
  }

  @override
  Future<MediaPreview> loadMediaPreview(
    String mediaId, {
    bool thumbnail = false,
  }) async {
    previewCalls.add(mediaId);
    previewThumbnailFlags.add(thumbnail);
    if (previewFails) {
      throw StateError('preview failed');
    }
    return MediaPreview(
      bytes: mediaId.contains('2') ? greenBytes : pngBytes,
      isDerivative: thumbnail,
    );
  }

  @override
  Future<Attachment> loadMediaMetadata(String mediaId) async {
    metadataCalls.add(mediaId);
    if (metadataFails) {
      throw const AuthFailure(
        status: 503,
        code: 'metadata_unavailable',
        message: '元信息暂不可用',
      );
    }
    return metadata;
  }

  @override
  Future<Uint8List> loadListPreview(String mediaId) async {
    listPreviewCalls.add(mediaId);
    if (listPreviewFails) {
      throw const AuthFailure(
        status: 503,
        code: 'thumbnail_unavailable',
        message: '缩略图暂不可用',
      );
    }
    final Attachment info = await loadMediaMetadata(mediaId);
    if (mediaNeedsExplicitOriginal(info.byteSize)) {
      return (await loadMediaPreview(mediaId, thumbnail: true)).bytes;
    }
    return mediaBytes(mediaId);
  }

  @override
  Future<MediaResponse> fetchOriginalMedia(
    String mediaId, {
    void Function(int received, int? total)? onProgress,
  }) async {
    originalCalls.add(mediaId);
    final Completer<void>? gate = originalGate;
    if (gate != null) {
      await gate.future;
    }
    final Object? failure = originalFailure;
    if (failure != null) {
      throw failure;
    }
    final Uint8List bytes = originalBytes ?? greenBytes;
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    originalProgress.add(bytes.length ~/ 2);
    onProgress?.call(bytes.length, bytes.length);
    originalProgress.add(bytes.length);
    return MediaResponse(
      status: 200,
      bytes: bytes,
      mimeType: 'image/jpeg',
      filename: 'original.jpg',
      byteSize: bytes.length,
    );
  }

  @override
  Future<MediaStreamHandle> openMediaStream(String mediaId) async {
    openMediaStreamCalls.add(mediaId);
    final FakeMediaStreamHandle handle = FakeMediaStreamHandle(
      uri: Uri.parse('http://127.0.0.1:1/stream/$mediaId'),
    );
    lastStreamHandle = handle;
    return handle;
  }

  @override
  Future<String> saveAs({
    required String mediaId,
    required String targetPath,
  }) async {
    savedPaths.add(targetPath);
    return targetPath;
  }
}

class FakeMediaStreamHandle implements MediaStreamHandle {
  FakeMediaStreamHandle({required this.uri});

  @override
  final Uri uri;

  final StreamController<MediaStreamProgress> _progress =
      StreamController<MediaStreamProgress>.broadcast();

  @override
  Stream<MediaStreamProgress> get progress => _progress.stream;

  bool closed = false;

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    await _progress.close();
  }
}

class FakeDownloads extends DownloadManager {
  FakeDownloads({
    required super.api,
    required super.session,
    required super.ledger,
    required super.cacheRoot,
    required super.onEvent,
  });

  final Map<String, DownloadTask> tasks = <String, DownloadTask>{};
  final List<String> starts = <String>[];

  @override
  Future<DownloadTask> start({
    required String operationId,
    required String consumerSession,
    required String mediaId,
    String? directory,
    ExpectedIdentity? expectedIdentity,
  }) async {
    starts.add(mediaId);
    for (final DownloadTask prior in tasks.values) {
      if (prior.operationId == operationId) {
        return prior;
      }
    }
    final DownloadTask task = DownloadTask(
      taskId: 'fake-task-${tasks.length + 1}',
      operationId: operationId,
      consumerSession: consumerSession,
      status: DownloadStatus.succeeded,
      plannedPath: '/tmp/$mediaId',
      actualPath: '/tmp/$mediaId',
      mediaId: mediaId,
      kind: AttachmentKind.document,
      filename: 'fake.bin',
    );
    tasks[task.taskId] = task;
    return task;
  }

  @override
  Future<DownloadTask?> get({
    required String taskId,
    required String consumerSession,
  }) async {
    return tasks[taskId];
  }

  @override
  Future<String> saveAsCopy({
    required String mediaId,
    required String targetPath,
  }) async {
    return targetPath;
  }
}

const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQoAHxcCAk+Uzr4AAAAASUVORK5CYII=';
const String _greenPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGNk+M/wn4GBgYGJAQoAHhgCAu/QjeYAAAAASUVORK5CYII=';
