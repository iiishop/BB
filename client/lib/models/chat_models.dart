/// Shared pure-Dart chat models for STEP-3.
///
/// These mirror `server/contract/chat-local-schema.json` (R2) plus the R3
/// presentation/event additions. The client never invents server fields: every
/// parser rejects malformed payloads with a [FormatException] that the service
/// layer maps to `upstream_unavailable`.
library;

/// Who may read a message pair. Accounts are the eight-digit social identity.
const int chatMaxMessageBytes = 64 * 1024;

/// Server-side cap for one uploaded file.
const int chatMaxUploadBytes = 32 * 1024 * 1024;

/// Local event schema version for the durable client feed.
const int localEventVersion = 1;

enum ChatMessageKind {
  body,
  attachment;

  static ChatMessageKind? tryParse(Object? value) {
    return switch (value) {
      'body' => ChatMessageKind.body,
      'attachment' => ChatMessageKind.attachment,
      _ => null,
    };
  }

  String get wire => name;
}

enum AttachmentKind {
  image,
  video,
  audio,
  document,
  other;

  static AttachmentKind? tryParse(Object? value) {
    return switch (value) {
      'image' => AttachmentKind.image,
      'video' => AttachmentKind.video,
      'audio' => AttachmentKind.audio,
      'document' => AttachmentKind.document,
      'other' => AttachmentKind.other,
      _ => null,
    };
  }

  String get wire => name;

  /// Cache subdirectory and download classification.
  String get cacheDirectory => switch (this) {
    AttachmentKind.image => 'images',
    AttachmentKind.video => 'videos',
    AttachmentKind.audio => 'audio',
    AttachmentKind.document => 'documents',
    AttachmentKind.other => 'other',
  };

  /// Short list-preview placeholder from the contract.
  String get previewLabel => switch (this) {
    AttachmentKind.image => '[图片]',
    AttachmentKind.video => '[视频]',
    AttachmentKind.audio => '[音频]',
    AttachmentKind.image ||
    AttachmentKind.document ||
    AttachmentKind.other => '[文件]',
  };
}

enum Presence {
  online,
  offline;

  static Presence tryParse(Object? value) {
    return value == 'online' ? Presence.online : Presence.offline;
  }

  String get wire => name;
}

/// One ordered body segment. STEP-3 keeps text and image positions intact.
sealed class MessagePart {
  const MessagePart();

  Map<String, dynamic> toJson();

  /// Deterministic identity used by presentation receipts.
  String get digestKey;

  static MessagePart? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    return switch (json['type']) {
      'text' =>
        json['text'] is String ? TextPart(json['text'] as String) : null,
      'image' =>
        json['media_id'] is String
            ? ImagePart(json['media_id'] as String)
            : null,
      _ => null,
    };
  }

  static String digestOf(Iterable<MessagePart> parts) =>
      parts.map((MessagePart part) => part.digestKey).join('\u0001');
}

class TextPart extends MessagePart {
  const TextPart(this.text);

  final String text;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'text',
    'text': text,
  };

  @override
  String get digestKey => 'text:$text';
}

class ImagePart extends MessagePart {
  const ImagePart(this.mediaId);

  final String mediaId;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'image',
    'media_id': mediaId,
  };

  @override
  String get digestKey => 'image:$mediaId';
}

/// Metadata for an independent attachment message.
class Attachment {
  const Attachment({
    required this.mediaId,
    required this.kind,
    required this.filename,
    required this.mimeType,
    required this.byteSize,
    this.coverMediaId,
  });

  final String mediaId;
  final AttachmentKind kind;
  final String filename;
  final String mimeType;
  final int byteSize;
  final String? coverMediaId;

