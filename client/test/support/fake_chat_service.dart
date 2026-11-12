import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  final List<String> mediaBytesCalls = <String>[];
  final List<String> openMediaStreamCalls = <String>[];
  FakeMediaStreamHandle? lastStreamHandle;
  final List<OutgoingPart> lastSentBody = <OutgoingPart>[];
  final List<OutgoingAttachment> lastSentAttachments = <OutgoingAttachment>[];
  final int? pageSize;
  final int? gateAtPosition;
  final Completer<void>? gate;
  int _seq = 100;

  @override
  String get selfAccount => self.account;

  @override
  Future<UserPage> listUsers({String afterAccount = '', int limit = 50}) async {
    return UserPage(
      items: users
          .where((ChatUser user) => user.account != self.account)
          .toList(),
    );
  }

  @override
  Future<MessagePage> loadConversation({
    required String peerAccount,
    int afterPosition = 0,
    int limit = 50,
  }) async {
    final List<ChatMessage> all =
        List<ChatMessage>.from(conversations[peerAccount] ?? <ChatMessage>[])
          ..sort((ChatMessage a, ChatMessage b) {
            return a.position.compareTo(b.position);
          });
    conversationCalls.add(afterPosition);
    final List<ChatMessage> remaining = all
        .where((ChatMessage message) => message.position > afterPosition)
        .toList();
    final int effectiveLimit = pageSize != null && pageSize! < limit
        ? pageSize!
        : limit;
    final List<ChatMessage> page = remaining.take(effectiveLimit).toList();
    if (gate != null && gateAtPosition == afterPosition) {
      await gate!.future;
    }
    return MessagePage(
      items: page,
      nextPosition: page.isEmpty ? afterPosition : page.last.position,
      hasMore: remaining.length > page.length,
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
    if (body.isNotEmpty) {
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
        );
        bodyOutcome = SendOutcome(
          operationId: '$seed-b',
          message: message,
          part: body,
        );
      }
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
    );
    list.add(message);
    return message;
  }

  @override
  Future<Uint8List> mediaBytes(String mediaId) async {
    mediaBytesCalls.add(mediaId);
    return mediaId.contains('2') ? greenBytes : pngBytes;
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
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
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
