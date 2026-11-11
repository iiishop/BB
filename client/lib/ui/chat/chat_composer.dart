import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/media_source.dart';
import 'chat_format.dart';
import 'media_actions.dart';

/// Ordered composer: text and images keep their insertion order; videos,
/// PDFs and other files are independent attachment messages.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.chat,
    required this.peerAccount,
    required this.onSent,
    this.enabled = true,
  });

  final ChatService chat;
  final String peerAccount;
  final void Function(List<ChatMessage> messages) onSent;
  final bool enabled;

  static const Key inputKey = Key('chat-composer-input');
  static const Key sendKey = Key('chat-composer-send');
  static const Key imageKey = Key('chat-composer-image');
  static const Key fileKey = Key('chat-composer-file');
  static const Key pasteKey = Key('chat-composer-paste');
  static const Key retryKey = Key('chat-composer-retry');

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<_DraftPart> _parts = <_DraftPart>[];
  final List<_DraftAttachment> _attachments = <_DraftAttachment>[];
  List<SendOutcome> _failed = <SendOutcome>[];
  bool _sending = false;

  @override
  void dispose() {
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
      final AttachmentKind kind = attachmentKindForMime(picked.mimeType);
      ResolvedMedia? cover;
      if (kind == AttachmentKind.video) {
        cover = await MediaActions.extractVideoCover(
          bytes: picked.bytes,
          filename: picked.filename,
        );
        if (cover == null) {
          _snack('无法从该视频提取封面，请换一个视频或提供封面图片');
          return;
        }
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
    } on FormatException catch (error) {
      _snack(error.message);
    } catch (_) {
      _snack('选择文件失败');
    }
  }

  Future<void> _pasteImage() async {
    try {
      final PickedMedia? picked = await MediaActions.readClipboardImage();
      if (!mounted) {
        return;
      }
      if (picked == null) {
        _snack('当前系统无法读取图片剪贴板（移动端粘贴图片为 NOT RUN）');
        return;
      }
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
    } catch (_) {
      _snack('粘贴图片失败');
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
    if (_sending || !widget.enabled) {
      return;
    }
    _commitCurrentText();
    if (_parts.isEmpty && _attachments.isEmpty) {
      return;
    }
    setState(() {
      _sending = true;
      _failed = <SendOutcome>[];
    });
    final List<OutgoingPart> body = <OutgoingPart>[
      for (final _DraftPart part in _parts) part.part,
    ];
    final List<OutgoingAttachment> attachments = <OutgoingAttachment>[
      for (final _DraftAttachment item in _attachments) item.attachment,
    ];
    try {
      final ComposedSendResult result = await widget.chat.sendComposed(
        targetAccount: widget.peerAccount,
        body: body,
        attachments: attachments,
      );
      final List<ChatMessage> sent = <ChatMessage>[
        if (result.body?.succeeded ?? false) result.body!.message!,
        for (final SendOutcome outcome in result.attachments)
          if (outcome.succeeded) outcome.message!,
      ];
      final List<SendOutcome> failed = <SendOutcome>[
        if (!(result.body?.succeeded ?? true)) result.body!,
        for (final SendOutcome outcome in result.attachments)
          if (!outcome.succeeded) outcome,
      ];
      if (!mounted) {
        return;
      }
      setState(() {
        _sending = false;
        _parts.clear();
        _attachments.clear();
        _failed = failed;
      });
      if (sent.isNotEmpty) {
        widget.onSent(sent);
      }
      if (failed.isNotEmpty) {
        _snack('有 ${failed.length} 项发送失败，可点击重试');
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _sending = false);
      _snack('发送失败，请稍后重试');
    }
  }

  Future<void> _retryFailed() async {
    if (_sending || _failed.isEmpty) {
      return;
    }
    setState(() => _sending = true);
    final List<ChatMessage> sent = <ChatMessage>[];
    final List<SendOutcome> remaining = <SendOutcome>[];
    for (final SendOutcome outcome in List<SendOutcome>.from(_failed)) {
      try {
        if (outcome.part != null) {
          final SendOutcome retried = await widget.chat.sendBody(
            targetAccount: widget.peerAccount,
            content: outcome.part!,
            operationId: outcome.operationId,
          );
          if (retried.message != null) {
            sent.add(retried.message!);
          }
        } else if (outcome.attachment != null) {
          final SendOutcome retried = await widget.chat.sendAttachment(
            targetAccount: widget.peerAccount,
            attachment: outcome.attachment!,
            operationId: outcome.operationId,
          );
          if (retried.message != null) {
            sent.add(retried.message!);
          }
        }
      } on AuthFailure catch (failure) {
        remaining.add(
          SendOutcome(
            operationId: outcome.operationId,
            failure: failure,
            part: outcome.part,
            attachment: outcome.attachment,
          ),
        );
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sending = false;
      _failed = remaining;
    });
    if (sent.isNotEmpty) {
      widget.onSent(sent);
    }
    if (remaining.isNotEmpty) {
      _snack('仍有 ${remaining.length} 项发送失败');
    }
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
              if (_failed.isNotEmpty) _failedBanner(),
              if (hasDraft) _draftStrip(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    key: ChatComposer.imageKey,
                    tooltip: '图片',
                    onPressed: _sending ? null : _addImage,
                    icon: const Icon(Icons.image_outlined),
                  ),
                  IconButton(
                    key: ChatComposer.fileKey,
                    tooltip: '附件',
                    onPressed: _sending ? null : _addFile,
                    icon: const Icon(Icons.attach_file_rounded),
                  ),
                  IconButton(
                    key: ChatComposer.pasteKey,
                    tooltip: '粘贴图片',
                    onPressed: _sending ? null : _pasteImage,
                    icon: const Icon(Icons.content_paste_rounded),
                  ),
                  Expanded(
                    child: TextField(
                      key: ChatComposer.inputKey,
                      controller: _controller,
                      focusNode: _focus,
                      enabled: !_sending && widget.enabled,
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
                      onPressed: _sending ? null : _send,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(48, 48),
                      ),
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.surface,
                              ),
                            )
                          : const Icon(Icons.arrow_upward_rounded),
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

  Widget _failedBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.dangerSurface,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        border: Border.all(color: AppColors.dangerBorder),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              '${_failed.length} 项未发送，重试不会重发已成功项',
              style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
            ),
          ),
          TextButton(
            key: ChatComposer.retryKey,
            onPressed: _sending ? null : _retryFailed,
            child: const Text('重试'),
          ),
        ],
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