  factory Attachment.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('attachment must be an object');
    }
    final AttachmentKind? kind = AttachmentKind.tryParse(json['media_type']);
    final Object? mediaId = json['media_id'];
    final Object? filename = json['filename'];
    final Object? mime = json['mime_type'];
    final Object? size = json['byte_size'];
    final Object? cover = json['cover_media_id'];
    if (kind == null ||
        mediaId is! String ||
        filename is! String ||
        mime is! String ||
        size is! int) {
      throw const FormatException('attachment has invalid fields');
    }
    return Attachment(
      mediaId: mediaId,
      kind: kind,
      filename: filename,
      mimeType: mime,
      byteSize: size,
      coverMediaId: cover is String ? cover : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'media_id': mediaId,
    'media_type': kind.wire,
    'filename': filename,
    'mime_type': mimeType,
    'byte_size': byteSize,
    'cover_media_id': coverMediaId,
  };
}

/// A committed server message.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.position,
    required this.senderAccount,
    required this.targetAccount,
    required this.createdAt,
    required this.kind,
    this.parts = const <MessagePart>[],
    this.attachment,
  });

  final String id;
  final int position;
  final String senderAccount;
  final String targetAccount;
  final DateTime createdAt;
  final ChatMessageKind kind;
  final List<MessagePart> parts;
  final Attachment? attachment;

  bool isMine(String selfAccount) => senderAccount == selfAccount;

  bool isAttachmentKind(AttachmentKind kind) =>
      this.kind == ChatMessageKind.attachment && attachment?.kind == kind;

  factory ChatMessage.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('message must be an object');
    }
    final Object? id = json['id'];
    final Object? position = json['position'];
    final Object? sender = json['sender_account'];
    final Object? target = json['target_account'];
    final Object? createdAt = json['created_at'];
    final ChatMessageKind? kind = ChatMessageKind.tryParse(json['kind']);
    if (id is! String ||
        position is! int ||
        sender is! String ||
        target is! String ||
        createdAt is! String ||
        kind == null) {
      throw const FormatException('message has invalid fields');
    }
    final DateTime timestamp = DateTime.tryParse(createdAt) != null
        ? DateTime.parse(createdAt).toUtc()
        : throw const FormatException('invalid created_at');
    final List<MessagePart> parts = <MessagePart>[];
    final Object? rawContent = json['content'];
    if (rawContent != null) {
      if (rawContent is! List) {
        throw const FormatException('content must be a list');
      }
      for (final Object? raw in rawContent) {
        final MessagePart? part = MessagePart.fromJson(raw);
        if (part == null) {
          throw const FormatException('invalid content part');
        }
        if (part is TextPart && part.text.isEmpty) {
          throw const FormatException('empty text part');
        }
        parts.add(part);
      }
    }
    final Attachment? attachment = json['attachment'] == null
        ? null
        : Attachment.fromJson(json['attachment']);
    if (kind == ChatMessageKind.body && parts.isEmpty) {
      throw const FormatException('body message without content');
    }
    if (kind == ChatMessageKind.attachment && attachment == null) {
      throw const FormatException('attachment message without attachment');
    }
    return ChatMessage(
      id: id,
      position: position,
      senderAccount: sender,
      targetAccount: target,
      createdAt: timestamp,
      kind: kind,
      parts: List<MessagePart>.unmodifiable(parts),
      attachment: attachment,
    );
  }

  /// Identity used by the client to deduplicate list results and events.
  String get identity => '$id@$position';
}

/// Preview embedded in the registered-user list.
class UserPreview {
  const UserPreview({
    required this.id,
    required this.senderAccount,
    required this.senderUsername,
    required this.previewBody,
  });

  final String id;
  final String senderAccount;
  final String senderUsername;
  final String previewBody;

  factory UserPreview.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('preview must be an object');
    }
    final Object? id = json['id'];
    final Object? sender = json['sender_account'];
    final Object? name = json['sender_username'];
    final Object? body = json['preview_body'];
    if (id is! String ||
        sender is! String ||
        name is! String ||
        body is! String) {
      throw const FormatException('preview has invalid fields');
    }
    return UserPreview(
      id: id,
      senderAccount: sender,
      senderUsername: name,
      previewBody: body,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'sender_account': senderAccount,
    'sender_username': senderUsername,
    'preview_body': previewBody,
  };
}

