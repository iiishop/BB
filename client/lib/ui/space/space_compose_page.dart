import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import '../chat/media_actions.dart';
import 'space_compose_controller.dart';
import 'space_gateway.dart';
import 'space_image_viewer.dart';
import 'space_layout.dart';
import 'space_local_store.dart';
import 'space_widgets.dart';

Future<PickedSpaceImage?> defaultSpaceImagePicker() async {
  final PickedMedia? media = await MediaActions.pick(MediaPickKind.image);
  if (media == null) {
    return null;
  }
  return PickedSpaceImage(bytes: media.bytes, filename: media.filename);
}

/// Draft editor. Width-capped on PC; text and image order sit side by side when
/// there is room. Drag reordering always has explicit up/down alternatives.
class SpaceComposePage extends StatefulWidget {
  const SpaceComposePage({
    super.key,
    required this.gateway,
    required this.store,
    required this.images,
    this.draftId,
    this.referenceId,
    this.referencePost,
    this.picker,
  });

  final SpaceGateway gateway;
  final SpaceLocalStore store;
  final SpaceImageLoader images;
  final String? draftId;
  final String? referenceId;
  final SpacePost? referencePost;
  final Future<PickedSpaceImage?> Function()? picker;

  static const Key composeKey = Key('space-compose');
  static const Key textKey = Key('space-compose-text');
  static const Key publishKey = Key('space-compose-publish');
  static const Key closeKey = Key('space-compose-close');
  static const Key addImageKey = Key('space-compose-add-image');
  static const Key discardKey = Key('space-compose-discard');
  static const Key statusKey = Key('space-compose-status');
  static const Key conflictKey = Key('space-compose-conflict');
  static const Key reloadServerKey = Key('space-compose-reload-server');

  @override
  State<SpaceComposePage> createState() => _SpaceComposePageState();
}

class _SpaceComposePageState extends State<SpaceComposePage> {
  late final SpaceComposeController _compose;

  @override
  void initState() {
    super.initState();
    _compose = SpaceComposeController(
      gateway: widget.gateway,
      store: widget.store,
      draftId: widget.draftId,
      referenceId: widget.referenceId,
      referencePost: widget.referencePost,
      picker: widget.picker ?? defaultSpaceImagePicker,
    );
    _compose.addListener(_onChanged);
    _compose.text.addListener(_compose.onTextChanged);
    unawaited(_compose.start());
  }

