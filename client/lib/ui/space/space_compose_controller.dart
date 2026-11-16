import 'dart:async';
import 'dart:convert';

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
  PendingDraftImage({
    required this.filename,
    required this.bytes,
    required this.operationId,
  });

  final String filename;
  final Uint8List bytes;
  final String operationId;
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
  String? publishError;
  String? publishedPostId;
  SpacePost? reference;

  String? _id;
  int? _version;
  String _serverText = '';
  List<SpaceImage> _images = <SpaceImage>[];
  /// Server image order (facts), kept apart from the local [_order].
  List<String> _serverOrder = <String>[];
  /// Server version the local unsynced buffer is based on. A save may never
  /// replay that buffer against a newer version adopted from another client.
  int? _baselineVersion;
  List<String> _order = <String>[];
  final List<PendingDraftImage> pending = <PendingDraftImage>[];
  String? _localKey;
  Timer? _debounce;
  bool _saving = false;
  int _counter = 0;
  bool _disposed = false;
  bool _discarded = false;
  String? _createOpId;
  String? _saveOpId;
  String? _saveSignature;
  String? _publishOpId;
  int? _publishVersion;
  String? _discardOpId;
  int? _discardVersion;

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
      text.text == _serverText &&
      _sameOrder(_order, _serverOrder) &&
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
        _createOpId ??= _opId;
        final SpaceOperation created = await gateway.createDraft(
          operationId: _createOpId!,
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
      _serverOrder = draft.images.map((SpaceImage i) => i.imageId).toList();
      if (local != null && _localKey != draft.draftId) {
        store.deleteDraft(_localKey!);
        store.saveDraft(draft.draftId, local);
      }
      _localKey = draft.draftId;
      final SpaceDraftBuffer? buffered = store.draft(draft.draftId);
      final bool hasLocalEdit = buffered?.dirty == true;
      text.text = hasLocalEdit ? buffered!.text : draft.text;
      _order = hasLocalEdit
          ? _mergeOrder(buffered!.imageIds, draft.images)
          : List<String>.of(_serverOrder);
      final bool contentMatchesServer =
          !hasLocalEdit ||
          (buffered!.text == draft.text &&
              _sameOrder(buffered.imageIds, _serverOrder));
      if (contentMatchesServer) {
        _baselineVersion = draft.version;
        phase = DraftSavePhase.saved;
        _persist(dirty: false);
      } else {
        // The buffer remembers the version it was written against. If the
        // server moved past it, replaying the old input would silently
        // overwrite the other writer, so surface the conflict instead.
        final int base = buffered.version ?? draft.version;
        _baselineVersion = base;
        if (base != draft.version) {
          phase = DraftSavePhase.conflict;
          error = '草稿已在别处更新；本机输入已保留，不会被覆盖';
        } else {
          phase = DraftSavePhase.dirty;
        }
        _persist(dirty: true);
      }
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

  bool _sameOrder(List<String> preferred, List<String> server) {
    final List<String> merged = <String>[
      ...preferred.where(server.contains),
      ...server.where((String id) => !preferred.contains(id)),
    ];
    if (merged.length != server.length) {
      return false;
    }
    for (int i = 0; i < merged.length; i++) {
      if (merged[i] != server[i]) {
        return false;
      }
    }
    return true;
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
    if (_discarded) {
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(saveNow());
    });
  }

  /// Retry the step that failed: draft creation has no version yet, otherwise
  /// the current unsynced edit is retried with its retained operation ID.
  Future<void> retry() async {
    if (_id == null) {
      await start();
    } else {
      await saveNow();
    }
  }

  Future<void> saveNow() async {
    final String? id = _id;
    final int? version = _version;
    if (id == null ||
        version == null ||
        _saving ||
        _disposed ||
        _discarded) {
      return;
    }
    if (phase == DraftSavePhase.conflict) {
      return;
    }
    _saving = true;
    phase = DraftSavePhase.saving;
    // Snapshot the exact payload this request sends. The response describes
    // that snapshot, never whatever the user typed while it was in flight.
    final String savedText = text.text;
    final List<String> savedOrder = List<String>.of(_order);
    final String signature = jsonEncode(<Object?>[
      id,
      version,
      savedText,
      savedOrder,
    ]);
    if (_saveSignature != signature) {
      _saveSignature = signature;
      _saveOpId = _opId;
    }
    _notify();
    try {
      final SpaceOperation operation = await gateway.updateDraft(
        draftId: id,
        operationId: _saveOpId!,
        expectedVersion: version,
        text: savedText,
        referenceId: referenceId,
        imageIds: savedOrder,
      );
      final int receiptVersion = operation.resourceVersion ?? version;
      _version = receiptVersion;
      SpaceDraft? confirmed;
      // The receipt carries identity/version only; re-read the draft to keep
      // displayed facts on the server's copy.
      try {
        confirmed = await gateway.getDraft(id);
      } catch (_) {
        // The mutation already committed; a failed confirmation read must not
        // present the save as failed.
      }
      final bool localChanged =
          text.text != savedText || !_sameOrder(_order, savedOrder);
      if (confirmed == null) {
        _serverText = savedText;
        _serverOrder = List<String>.of(savedOrder);
        if (localChanged) {
          _version = receiptVersion;
          _baselineVersion = receiptVersion;
          phase = DraftSavePhase.dirty;
          _persist(dirty: true);
          _scheduleSave();
        } else {
          _version = receiptVersion;
          _baselineVersion = receiptVersion;
          phase = DraftSavePhase.saved;
          error = null;
          _saveOpId = null;
          _saveSignature = null;
          _persist(dirty: false);
        }
      } else {
        _serverText = confirmed.text;
        _serverOrder = confirmed.images
            .map((SpaceImage i) => i.imageId)
            .toList();
        _images = List<SpaceImage>.of(confirmed.images);
        if (!localChanged) {
          _version = confirmed.version;
          _baselineVersion = confirmed.version;
          _order = List<String>.of(_serverOrder);
          text.text = confirmed.text;
          phase = DraftSavePhase.saved;
          error = null;
          _saveOpId = null;
          _saveSignature = null;
          _persist(dirty: false);
        } else if (confirmed.version == receiptVersion &&
            confirmed.text == savedText) {
          // Only local input advanced while the request was in flight. Keep
          // it dirty and save the newer snapshot; never label it saved.
          _version = confirmed.version;
          _baselineVersion = confirmed.version;
          _order = _mergeOrder(_order, confirmed.images);
          phase = DraftSavePhase.dirty;
          error = null;
          _persist(dirty: true);
          _scheduleSave();
        } else {
          // Another writer advanced the draft while this save was in flight.
          _version = confirmed.version;
          _baselineVersion = receiptVersion;
          phase = DraftSavePhase.conflict;
          error = '草稿已在别处更新；本机输入已保留，不会被覆盖';
          _persist(dirty: true);
        }
      }
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
      _baselineVersion = draft.version;
      _serverText = draft.text;
      _images = List<SpaceImage>.of(draft.images);
      _serverOrder = draft.images.map((SpaceImage i) => i.imageId).toList();
      _order = List<String>.of(_serverOrder);
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
    if (_discarded) {
      return;
    }
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
        serverImageIds: List<String>.of(_serverOrder),
        dirty: dirty,
        version: _baselineVersion ?? _version,
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
      operationId: _opId,
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
    final String localText = text.text;
    final List<String> localOrder = List<String>.of(_order);
    item.uploading = true;
    _notify();
    try {
      final SpaceDraft draft = await gateway.getDraft(id);
      _version = draft.version;
      _serverText = draft.text;
      _serverOrder = draft.images.map((SpaceImage i) => i.imageId).toList();
      _images = List<SpaceImage>.of(draft.images);
      pending.remove(item);
      final bool localChanged =
          text.text != localText || !_sameOrder(_order, localOrder);
      if (!localChanged) {
        _order = List<String>.of(_serverOrder);
        text.text = draft.text;
        if (phase != DraftSavePhase.conflict) {
          _baselineVersion = draft.version;
          phase = DraftSavePhase.saved;
        }
        error = null;
        _persist(dirty: phase != DraftSavePhase.saved);
      } else {
        _order = _mergeOrder(_order, draft.images);
        if (phase != DraftSavePhase.conflict) {
          _baselineVersion = draft.version;
          phase = DraftSavePhase.dirty;
          _scheduleSave();
        }
        _persist(dirty: true);
      }
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
    final String localText = text.text;
    final List<String> localOrder = List<String>.of(_order);
    item.uploading = true;
    item.error = null;
    _notify();
    try {
      final SpaceOperation operation = await gateway.addImage(
        draftId: id,
        operationId: item.operationId,
        expectedVersion: version,
        filename: item.filename,
        bytes: item.bytes,
      );
      _version = operation.resourceVersion ?? version;
      item.uploaded = true;
      final SpaceDraft draft = await gateway.getDraft(id);
      _images = List<SpaceImage>.of(draft.images);
      _serverText = draft.text;
      _serverOrder = draft.images.map((SpaceImage i) => i.imageId).toList();
      _version = draft.version;
      pending.remove(item);
      final bool localChanged =
          text.text != localText || !_sameOrder(_order, localOrder);
      if (!localChanged) {
        _order = List<String>.of(_serverOrder);
        text.text = draft.text;
        if (phase != DraftSavePhase.conflict) {
          _baselineVersion = draft.version;
          phase = DraftSavePhase.saved;
        }
        error = null;
        _persist(dirty: phase != DraftSavePhase.saved);
      } else {
        // The upload response must not mark text/order the user changed while
        // it was in flight as saved; merge the new image and save again.
        _order = _mergeOrder(_order, draft.images);
        if (phase != DraftSavePhase.conflict) {
          _baselineVersion = draft.version;
          phase = DraftSavePhase.dirty;
          _scheduleSave();
        }
        _persist(dirty: true);
      }
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
    if (text.text != _serverText || !_sameOrder(_order, _serverOrder)) {
      // Defensive: a saved phase must never pair with unsynced content.
      phase = DraftSavePhase.dirty;
      error = '请等待草稿保存完成再发布';
      _persist(dirty: true);
      _scheduleSave();
      _notify();
      return false;
    }
    if (text.text.trim().isEmpty && _images.isEmpty && !hasReference) {
      error = '写一点正文或添加一张图片后再发布';
      _notify();
      return false;
    }
    _debounce?.cancel();
    if (_publishOpId == null || _publishVersion != version) {
      _publishOpId = _opId;
      _publishVersion = version;
    }
    try {
      final SpaceOperation operation = await gateway.publishDraft(
        draftId: id,
        operationId: _publishOpId!,
        expectedVersion: version,
      );
      publishedPostId = operation.resourceId;
      _publishOpId = null;
      _publishVersion = null;
      publishError = null;
      store.deleteDraft(id);
      return publishedPostId != null;
    } on AuthFailure catch (failure) {
      publishError = spaceErrorText(failure);
      if (failure.code == 'version_conflict') {
        phase = DraftSavePhase.conflict;
      }
      _persist(dirty: true);
      _notify();
      return false;
    } catch (failure) {
      publishError = spaceErrorText(failure);
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
    if (_discardOpId == null || _discardVersion != version) {
      _discardOpId = _opId;
      _discardVersion = version;
    }
    try {
      await gateway.deleteDraft(
        draftId: id,
        operationId: _discardOpId!,
        expectedVersion: version,
      );
      // A debounce/retry that resolves after deletion must not resurrect the
      // local buffer of a draft the user explicitly discarded.
      _discarded = true;
      _debounce?.cancel();
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