/// One registered user shown on the default home page.
class ChatUser {
  const ChatUser({
    required this.account,
    required this.username,
    required this.avatarUrl,
    required this.avatarVersion,
    required this.presence,
    this.lastContactAt,
    this.lastMessage,
  });

  final String account;
  final String username;
  final String avatarUrl;
  final String avatarVersion;
  final Presence presence;
  final DateTime? lastContactAt;
  final UserPreview? lastMessage;

  factory ChatUser.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('user must be an object');
    }
    final Object? account = json['account'];
    final Object? username = json['username'];
    final Object? avatarUrl = json['avatar_url'];
    final Object? avatarVersion = json['avatar_version'];
    if (account is! String ||
        username is! String ||
        avatarUrl is! String ||
        avatarVersion is! String) {
      throw const FormatException('user has invalid fields');
    }
    final Object? contact = json['last_contact_at'];
    final DateTime? lastContactAt = contact is String
        ? DateTime.tryParse(contact)?.toUtc()
        : null;
    return ChatUser(
      account: account,
      username: username,
      avatarUrl: avatarUrl,
      avatarVersion: avatarVersion,
      presence: Presence.tryParse(json['presence']),
      lastContactAt: lastContactAt,
      lastMessage: json['last_message'] == null
          ? null
          : UserPreview.fromJson(json['last_message']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
    'avatar_url': avatarUrl,
    'avatar_version': avatarVersion,
    'presence': presence.wire,
    'last_contact_at': lastContactAt?.toIso8601String(),
    'last_message': lastMessage?.toJson(),
  };
}

/// Keyset page of registered users.
class UserPage {
  const UserPage({required this.items, this.nextCursor});

  final List<ChatUser> items;
  final String? nextCursor;

  factory UserPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['items'] is! List) {
      throw const FormatException('user page must be an object');
    }
    final Object? cursor = json['next_cursor'];
    return UserPage(
      items: List<ChatUser>.unmodifiable(
        (json['items'] as List).map(ChatUser.fromJson),
      ),
      nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((ChatUser user) => user.toJson()).toList(),
    'next_cursor': nextCursor,
  };
}

/// Ascending page of a pair's messages.
class MessagePage {
  const MessagePage({
    required this.items,
    required this.nextPosition,
    required this.hasMore,
  });

  final List<ChatMessage> items;
  final int nextPosition;
  final bool hasMore;

  factory MessagePage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        json['next_position'] is! int ||
        json['has_more'] is! bool) {
      throw const FormatException('message page must be an object');
    }
    return MessagePage(
      items: List<ChatMessage>.unmodifiable(
        (json['items'] as List).map(ChatMessage.fromJson),
      ),
      nextPosition: json['next_position'] as int,
      hasMore: json['has_more'] as bool,
    );
  }
}

enum OperationStatus {
  pending,
  uncertain,
  succeeded,
  failed;

  static OperationStatus tryParse(Object? value) {
    return switch (value) {
      'pending' => OperationStatus.pending,
      'uncertain' => OperationStatus.uncertain,
      'succeeded' => OperationStatus.succeeded,
      'failed' => OperationStatus.failed,
      _ => OperationStatus.pending,
    };
  }

  String get wire => name;
}

/// Result of an idempotent client operation (`GET /operations/{id}`).
class OperationResult {
  const OperationResult({
    required this.operationId,
    required this.kind,
    required this.status,
    this.message,
    this.taskId,
    this.errorCode,
  });

  final String operationId;
  final String kind;
  final OperationStatus status;
  final ChatMessage? message;
  final String? taskId;
  final String? errorCode;