  @override
  void dispose() {
    _compose.removeListener(_onChanged);
    _compose.text.removeListener(_compose.onTextChanged);
    _compose.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _publish() async {
    final bool ok = await _compose.publish();
    if (ok && mounted && _compose.publishedPostId != null) {
      Navigator.of(context).pop(_compose.publishedPostId);
    }
  }

  Future<void> _discard() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('丢弃这份草稿？'),
        content: const Text('丢弃后不能恢复；发布后的说说需要从详情里删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('丢弃草稿'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final bool ok = await _compose.discard();
      if (ok && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final SpaceLayout layout = SpaceLayout.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      key: SpaceComposePage.composeKey,
      backgroundColor: AppColors.paper,
      appBar: AppBar(
        backgroundColor: AppColors.paper,
        surfaceTintColor: Colors.transparent,
        title: Text(
          widget.referenceId != null
              ? '转发说说'
              : widget.draftId != null
              ? '编辑草稿'
              : '新说说',
        ),
        leading: IconButton(
          key: SpaceComposePage.closeKey,
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded),
        ),
        actions: <Widget>[
          if (_compose.canDiscard)
            PopupMenuButton<String>(
              key: SpaceComposePage.discardKey,
              onSelected: (String value) {
                if (value == 'discard') {
                  unawaited(_discard());
                }
              },
              itemBuilder: (BuildContext context) =>
                  const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'discard',
                      child: Text('丢弃草稿'),
                    ),
                  ],
            ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: FilledButton(
              key: SpaceComposePage.publishKey,
              onPressed: _compose.canPublish ? _publish : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              ),
              child: Text(_compose.publishing ? '发布中' : '发布'),
            ),
          ),
        ],
      ),
      body: SpaceOcclusion(
        layout: layout,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _statusBanner(text),
                  if (_compose.reference != null)
                    SpaceReferenceCard(
                      reference: _referenceOf(_compose.reference!),
                      onOpen: () {},
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  Expanded(
                    child: layout.composeTwoColumn
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Expanded(flex: 3, child: _editor(text)),
                              const VerticalDivider(width: AppSpacing.lg),
                              Expanded(flex: 2, child: _imageColumn(text)),
                            ],
                          )
                        : SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                _editor(text),
                                const SizedBox(height: AppSpacing.lg),
                                _imageColumn(text),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  SpaceReference _referenceOf(SpacePost post) => SpaceReference(
    postId: post.postId,
    deleted: false,
    author: post.author,
    text: post.text,
    image: post.images.isEmpty ? null : post.images.first,
  );

  Widget _statusBanner(TextTheme text) {
    final Widget? banner = switch (_compose.phase) {
      DraftSavePhase.conflict => SpaceInlineBanner(
        key: SpaceComposePage.conflictKey,
        message: _compose.error ?? '草稿已在别处更新',
        tone: AppColors.warning,
        background: AppColors.warningSurface,
        icon: Icons.sync_problem_rounded,
        actionLabel: '载入服务器版本',
        actionKey: SpaceComposePage.reloadServerKey,
        onAction: _compose.loadServerVersion,
      ),
      DraftSavePhase.offline => SpaceInlineBanner(
        message: _compose.error ?? '离线：仅保存在本机',
        tone: AppColors.warning,
        background: AppColors.warningSurface,
        icon: Icons.cloud_off_rounded,
        actionLabel: '重试保存',
        onAction: _compose.retry,
      ),
      DraftSavePhase.failed => SpaceInlineBanner(
        message: _compose.error ?? '保存失败',
        tone: AppColors.danger,
        background: AppColors.dangerSurface,
        icon: Icons.error_outline_rounded,
        actionLabel: '重试',
        onAction: _compose.retry,
      ),
      DraftSavePhase.creating ||
      DraftSavePhase.saving ||
      DraftSavePhase.dirty ||
      DraftSavePhase.saved => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_compose.publishError != null)
          SpaceInlineBanner(
            key: const Key('space-compose-publish-error'),
            message: _compose.publishError!,
            tone: AppColors.danger,
            background: AppColors.dangerSurface,
            icon: Icons.error_outline_rounded,
          ),
        ?banner,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: <Widget>[
              Icon(
                _compose.phase == DraftSavePhase.saved
                    ? Icons.cloud_done_outlined
                    : Icons.edit_note_rounded,
                size: 16,
                color: AppColors.inkMuted,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                _compose.statusLabel,
                key: SpaceComposePage.statusKey,
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _editor(TextTheme text) {
    return TextField(
      key: SpaceComposePage.textKey,
      controller: _compose.text,
      maxLines: null,
      minLines: 6,
      maxLength: 20000,
      textInputAction: TextInputAction.newline,
      style: text.bodyLarge?.copyWith(color: AppColors.ink, fontSize: 16),
      decoration: const InputDecoration(
        hintText: '这一刻想说什么？发布后不能编辑，只能删除。',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        counterStyle: TextStyle(fontSize: 11, color: AppColors.inkMuted),
      ),
    );
  }

  Widget _imageColumn(TextTheme text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('图片', style: text.titleMedium),
            const SizedBox(width: AppSpacing.sm),
            Text('${_compose.images.length}', style: text.bodySmall),
            const Spacer(),
            OutlinedButton.icon(
              key: SpaceComposePage.addImageKey,
              onPressed: _compose.busy ? null : _compose.addImage,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              ),
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('添加图片'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('九张只是信息流预览数量；发布前可调整顺序。', style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        if (_compose.images.isEmpty && _compose.pending.isEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.brand),
              border: Border.all(color: AppColors.border),
            ),
            child: Text('还没有图片', style: text.bodySmall),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _compose.images.length,
            onReorderItem: (int oldIndex, int newIndex) {
              unawaited(_compose.moveImage(oldIndex, newIndex));
            },
            itemBuilder: (BuildContext context, int index) {
              final SpaceImage image = _compose.images[index];
              final bool first = index == 0;
              final bool last = index == _compose.images.length - 1;
              return _imageTile(
                key: ValueKey<String>('saved-${image.imageId}'),
                index: index,
                child: _savedThumb(image),
                title: image.filename,
                first: first,
                last: last,
                onUp: first
                    ? null
                    : () => _compose.moveImageBy(image.imageId, -1),
                onDown: last
                    ? null
                    : () => _compose.moveImageBy(image.imageId, 1),
                onRemove: () => _compose.removeImage(image.imageId),
              );
            },
          ),
        for (final PendingDraftImage item in _compose.pending)
          _pendingTile(item),
      ],
    );
  }

  Widget _savedThumb(SpaceImage image) {
    return FutureBuilder<Uint8List>(
      future: widget.images.load(image.imageId),
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snapshot) {
        return snapshot.hasData
            ? Image.memory(snapshot.data!, fit: BoxFit.cover)
            : const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
      },
    );
  }

  Widget _imageTile({
    required Key key,
    required int index,
    required Widget child,
    required String title,
    required bool first,
    required bool last,
    required VoidCallback? onUp,
    required VoidCallback? onDown,
    required VoidCallback onRemove,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.brand),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: <Widget>[
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(AppSpacing.xs),
                child: Icon(Icons.drag_indicator_rounded, size: 20),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 52, height: 52, child: child),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            IconButton(
              key: Key('space-compose-up-$index'),
              onPressed: onUp,
              tooltip: '向前移动',
              icon: const Icon(Icons.arrow_upward_rounded, size: 18),
            ),
            IconButton(
              key: Key('space-compose-down-$index'),
              onPressed: onDown,
              tooltip: '向后移动',
              icon: const Icon(Icons.arrow_downward_rounded, size: 18),
            ),
            IconButton(
              key: Key('space-compose-remove-$index'),
              onPressed: onRemove,
              tooltip: '移除图片',
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingTile(PendingDraftImage item) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.warningSurface,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        border: Border.all(color: AppColors.warningBorder),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 52,
              height: 52,
              child: Image.memory(item.bytes, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  item.uploading ? '上传中…' : item.error ?? '等待上传',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.warning,
                  ),
                ),
              ],
            ),
          ),
          if (!item.uploading && item.error != null)
            TextButton(
              key: Key('space-compose-retry-${item.filename}'),
              onPressed: () => _compose.retryUpload(item),
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
