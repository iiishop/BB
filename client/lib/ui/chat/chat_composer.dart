import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/media_source.dart';
import 'chat_format.dart';
import 'media_actions.dart';
import 'pending_send.dart';

/// Lets the chat page retry one failed item from its bubble.
///
/// The composer still owns the operation plan so a retry reuses the exact same
/// operation id and cannot double-send.
class ChatComposerController {
  _ChatComposerState? _state;

  void _attach(_ChatComposerState state) {
    _state = state;
  }

  void _detach(_ChatComposerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  bool get canRetry => _state?._failed.isNotEmpty ?? false;

  Future<void> retryFailed(String operationId) async {
    final _ChatComposerState? state = _state;
    if (state == null || !state.mounted) {
      return;
    }
    await state._retryOne(operationId);
  }

  /// The server operation was verified as committed; the local failure entry
  /// and its retry affordance must disappear.
  void forgetCommittedOperation(String operationId) {
    _state?._forgetCommittedOperation(operationId);
  }
}

/// Ordered composer: text and images keep their insertion order; videos,
/// PDFs and other files are independent attachment messages.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.chat,
    required this.peerAccount,
    required this.onSent,
    this.onSentOperations,
    this.onPendingChanged,
    this.controller,
    this.enabled = true,
    this.clipboard = const PlatformClipboardMediaReader(),
    this.coverExtractor = defaultVideoCoverExtractor,
  });

  final ChatService chat;
  final String peerAccount;

  /// Successful messages plus the local bytes already held for body images,
  /// keyed by the committed media id.
  final void Function(
    List<ChatMessage> messages,
    Map<String, Uint8List> localPreviews,
  )
  onSent;

  /// Successful operations paired with the committed messages, so the chat
  /// page can keep one bubble element from "sending" to "sent".
  final void Function(List<SentOperation> operations)? onSentOperations;

  /// Snapshot of local bubbles that have not settled yet (sending or failed).
  final void Function(List<PendingSend> pending)? onPendingChanged;

  final ChatComposerController? controller;
  final bool enabled;
  final ClipboardMediaReader clipboard;

  /// Product default is the real ffmpeg/platform extractor; the seam lets
  /// widget tests observe the picked path/bytes without replacing the UI flow.
  final VideoCoverExtractorFn coverExtractor;

  static const Key inputKey = Key('chat-composer-input');
  static const Key sendKey = Key('chat-composer-send');
  static const Key imageKey = Key('chat-composer-image');
  static const Key fileKey = Key('chat-composer-file');
  static const Key pasteKey = Key('chat-composer-paste');

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<_DraftPart> _parts = <_DraftPart>[];
  final List<_DraftAttachment> _attachments = <_DraftAttachment>[];
  List<SendOutcome> _failed = <SendOutcome>[];
  final List<PendingSend> _pending = <PendingSend>[];

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _addImage() async {
    try {
      final PickedMedia? picked = await MediaActions.pick(MediaPickKind.image);
      if (picked == null || !mounted) {
        return;
      }
      _addBodyImage(picked);
    } on FormatException catch (error) {
      _snack(error.message);
    } catch (_) {
      _snack('选择图片失败');
    }
  }

  Future<void> _addFile() async {
    try {
      final PickedMedia? picked = await MediaActions.pick(MediaPickKind.file);
      if (picked == null || !mounted) {
        return;
      }
      if (picked.mimeType.startsWith('image/')) {
        _addBodyImage(picked);
        return;
      }
      await _addAttachment(picked);
    } on FormatException catch (error) {
      _snack(error.message);
    } catch (_) {
      _snack('选择文件失败');
    }
  }

  Future<void> _addAttachment(PickedMedia picked) async {
    final AttachmentKind kind = attachmentKindForMime(picked.mimeType);
    ResolvedMedia? cover;
    if (kind == AttachmentKind.video) {
      cover = await widget.coverExtractor(
        path: picked.path,
        bytes: picked.bytes,
        filename: picked.filename,
      );
      if (cover == null) {
        _snack('无法从该视频提取封面，请换一个视频');
        return;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _attachments.add(
        _DraftAttachment(
          attachment: OutgoingAttachment(
            source: MediaSource(
              bytes: picked.bytes,
              filename: picked.filename,
              mimeType: picked.mimeType,
            ),
            cover: cover == null
                ? null
                : MediaSource(
                    bytes: cover.bytes,
                    filename: cover.filename,
                    mimeType: cover.mimeType,
                  ),
          ),
          filename: picked.filename,
          size: picked.bytes.length,
          kind: kind,
          coverBytes: cover?.bytes,
        ),
      );
    });
  }

  void _addBodyImage(PickedMedia picked) {
    _commitCurrentText();
    setState(() {
      _parts.add(
        _DraftPart(
          OutgoingImage(
            MediaSource(
              bytes: picked.bytes,
              filename: picked.filename,
              mimeType: picked.mimeType,
            ),
          ),
          bytes: picked.bytes,
        ),
      );
    });
  }

  Future<void> _pasteMedia() async {
    try {
      final PickedMedia? picked = await widget.clipboard.read();
      if (!mounted) {
        return;
      }
      if (picked == null) {
        _snack('剪贴板中没有可用的图片或视频');
        return;
      }
      if (picked.mimeType.startsWith('image/')) {
        _addBodyImage(picked);
      } else if (picked.mimeType.startsWith('video/')) {
        await _addAttachment(picked);
      } else {
        _snack('剪贴板媒体类型不受支持，仅支持图片或视频');
      }
    } catch (_) {
      _snack('读取剪贴板媒体失败');
    }
  }

  void _commitCurrentText() {
    final String text = _controller.text.trim();
    if (text.isEmpty) {
      _controller.clear();
      return;
    }
    _parts.add(_DraftPart(OutgoingText(text)));
    _controller.clear();
  }

  Future<void> _send() async {
    if (!widget.enabled) {
      return;
    }
    _commitCurrentText();
    if (_parts.isEmpty && _attachments.isEmpty) {
      return;
    }
    final List<_DraftPart> parts = List<_DraftPart>.of(_parts);
    final List<_DraftAttachment> attachments = List<_DraftAttachment>.of(
      _attachments,
    );
    final String seed = newOperationId('x');
    final List<PendingSend> pending;
    try {
      pending = _buildPending(seed, parts, attachments);
    } on AuthFailure catch (failure) {
      _snack(failure.message);
      return;
    }
    setState(() {
      _parts.clear();
      _attachments.clear();
      _pending.addAll(pending);
    });
    _emitPending();
    final List<OutgoingPart> body = <OutgoingPart>[
      for (final _DraftPart part in parts) part.part,
    ];
    final List<OutgoingAttachment> outgoingAttachments = <OutgoingAttachment>[
      for (final _DraftAttachment item in attachments) item.attachment,
    ];
    try {
      final ComposedSendResult result = await widget.chat.sendComposed(
        targetAccount: widget.peerAccount,
        body: body,
        attachments: outgoingAttachments,
        operationSeed: seed,
      );
      if (!mounted) {
        return;
      }
      _applyResult(result);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      _markSeedFailed(seed, parts, attachments, failure);
      _snack(failure.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      _markSeedFailed(
        seed,
        parts,
        attachments,
        const AuthFailure(
          status: 0,
          code: 'send_failed',
          message: '发送失败，请稍后重试',
        ),
      );
      _snack('发送失败，请稍后重试');
    }
  }

  void _applyResult(ComposedSendResult result) {
    final List<SendOutcome> outcomes = <SendOutcome>[
      if (result.body != null) result.body!,
      ...result.attachments,
    ];
    final Set<String> succeededIds = <String>{};
    final Set<String> failedIds = <String>{};
    final List<ChatMessage> sent = <ChatMessage>[];
    final List<SendOutcome> failed = <SendOutcome>[];
    final List<SentOperation> operations = <SentOperation>[];
    for (final SendOutcome outcome in outcomes) {
      final ChatMessage? message = outcome.message;
      if (message != null) {
        succeededIds.add(outcome.operationId);
        sent.add(message);
        operations.add(
          SentOperation(operationId: outcome.operationId, message: message),
        );
      } else {
        failedIds.add(outcome.operationId);
        failed.add(outcome);
      }
    }
    setState(() {
      _pending.removeWhere(
        (PendingSend pending) => succeededIds.contains(pending.operationId),
      );
      _markPendingFailed(failedIds);
      // Earlier failures stay retryable when a new message is sent.
      _failed.addAll(failed);
    });
    if (sent.isNotEmpty) {
      widget.onSent(sent, _bodyLocalPreviews(result.body));
      widget.onSentOperations?.call(operations);
    }
    _emitPending();
    if (failed.isNotEmpty) {
      _snack('有 ${failed.length} 项发送失败，可点按气泡重试');
    }
  }

  void _markSeedFailed(
    String seed,
    List<_DraftPart> parts,
    List<_DraftAttachment> attachments,
    AuthFailure failure,
  ) {
    final List<SendOutcome> failed = <SendOutcome>[
      if (parts.isNotEmpty)
        SendOutcome(
          operationId: '$seed-b',
          failure: failure,
          part: <OutgoingPart>[for (final _DraftPart part in parts) part.part],
        ),
      for (int i = 0; i < attachments.length; i += 1)
        SendOutcome(
          operationId: '$seed-a$i',
          failure: failure,
          attachment: attachments[i].attachment,
        ),
    ];
    setState(() {
      _failed.addAll(failed);
      _markPendingFailed(<String>{
        for (final SendOutcome outcome in failed) outcome.operationId,
      });
    });
    _emitPending();
  }

  void _markPendingFailed(Set<String> operationIds) {
    for (int i = 0; i < _pending.length; i += 1) {
      if (operationIds.contains(_pending[i].operationId)) {
        _pending[i] = _pending[i].copyWith(state: SendFeedbackState.failed);
      }
    }
  }

  Future<void> _retryOne(String operationId) async {
    if (!widget.enabled) {
      return;
    }
    final int index = _failed.indexWhere(
      (SendOutcome outcome) => outcome.operationId == operationId,
    );
    if (index < 0) {
      return;
    }
    final SendOutcome outcome = _failed[index];
    setState(() {
      _failed = List<SendOutcome>.of(_failed)..removeAt(index);
      _setPendingState(operationId, SendFeedbackState.sending);
    });
    _emitPending();
    SendOutcome? retried;
    try {
      if (outcome.part != null) {
        retried = await widget.chat.sendBody(
          targetAccount: widget.peerAccount,
          content: outcome.part!,
          operationId: operationId,
        );
      } else if (outcome.attachment != null) {
        retried = await widget.chat.sendAttachment(
          targetAccount: widget.peerAccount,
          attachment: outcome.attachment!,
          operationId: operationId,
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _failed.add(
          error is AuthFailure
              ? SendOutcome(
                  operationId: operationId,
                  failure: error,
                  part: outcome.part,
                  attachment: outcome.attachment,
                )
              : outcome,
        );
        _setPendingState(operationId, SendFeedbackState.failed);
      });
      _emitPending();
      _snack(error is AuthFailure ? error.message : '重试失败，请稍后再试');
      return;
    }
    if (!mounted) {
      return;
    }
    if (retried == null) {
      setState(() {
        _failed.add(outcome);
        _setPendingState(operationId, SendFeedbackState.failed);
      });
      _emitPending();
      return;
    }
    final ChatMessage? message = retried.message;
    if (message == null) {
      setState(() {
        _failed.add(retried!);
        _setPendingState(operationId, SendFeedbackState.failed);
      });
      _emitPending();
      _snack('重试失败，请稍后再试');
      return;
    }
    setState(() {
      _pending.removeWhere(
        (PendingSend pending) => pending.operationId == operationId,
      );
    });
    widget.onSent(<ChatMessage>[message], _bodyLocalPreviews(retried));
    widget.onSentOperations?.call(<SentOperation>[
      SentOperation(operationId: operationId, message: message),
    ]);
    _emitPending();
  }

  void _forgetCommittedOperation(String operationId) {
    final bool hadFailed = _failed.any(
      (SendOutcome outcome) => outcome.operationId == operationId,
    );
    final bool hadPending = _pending.any(
      (PendingSend item) => item.operationId == operationId,
    );
    if (!hadFailed && !hadPending) {
      return;
    }
    setState(() {
      _failed.removeWhere(
        (SendOutcome outcome) => outcome.operationId == operationId,
      );
      _pending.removeWhere(
        (PendingSend item) => item.operationId == operationId,
      );
    });
    if (hadPending) {
      _emitPending();
    }
  }

  void _setPendingState(String operationId, SendFeedbackState state) {
    for (int i = 0; i < _pending.length; i += 1) {
      if (_pending[i].operationId == operationId) {
        _pending[i] = _pending[i].copyWith(state: state);
      }
    }
  }

  void _emitPending() {
    final void Function(List<PendingSend>)? callback = widget.onPendingChanged;
    if (callback == null) {
      return;
    }
    callback(List<PendingSend>.unmodifiable(_pending));
  }

  /// Builds one local bubble per outgoing item before any request is sent.
  /// Media ids are local-only, so a pending image can render from bytes the
  /// composer already holds without pretending it was uploaded.
  List<PendingSend> _buildPending(
    String seed,
    List<_DraftPart> parts,
    List<_DraftAttachment> attachments,
  ) {
    final String self = widget.chat.selfAccount;
    final DateTime now = DateTime.now().toUtc();
    final List<PendingSend> pending = <PendingSend>[];
    final List<MessagePart> bodyParts = <MessagePart>[];
    final Map<String, Uint8List> imageBytes = <String, Uint8List>{};
    for (int index = 0; index < parts.length; index += 1) {
      final OutgoingPart part = parts[index].part;
      if (part is OutgoingText) {
        bodyParts.add(TextPart(part.text));
      } else if (part is OutgoingImage) {
        final String mediaId = 'pending:$seed:img$index';
        bodyParts.add(ImagePart(mediaId));
        final Uint8List? bytes = parts[index].bytes ?? part.source.bytes;
        if (bytes != null && bytes.isNotEmpty) {
          imageBytes[mediaId] = bytes;
        }
      }
    }
    if (bodyParts.isNotEmpty) {
      pending.add(
        PendingSend(
          operationId: '$seed-b',
          message: ChatMessage(
            id: 'pending:$seed-b',
            position: 0,
            senderAccount: self,
            targetAccount: widget.peerAccount,
            createdAt: now,
            kind: ChatMessageKind.body,
            parts: bodyParts,
          ),
          state: SendFeedbackState.sending,
          imageBytes: imageBytes,
        ),
      );
    }
    for (int index = 0; index < attachments.length; index += 1) {
      final _DraftAttachment draft = attachments[index];
      final Uint8List? cover = draft.coverBytes;
      final String mediaId = 'pending:$seed:att$index';
      final String? coverId = cover == null
          ? null
          : 'pending:$seed:cover$index';
      pending.add(
        PendingSend(
          operationId: '$seed-a$index',
          message: ChatMessage(
            id: 'pending:$seed-a$index',
            position: 0,
            senderAccount: self,
            targetAccount: widget.peerAccount,
            createdAt: now,
            kind: ChatMessageKind.attachment,
            attachment: Attachment(
              mediaId: mediaId,
              kind: draft.kind,
              filename: draft.filename,
              mimeType:
                  draft.attachment.source.mimeType ??
                  'application/octet-stream',
              byteSize: draft.size,
              coverMediaId: coverId,
            ),
          ),
          state: SendFeedbackState.sending,
          imageBytes: coverId == null
              ? const <String, Uint8List>{}
              : <String, Uint8List>{coverId: cover!},
        ),
      );
    }
    return pending;
  }

  /// Maps committed image blocks back to the bytes the composer still holds.
  /// Only used when both sides report the same number of images; a mismatch
  /// means the server normalized the body and guessing would bind wrong bytes.
  Map<String, Uint8List> _bodyLocalPreviews(SendOutcome? outcome) {
    final ChatMessage? message = outcome?.message;
    final List<OutgoingPart>? parts = outcome?.part;
    if (message == null || parts == null) {
      return <String, Uint8List>{};
    }
    final List<ImagePart> images = message.parts
        .whereType<ImagePart>()
        .toList();
    final List<OutgoingImage> outgoing = parts
        .whereType<OutgoingImage>()
        .toList();
    if (images.length != outgoing.length) {
      return <String, Uint8List>{};
    }
    final Map<String, Uint8List> previews = <String, Uint8List>{};
    for (int index = 0; index < images.length; index += 1) {
      final Uint8List? bytes = outgoing[index].source.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        previews[images[index].mediaId] = bytes;
      }
    }
    return previews;
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bool hasDraft = _parts.isNotEmpty || _attachments.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (hasDraft) _draftStrip(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    key: ChatComposer.imageKey,
                    tooltip: '图片',
                    onPressed: widget.enabled ? _addImage : null,
                    icon: const Icon(Icons.image_outlined),
                  ),
                  IconButton(
                    key: ChatComposer.fileKey,
                    tooltip: '附件',
                    onPressed: widget.enabled ? _addFile : null,
                    icon: const Icon(Icons.attach_file_rounded),
                  ),
                  IconButton(
                    key: ChatComposer.pasteKey,
                    tooltip: '粘贴图片或视频',
                    onPressed: widget.enabled ? _pasteMedia : null,
                    icon: const Icon(Icons.content_paste_rounded),
                  ),
                  Expanded(
                    child: TextField(
                      key: ChatComposer.inputKey,
                      controller: _controller,
                      focusNode: _focus,
                      enabled: widget.enabled,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '输入消息…',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm + 4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: FilledButton(
                      key: ChatComposer.sendKey,
                      onPressed: widget.enabled ? _send : null,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Icon(Icons.arrow_upward_rounded),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _draftStrip() {
    return SizedBox(
      height: 64,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: <Widget>[
          for (int i = 0; i < _parts.length; i++) _partChip(i, _parts[i]),
          for (int i = 0; i < _attachments.length; i++)
            _attachmentChip(i, _attachments[i]),
        ],
      ),
    );
  }

  Widget _partChip(int index, _DraftPart part) {
    final Widget content = part.bytes == null
        ? Container(
            constraints: const BoxConstraints(maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            alignment: Alignment.centerLeft,
            child: Text(
              (part.part as OutgoingText).text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              part.bytes!,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) {
                    return const SizedBox(width: 56, height: 56);
                  },
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: content,
          ),
          Positioned(
            right: -6,
            top: -6,
            child: InkWell(
              onTap: () => setState(() => _parts.removeAt(index)),
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppColors.ink,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: AppColors.surface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attachmentChip(int index, _DraftAttachment attachment) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            height: 56,
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: AppColors.paper,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (attachment.coverBytes != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(
                      attachment.coverBytes!,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                    ),
                  )
                else
                  Icon(
                    Icons.insert_drive_file_outlined,
                    color: attachmentColor(
                      attachment.kind == AttachmentKind.document
                          ? 'application/pdf'
                          : 'application/octet-stream',
                    ),
                  ),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        attachment.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${attachment.kind.previewLabel} · '
                        '${formatBytes(attachment.size)}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: -6,
            top: -6,
            child: InkWell(
              onTap: () => setState(() => _attachments.removeAt(index)),
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppColors.ink,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: AppColors.surface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftPart {
  const _DraftPart(this.part, {this.bytes});

  final OutgoingPart part;
  final Uint8List? bytes;
}

class _DraftAttachment {
  const _DraftAttachment({
    required this.attachment,
    required this.filename,
    required this.size,
    required this.kind,
    this.coverBytes,
  });

  final OutgoingAttachment attachment;
  final String filename;
  final int size;
  final AttachmentKind kind;
  final Uint8List? coverBytes;
}