  factory OperationResult.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('operation must be an object');
    }
    final Object? id = json['operation_id'];
    final Object? kind = json['kind'];
    if (id is! String || kind is! String) {
      throw const FormatException('operation has invalid fields');
    }
    return OperationResult(
      operationId: id,
      kind: kind,
      status: OperationStatus.tryParse(json['status']),
      message: json['message'] == null
          ? null
          : ChatMessage.fromJson(json['message']),
      taskId: json['task_id'] is String ? json['task_id'] as String : null,
      errorCode: json['error_code'] is String
          ? json['error_code'] as String
          : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'operation_id': operationId,
    'kind': kind,
    'status': status.wire,
    'message': message == null ? null : messageToJson(message!),
    'task_id': taskId,
    'error_code': errorCode,
  };
}

enum DownloadStatus {
  pending,
  running,
  uncertain,
  succeeded,
  failed;

  static DownloadStatus tryParse(Object? value) {
    return switch (value) {
      'running' => DownloadStatus.running,
      'uncertain' => DownloadStatus.uncertain,
      'succeeded' => DownloadStatus.succeeded,
      'failed' => DownloadStatus.failed,
      _ => DownloadStatus.pending,
    };
  }

  String get wire => name;

  bool get terminal => this == succeeded || this == failed;
}

/// Async attachment download task owned by the client.
class DownloadTask {
  const DownloadTask({
    required this.taskId,
    required this.operationId,
    required this.consumerSession,
    required this.status,
    required this.plannedPath,
    this.actualPath,
    this.errorCode,
    this.mediaId,
    this.kind,
    this.filename,
    this.originIdentity,
  });

  final String taskId;
  final String operationId;
  final String consumerSession;
  final DownloadStatus status;
  final String plannedPath;
  final String? actualPath;
  final String? errorCode;
  final String? mediaId;
  final AttachmentKind? kind;
  final String? filename;

  /// ExpectedIdentity JSON snapshot of the identity that started the download.
  /// v2 callbacks must never be rewritten to a newer binding.
  final Map<String, dynamic>? originIdentity;

  DownloadTask copyWith({
    DownloadStatus? status,
    String? plannedPath,
    String? actualPath,
    String? errorCode,
  }) {
    return DownloadTask(
      taskId: taskId,
      operationId: operationId,
      consumerSession: consumerSession,
      status: status ?? this.status,
      plannedPath: plannedPath ?? this.plannedPath,
      actualPath: actualPath ?? this.actualPath,
      errorCode: errorCode ?? this.errorCode,
      mediaId: mediaId,
      kind: kind,
      filename: filename,
      originIdentity: originIdentity,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'task_id': taskId,
    'operation_id': operationId,
    'consumer_session': consumerSession,
    'status': status.wire,
    'planned_path': plannedPath,
    'actual_path': actualPath,
    'error_code': errorCode,
    'media_id': mediaId,
    'media_type': kind?.wire,
    'filename': filename,
    'origin_identity': originIdentity,
  };

  factory DownloadTask.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('download must be an object');
    }
    final Object? taskId = json['task_id'];
    final Object? operationId = json['operation_id'];
    final Object? consumer = json['consumer_session'];
    final Object? planned = json['planned_path'];
    if (taskId is! String ||
        operationId is! String ||
        consumer is! String ||
        planned is! String) {
      throw const FormatException('download has invalid fields');
    }
    return DownloadTask(
      taskId: taskId,
      operationId: operationId,
      consumerSession: consumer,
      status: DownloadStatus.tryParse(json['status']),
      plannedPath: planned,
      actualPath: json['actual_path'] is String
          ? json['actual_path'] as String
          : null,
      errorCode: json['error_code'] is String
          ? json['error_code'] as String
          : null,
      originIdentity: json['origin_identity'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(
              json['origin_identity'] as Map<String, dynamic>,
            )
          : null,
      mediaId: json['media_id'] is String ? json['media_id'] as String : null,
      kind: AttachmentKind.tryParse(json['media_type']),
      filename: json['filename'] is String ? json['filename'] as String : null,
    );
  }

