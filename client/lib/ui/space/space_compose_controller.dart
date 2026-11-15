import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../models/auth_models.dart';
import '../../models/space_models.dart';
import 'space_gateway.dart';
import 'space_local_store.dart';

enum DraftSavePhase {
  creating,
  saved,
  saving,
  dirty,
  conflict,
  offline,
  failed,
}

class PickedSpaceImage {
  const PickedSpaceImage({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

class PendingDraftImage {
  PendingDraftImage({required this.filename, required this.bytes});

  final String filename;
  final Uint8List bytes;
  String? error;
  bool uploading = false;

  /// Bytes reached the server but the refreshed draft could not be read; a
  /// retry must fetch the draft again instead of uploading a second copy.
  bool uploaded = false;
}

/// Draft editor state. It owns no business fact: the server draft is
/// authoritative, while this controller only buffers unsynced text and image
/// order until the server accepts one explicit version.
class SpaceComposeController extends ChangeNotifier {
  SpaceComposeController({
    required this.gateway,
    required this.store,
    this.draftId,
    this.referenceId,
    this.referencePost,
    this.picker,
  });

  final SpaceGateway gateway;
  final SpaceLocalStore store;
  final String? draftId;
  final String? referenceId;
  final SpacePost? referencePost;
  final Future<PickedSpaceImage?> Function()? picker;

  final TextEditingController text = TextEditingController();

  DraftSavePhase phase = DraftSavePhase.creating;
  String? error;
  String? publishedPostId;
  SpacePost? reference;

  String? _id;
  int? _version;
  String _serverText = '';
  List<SpaceImage> _images = <SpaceImage>[];
  List<String> _order = <String>[];
  final List<PendingDraftImage> pending = <PendingDraftImage>[];
  String? _localKey;
  Timer? _debounce;
  bool _saving = false;
  int _counter = 0;
  bool _disposed = false;

  String? get id => _id;
  int? get version => _version;
  List<SpaceImage> get images => List<SpaceImage>.unmodifiable(_images);
  bool get busy =>
      phase == DraftSavePhase.creating || phase == DraftSavePhase.saving;
  bool get hasReference => referenceId != null;

  bool get canPublish =>
      _id != null &&
      _version != null &&
      phase == DraftSavePhase.saved &&
      pending.every((PendingDraftImage p) => !p.uploading && p.error == null) &&
      pending.isEmpty &&
      (text.text.trim().isNotEmpty || _images.isNotEmpty || hasReference);

  bool get canDiscard => _id != null && _version != null && !busy;

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  String get _opId {
    _counter += 1;
    return 'space-draft-${DateTime.now().microsecondsSinceEpoch}-$_counter';
  }

  Future<void> start() async {
    reference = referencePost;
    if (referenceId != null && reference == null) {
      try {
        reference = await gateway.getPost(referenceId!, visitId: null);
      } catch (_) {
        // The direct source may already be deleted; publishing then reports
        // source_deleted and the draft stays private.
      }
    }
    final String intent =
        _localKey ?? draftId ?? 'new-${DateTime.now().microsecondsSinceEpoch}';
    _localKey = intent;
    final SpaceDraftBuffer? local = store.draft(intent);
    try {
      SpaceDraft draft;
      if (draftId != null) {
        draft = await gateway.getDraft(draftId!);
      } else {
        final SpaceOperation created = await gateway.createDraft(
          operationId: _opId,
          text: local?.text ?? '',
          referenceId: referenceId,
        );
        final String? newId = created.resourceId;
        if (newId == null) {
          phase = DraftSavePhase.failed;
          error = '草稿创建失败，请稍后重试';
          _notify();
          return;
        }
        draft = await gateway.getDraft(newId);
      }
      _id = draft.draftId;
      _version = draft.version;
      _serverText = draft.text;
      _images = List<SpaceImage>.of(draft.images);
      if (local != null && _localKey != draft.draftId) {
        store.deleteDraft(_localKey!);
        store.saveDraft(draft.draftId, local);
      }
      _localKey = draft.draftId;
      final SpaceDraftBuffer? buffered = store.draft(draft.draftId);
      text.text = buffered?.dirty == true ? buffered!.text : draft.text;
      _order = buffered?.dirty == true
          ? _mergeOrder(buffered!.imageIds, draft.images)
          : draft.images.map((SpaceImage i) => i.imageId).toList();
      phase = buffered?.dirty == true
          ? DraftSavePhase.dirty
          : DraftSavePhase.saved;
      _persist(dirty: phase == DraftSavePhase.dirty);
      _notify();
      if (phase == DraftSavePhase.dirty) {
        _scheduleSave();
      }
    } on AuthFailure catch (failure) {
      if (isSpaceOffline(failure)) {
        phase = DraftSavePhase.offline;
        error = '无法连接服务器，输入会先保存在本机';
        if (local != null) {
          text.text = local.text;
          _order = local.imageIds;
        }
      } else {
        phase = DraftSavePhase.failed;
        error = spaceErrorText(failure);
      }
      _persist(dirty: true);
      _notify();
    } catch (failure) {
      phase = DraftSavePhase.offline;
      error = '无法连接服务器，输入会先保存在本机';
      if (local != null) {
        text.text = local.text;
        _order = local.imageIds;
      }
      _persist(dirty: true);
      _notify();
    }
  }

  List<String> _mergeOrder(List<String> preferred, List<SpaceImage> server) {
    final Set<String> available = server
        .map((SpaceImage i) => i.imageId)
        .toSet();
    final List<String> merged = preferred.where(available.contains).toList();
    for (final SpaceImage image in server) {
      if (!merged.contains(image.imageId)) {
        merged.add(image.imageId);
      }
    }
    return merged;
  }

  void onTextChanged() {
    if (phase == DraftSavePhase.creating) {
      return;
    }
    _persist(dirty: true);
    if (phase != DraftSavePhase.conflict) {
      phase = DraftSavePhase.dirty;
    }
    _notify();
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(saveNow());
    });
  }

  Future<void> saveNow() async {
    final String? id = _id;
    final int? version = _version;
    if (id == null || version == null || _saving || _disposed) {
      return;
    }
    if (phase == DraftSavePhase.conflict) {
      return;
    }
    _saving = true;
    phase = DraftSavePhase.saving;
    _notify();
    try {
      final SpaceOperation operation = await gateway.updateDraft(
        draftId: id,
        operationId: _opId,
        expectedVersion: version,
        text: text.text,
        referenceId: referenceId,
        imageIds: _order,
      );
      _version = operation.resourceVersion ?? version;
      _serverText = text.text;
      phase = DraftSavePhase.saved;
      error = null;
      _persist(dirty: false);
    } on AuthFailure catch (failure) {
      if (failure.code == 'version_conflict') {
        phase = DraftSavePhase.conflict;
        error = '草稿已在别处更新；本机输入已保留，不会被覆盖';
      } else if (isSpaceOffline(failure)) {
        phase = DraftSavePhase.offline;
        error = '暂时无法保存，输入已留在本机';
      } else {
        phase = DraftSavePhase.failed;
        error = spaceErrorText(failure);
      }
      _persist(dirty: true);
    } catch (failure) {
      phase = isSpaceOffline(failure)
          ? DraftSavePhase.offline
          : DraftSavePhase.failed;
      error = isSpaceOffline(failure)
          ? '暂时无法保存，输入已留在本机'
          : spaceErrorText(failure);
      _persist(dirty: true);
    } finally {
      _saving = false;
      _notify();
    }
  }

  /// Re-reads the server copy after an explicit conflict decision. Local input
  /// is replaced only by this action, never by the background save.
  Future<void> loadServerVersion() async {
    final String? id = _id;
    if (id == null) {
      return;
    }
    try {
      final SpaceDraft draft = await gateway.getDraft(id);
      _version = draft.version;
      _serverText = draft.text;
      _images = List<SpaceImage>.of(draft.images);
      _order = draft.images.map((SpaceImage i) => i.imageId).toList();
      text.text = draft.text;
      phase = DraftSavePhase.saved;
      error = null;
      _persist(dirty: false);
    } catch (failure) {
      phase = isSpaceOffline(failure)
          ? DraftSavePhase.offline
          : DraftSavePhase.failed;
      error = spaceErrorText(failure);
    }
    _notify();
  }

  void _persist({required bool dirty}) {
    final String? key = _localKey ?? _id;
    if (key == null) {
      return;
    }
    store.saveDraft(
      key,
      SpaceDraftBuffer(
        text: text.text,
        imageIds: List<String>.of(_order),
        serverText: _serverText,
        serverImageIds: _images.map((SpaceImage i) => i.imageId).toList(),
        dirty: dirty,
        version: _version,
      ),
    );
  }

  Future<void> addImage() async {
    final Future<PickedSpaceImage?> Function()? pick = picker;
    if (pick == null) {
      return;
    }
    final PickedSpaceImage? picked = await pick();
    if (picked == null) {
      return;
    }
    final PendingDraftImage item = PendingDraftImage(
      filename: picked.filename,
      bytes: picked.bytes,
    );
    pending.add(item);
    _notify();
    await _upload(item);
  }

  Future<void> retryUpload(PendingDraftImage item) async {
    if (item.uploading) {
      return;
    }
    item.error = null;
    if (item.uploaded) {
      await _refreshDraftImages(item);
      return;
    }
    await _upload(item);
  }

  Future<void> _refreshDraftImages(PendingDraftImage item) async {
    final String? id = _id;
    if (id == null) {
      return;
    }
    item.uploading = true;
    _notify();
    try {
      final SpaceDraft draft = await gateway.getDraft(id);
      _version = draft.version;
      _images = List<SpaceImage>.of(draft.images);
      _order = draft.images.map((SpaceImage i) => i.imageId).toList();
      pending.remove(item);
      phase = DraftSavePhase.saved;
      error = null;
      _persist(dirty: false);
    } catch (failure) {
      item.error = '上传结果待确认';
      error = spaceErrorText(failure);
      phase = isSpaceOffline(failure)
          ? DraftSavePhase.offline
          : DraftSavePhase.failed;
      _persist(dirty: true);
    } finally {
      item.uploading = false;
      _notify();
    }
  }

  Future<void> _upload(PendingDraftImage item) async {
    final String? id = _id;
    final int? version = _version;
    if (id == null || version == null) {
      item.error = '草稿尚未创建';
      _notify();
      return;
    }
    item.uploading = true;
    item.error = null;
    _notify();
    try {
      final SpaceOperation operation = await gateway.addImage(
        draftId: id,
        operationId: _opId,
        expectedVersion: version,
        filename: item.filename,
        bytes: item.bytes,
      );
      _version = operation.resourceVersion ?? version;
      item.uploaded = true;
      final SpaceDraft draft = await gateway.getDraft(id);
      _images = List<SpaceImage>.of(draft.images);
      _order = draft.images.map((SpaceImage i) => i.imageId).toList();
      _version = draft.version;
      pending.remove(item);
      if (phase != DraftSavePhase.conflict) {
        phase = DraftSavePhase.saved;
      }
      error = null;
      _persist(dirty: false);
    } on AuthFailure catch (failure) {
      if (failure.code == 'version_conflict') {
        phase = DraftSavePhase.conflict;
        item.error = '草稿已更新';
        error = '草稿已在别处更新；本机输入已保留，不会被覆盖';
      } else if (isSpaceOffline(failure)) {
        phase = DraftSavePhase.offline;
        item.error = '上传失败';
        error = '图片上传失败，可点击重试';
      } else {
        item.error = spaceErrorText(failure);
        error = item.error;
      }
      _persist(dirty: true);
    } catch (failure) {
      item.error = '上传失败';
      phase = isSpaceOffline(failure)
          ? DraftSavePhase.offline
          : DraftSavePhase.failed;
      error = '图片上传失败，可点击重试';
      _persist(dirty: true);
    } finally {
      item.uploading = false;
      _notify();
    }
  }

  Future<void> removeImage(String imageId) async {
    if (phase == DraftSavePhase.conflict) {
      return;
    }
    _order.remove(imageId);
    _images.removeWhere((SpaceImage i) => i.imageId == imageId);
    _persist(dirty: true);
    _notify();
    await saveNow();
  }

  Future<void> moveImage(int from, int to) async {
    if (phase == DraftSavePhase.conflict) {
      return;
    }
    if (from < 0 || from >= _order.length || to < 0 || to >= _order.length) {
      return;
    }
    final String id = _order.removeAt(from);
    _order.insert(to, id);
    _images = <SpaceImage>[
      for (final String imageId in _order)
        _images.firstWhere((SpaceImage i) => i.imageId == imageId),
    ];
    _persist(dirty: true);
    _notify();
    await saveNow();
  }

  Future<void> moveImageBy(String imageId, int delta) async {
    final int index = _order.indexOf(imageId);
    if (index < 0) {
      return;
    }
    await moveImage(index, index + delta);
  }

  Future<bool> publish() async {
    final String? id = _id;
    final int? version = _version;
    if (id == null || version == null) {
      return false;
    }
    if (pending.isNotEmpty) {
      error = '还有图片没有上传完成，暂时不能发布';
      _notify();
      return false;
    }
    if (phase != DraftSavePhase.saved) {
      error = '请等待草稿保存完成再发布';
      _notify();
      return false;
    }
    if (text.text.trim().isEmpty && _images.isEmpty && !hasReference) {
      error = '写一点正文或添加一张图片后再发布';
      _notify();
      return false;
    }
    _debounce?.cancel();
    try {
      final SpaceOperation operation = await gateway.publishDraft(
        draftId: id,
        operationId: _opId,
        expectedVersion: version,
      );
      publishedPostId = operation.resourceId;
      store.deleteDraft(id);
      return publishedPostId != null;
    } on AuthFailure catch (failure) {
      error = spaceErrorText(failure);
      if (failure.code == 'version_conflict') {
        phase = DraftSavePhase.conflict;
      }
      _persist(dirty: true);
      _notify();
      return false;
    } catch (failure) {
      error = spaceErrorText(failure);
      _persist(dirty: true);
      _notify();
      return false;
    }
  }

  Future<bool> discard() async {
    final String? id = _id;
    final int? version = _version;
    if (id == null || version == null) {
      return false;
    }
    try {
      await gateway.deleteDraft(
        draftId: id,
        operationId: _opId,
        expectedVersion: version,
      );
      store.deleteDraft(id);
      final String? key = _localKey;
      if (key != null) {
        store.deleteDraft(key);
      }
      return true;
    } catch (failure) {
      error = spaceErrorText(failure);
      _notify();
      return false;
    }
  }

  String get statusLabel {
    switch (phase) {
      case DraftSavePhase.creating:
        return '正在创建草稿…';
      case DraftSavePhase.saving:
        return '保存中…';
      case DraftSavePhase.saved:
        return '已保存到服务器';
      case DraftSavePhase.dirty:
        return '有未保存的修改';
      case DraftSavePhase.conflict:
        return '草稿已在别处更新，本机修改未覆盖';
      case DraftSavePhase.offline:
        return '离线：仅保存在本机';
      case DraftSavePhase.failed:
        return '保存失败';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    text.dispose();
    super.dispose();
  }
}