  /// Wire shape returned by the local control API (no internal extras).
  Map<String, dynamic> toWire() => <String, dynamic>{
    'task_id': taskId,
    'operation_id': operationId,
    'consumer_session': consumerSession,
    'status': status.wire,
    'planned_path': plannedPath,
    'actual_path': actualPath,
    'error_code': errorCode,
  };
}

enum LocalEventType {
  messageAvailable,
  downloadSucceeded,
  downloadFailed;

  static LocalEventType? tryParse(Object? value) {
    return switch (value) {
      'message.available' => messageAvailable,
      'download.succeeded' => downloadSucceeded,
      'download.failed' => downloadFailed,
      _ => null,
    };
  }

  String get wire => switch (this) {
    messageAvailable => 'message.available',
    downloadSucceeded => 'download.succeeded',
    downloadFailed => 'download.failed',
  };
}

/// Durable client event handed to the DSH plugin.
class LocalEvent {
  const LocalEvent({
    required this.eventId,
    required this.account,
    required this.consumerSession,
    required this.type,
    this.peerAccount,
    this.position,
    this.messageId,
    this.taskId,
    this.operationId,
    this.actualPath,
    this.errorCode,
    this.originIdentity,
  });

  final String eventId;
  final String account;
  final String consumerSession;
  final LocalEventType type;

  /// ExpectedIdentity JSON snapshot of the binding that admitted the event.
  final Map<String, dynamic>? originIdentity;
  final String? peerAccount;
  final int? position;
  final String? messageId;
  final String? taskId;
  final String? operationId;
  final String? actualPath;
  final String? errorCode;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': localEventVersion,
    'event_id': eventId,
    'account': account,
    'consumer_session': consumerSession,
    'type': type.wire,
    if (peerAccount != null) 'peer_account': peerAccount,
    if (position != null) 'position': position,
    if (taskId != null) 'task_id': taskId,
    if (operationId != null) 'operation_id': operationId,
    if (actualPath != null) 'actual_path': actualPath,
    if (errorCode != null) 'error_code': errorCode,
    if (originIdentity != null) 'origin_identity': originIdentity,
  };

  factory LocalEvent.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('event must be an object');
    }
    final Object? eventId = json['event_id'];
    final Object? account = json['account'];
    final Object? consumer = json['consumer_session'];
    final LocalEventType? type = LocalEventType.tryParse(json['type']);
    if (eventId is! String ||
        account is! String ||
        consumer is! String ||
        type == null) {
      throw const FormatException('event has invalid fields');
    }
    return LocalEvent(
      eventId: eventId,
      account: account,
      consumerSession: consumer,
      type: type,
      peerAccount: json['peer_account'] is String
          ? json['peer_account'] as String
          : null,
      position: json['position'] is int ? json['position'] as int : null,
      messageId: json['message_id'] is String
          ? json['message_id'] as String
          : null,
      taskId: json['task_id'] is String ? json['task_id'] as String : null,
      operationId: json['operation_id'] is String
          ? json['operation_id'] as String
          : null,
      actualPath: json['actual_path'] is String
          ? json['actual_path'] as String
          : null,
      errorCode: json['error_code'] is String
          ? json['error_code'] as String
          : null,
      originIdentity: json['origin_identity'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(
              json['origin_identity'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

class LocalEventEntry {
  const LocalEventEntry({required this.cursor, required this.event});

  final int cursor;
  final LocalEvent event;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cursor': cursor,
    'event': event.toJson(),
  };

  factory LocalEventEntry.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['cursor'] is! int) {
      throw const FormatException('event entry has invalid fields');
    }
    return LocalEventEntry(
      cursor: json['cursor'] as int,
      event: LocalEvent.fromJson(json['event']),
    );
  }
}

class LocalEventPage {
  const LocalEventPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    this.reason,
  });

  final List<LocalEventEntry> items;
  final int nextCursor;
  final bool hasMore;
  final String? reason;

  factory LocalEventPage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        json['next_cursor'] is! int ||
        json['has_more'] is! bool) {
      throw const FormatException('event page has invalid fields');
    }
    return LocalEventPage(
      items: List<LocalEventEntry>.unmodifiable(
        (json['items'] as List).map(LocalEventEntry.fromJson),
      ),
      nextCursor: json['next_cursor'] as int,
      hasMore: json['has_more'] as bool,
      reason: json['reason'] is String ? json['reason'] as String : null,
    );
  }

  Map<String, dynamic> toWire() => <String, dynamic>{
    'items': items.map((LocalEventEntry entry) => entry.toJson()).toList(),
    'next_cursor': nextCursor,
    'has_more': hasMore,
    if (reason != null) 'reason': reason,
  };
}

/// Display evidence for one message read by the DSH consumer.
///
/// The plugin confirms a receipt only after the actual model request completed
/// with a successful response. Presence of the receipt in a read result is not
/// confirmation.
class PresentationReceipt {
  const PresentationReceipt({
    required this.receiptId,
    required this.account,
    required this.consumerSession,
    required this.peerAccount,
    required this.messageId,
    required this.position,
    required this.contentDigest,
    this.confirmed = false,
    this.attemptId,
    this.consumerId,
  });

  final String receiptId;
  final String account;
  final String consumerSession;

  /// Stable client consumer that owns this display fact. Null only for
  /// receipts written before the consumer-scoped ledger existed.
  final String? consumerId;
  final String peerAccount;
  final String messageId;
  final int position;
  final String contentDigest;
  final bool confirmed;
  final String? attemptId;

  PresentationReceipt copyWith({
    bool? confirmed,
    String? attemptId,
    String? consumerId,
  }) {
    return PresentationReceipt(
      receiptId: receiptId,
      account: account,
      consumerSession: consumerSession,
      consumerId: consumerId ?? this.consumerId,
      peerAccount: peerAccount,
      messageId: messageId,
      position: position,
      contentDigest: contentDigest,
      confirmed: confirmed ?? this.confirmed,
      attemptId: attemptId ?? this.attemptId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'receipt_id': receiptId,
    'account': account,
    'consumer_session': consumerSession,
    'consumer_id': consumerId,
    'peer_account': peerAccount,
    'message_id': messageId,
    'position': position,
    'content_digest': contentDigest,
    'confirmed': confirmed,
    'attempt_id': attemptId,
  };

  factory PresentationReceipt.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('receipt must be an object');
    }
    final Object? id = json['receipt_id'];
    final Object? account = json['account'];
    final Object? consumer = json['consumer_session'];
    final Object? peer = json['peer_account'];
    final Object? message = json['message_id'];
    final Object? position = json['position'];
    final Object? digest = json['content_digest'];
    if (id is! String ||
        account is! String ||
        consumer is! String ||
        peer is! String ||
        message is! String ||
        position is! int ||
        digest is! String) {
      throw const FormatException('receipt has invalid fields');
    }
    return PresentationReceipt(
      receiptId: id,
      account: account,
      consumerSession: consumer,
      consumerId: json['consumer_id'] is String
          ? json['consumer_id'] as String
          : null,
      peerAccount: peer,
      messageId: message,
      position: position,
      contentDigest: digest,
      confirmed: json['confirmed'] == true,
      attemptId: json['attempt_id'] is String
          ? json['attempt_id'] as String
          : null,
    );
  }

  /// Public half attached to a VisibleMessage.
  Map<String, dynamic> toPresentation() => <String, dynamic>{
    'receipt_id': receiptId,
    'content_digest': contentDigest,
  };
}

/// Ordered MCP block: real text or a real image payload.
sealed class VisibleBlock {
  const VisibleBlock();

  Map<String, dynamic> toJson();

  static VisibleBlock fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('block must be an object');
    }
    if (json['type'] == 'text' && json['text'] is String) {
      return VisibleTextBlock(json['text'] as String);
    }
    if (json['type'] == 'image' &&
        json['data'] is String &&
        json['mime_type'] is String) {
      return VisibleImageBlock(
        data: json['data'] as String,
        mimeType: json['mime_type'] as String,
      );
    }
    throw const FormatException('invalid block');
  }
}

class VisibleTextBlock extends VisibleBlock {
  const VisibleTextBlock(this.text);

  final String text;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'text',
    'text': text,
  };
}

class VisibleImageBlock extends VisibleBlock {
  const VisibleImageBlock({required this.data, required this.mimeType});

  final String data;
  final String mimeType;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': 'image',
    'data': data,
    'mime_type': mimeType,
  };
}

/// Message plus ordered blocks and display evidence.
class VisibleMessage {
  const VisibleMessage({
    required this.message,
    required this.blocks,
    this.presentation,
  });

  final ChatMessage message;
  final List<VisibleBlock> blocks;
  final PresentationReceipt? presentation;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'message': _messageToJson(message),
    'blocks': blocks.map((VisibleBlock block) => block.toJson()).toList(),
    if (presentation != null) 'presentation': presentation!.toPresentation(),
  };

  factory VisibleMessage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> || json['blocks'] is! List) {
      throw const FormatException('visible message must be an object');
    }
    return VisibleMessage(
      message: ChatMessage.fromJson(json['message']),
      blocks: List<VisibleBlock>.unmodifiable(
        (json['blocks'] as List).map(VisibleBlock.fromJson),
      ),
      presentation: json['presentation'] == null
          ? null
          : PresentationReceipt.fromJson(<String, dynamic>{
              ...(json['presentation'] as Map<String, dynamic>),
              'account':
                  (json['message'] as Map<String, dynamic>)['sender_account'],
              'consumer_session': '',
              'peer_account':
                  (json['message'] as Map<String, dynamic>)['target_account'],
              'message_id': (json['message'] as Map<String, dynamic>)['id'],
              'position': (json['message'] as Map<String, dynamic>)['position'],
              'confirmed': false,
            }),
    );
  }
}

Map<String, dynamic> messageToJson(ChatMessage message) =>
    _messageToJson(message);

Map<String, dynamic> _messageToJson(ChatMessage message) => <String, dynamic>{
  'id': message.id,
  'position': message.position,
  'sender_account': message.senderAccount,
  'target_account': message.targetAccount,
  'created_at': message.createdAt.toIso8601String(),
  'kind': message.kind.wire,
  if (message.kind == ChatMessageKind.body)
    'content': message.parts.map((MessagePart part) => part.toJson()).toList(),
  'attachment': message.attachment?.toJson(),
};

/// Read/wait result returned by the local control API.
class VisibleMessagePage {
  const VisibleMessagePage({
    required this.items,
    required this.nextPosition,
    required this.hasMore,
    this.reason,
  });

  final List<VisibleMessage> items;
  final int nextPosition;
  final bool hasMore;
  final String? reason;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'items': items.map((VisibleMessage message) => message.toJson()).toList(),
    'next_position': nextPosition,
    'has_more': hasMore,
    if (reason != null) 'reason': reason,
  };

  factory VisibleMessagePage.fromJson(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['items'] is! List ||
        json['next_position'] is! int ||
        json['has_more'] is! bool) {
      throw const FormatException('visible page has invalid fields');
    }
    return VisibleMessagePage(
      items: List<VisibleMessage>.unmodifiable(
        (json['items'] as List).map(VisibleMessage.fromJson),
      ),
      nextPosition: json['next_position'] as int,
      hasMore: json['has_more'] as bool,
      reason: json['reason'] is String ? json['reason'] as String : null,
    );
  }
}
