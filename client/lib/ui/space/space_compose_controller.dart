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

  /// Version the upload receipt accepted. A later confirmation read may see a
  /// newer version written by someone else; that is a fence, not a new
  /// baseline for local input.
  int? confirmedVersion;

  /// Local image intent when the upload started. A confirmation retry must
  /// reconcile against this snapshot, not against whatever _order holds by
  /// then, or an image removed during the upload is treated as "no change".
  List<String> localOrderAtAdmission = <String>[];
  List<String> serverOrderAtAdmission = <String>[];
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

  /// Completed when the in-flight save settles, so publish can wait for it
  /// instead of losing the race for `expectedVersion`.
  Completer<void>? _saveIdle;
  bool _publishing = false;
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

  /// True whenever there is something to publish.
  ///
  /// A pending autosave is no longer a precondition: `publish` captures the
  /// screen state and syncs it itself, so blocking the button on `phase ==
  /// saved` only made the user wait for a timer they never asked for. Two
  /// states still block, because neither can be resolved by publishing:
  /// a conflict (another writer owns the draft) and a failed image upload.
  bool get canPublish =>
      !_publishing &&
      phase != DraftSavePhase.conflict &&
      !pending.any((PendingDraftImage p) => p.error != null) &&
      (text.text.trim().isNotEmpty ||
          _images.isNotEmpty ||
          pending.isNotEmpty ||
          hasReference);

  bool get canDiscard => _id != null && _version != null && !busy;

  /// True while a publish request is running, so the page can label the button.
  bool get publishing => _publishing;

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
          ? _resumeOrder(buffered!, draft)
          : List<String>.of(_serverOrder);
      _images = _imagesForOrder(draft.images, _order);
      final bool contentMatchesServer =
          !hasLocalEdit ||
          (buffered!.text == draft.text &&
              listEquals(buffered.imageIds, _serverOrder));
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

  /// Resumes a locally dirty image order without resurrecting images the user
  /// removed. Server images the buffer never saw (added on the same page or by
  /// the upload confirmation) are appended; a member the buffer knew but its
  /// local order dropped stays removed.
  List<String> _resumeOrder(SpaceDraftBuffer buffer, SpaceDraft draft) {
    final List<String> serverNow = draft.images
        .map((SpaceImage i) => i.imageId)
        .toList();
    final List<String> order = buffer.imageIds
        .where(serverNow.contains)
        .toList();
    for (final String id in serverNow) {
      if (!order.contains(id) && !buffer.serverImageIds.contains(id)) {
        order.add(id);
      }
    }
    return order;
  }

  List<SpaceImage> _imagesForOrder(
    List<SpaceImage> server,
    List<String> order,
  ) {
    return <SpaceImage>[
      for (final String id in order)
        for (final SpaceImage image in server)
          if (image.imageId == id) image,
    ];
  }

  /// Appends images the server gained since [serverBefore] without putting
  /// back an image the user removed locally while the upload was in flight.
  List<String> _mergeUploadOrder(
    List<String> local,
    List<String> serverBefore,
    List<SpaceImage> server,
  ) {
    final List<String> serverNow = server
        .map((SpaceImage i) => i.imageId)
        .toList();
    final List<String> order = local.where(serverNow.contains).toList();
    for (final String id in serverNow) {
      if (!serverBefore.contains(id) && !order.contains(id)) {
        order.add(id);
      }
    }
    return order;
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

  /// Persists the draft.
  ///
  /// [snapshotText] / [snapshotOrder] pin the payload. Publish passes the content
  /// the user had on screen when they tapped send, so anything typed while the
  /// request is in flight cannot change what gets published.
  Future<void> saveNow({
    String? snapshotText,
    List<String>? snapshotOrder,
  }) async {
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
    final String savedText = snapshotText ?? text.text;
    final List<String> savedOrder =
        snapshotOrder ?? List<String>.of(_order);
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
          text.text != savedText || !listEquals(_order, savedOrder);
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
        if (!localChanged) {
          _version = confirmed.version;
          _baselineVersion = confirmed.version;
          _order = List<String>.of(_serverOrder);
          _images = List<SpaceImage>.of(confirmed.images);
          text.text = confirmed.text;
          phase = DraftSavePhase.saved;
          error = null;
          _saveOpId = null;
          _saveSignature = null;
          _persist(dirty: false);
        } else if (confirmed.version == receiptVersion &&
            confirmed.text == savedText) {
          // Only local input (text or image membership/order) advanced while
          // the request was in flight. Keep the local intent untouched — an
          // older receipt must not restore a removed image — and save the
          // newer snapshot.
          _version = confirmed.version;
          _baselineVersion = confirmed.version;
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
      final Completer<void>? idle = _saveIdle;
      _saveIdle = null;
      idle?.complete();
      _notify();
    }
  }

  /// Waits while an autosave is in flight.
  ///
  /// Publish takes over the draft version, so it must not start writing until
  /// the current request has settled — two writers sharing one `expectedVersion`
  /// turn into a spurious 409.
  Future<void> _settleSave() async {
    if (!_saving) {
      return;
    }
    final Completer<void> idle = _saveIdle = Completer<void>();
    await idle.future.timeout(const Duration(seconds: 20), onTimeout: () {});
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
    final List<String> localOrder = List<String>.of(
      item.localOrderAtAdmission,
    );
    final List<String> serverBefore = List<String>.of(
      item.serverOrderAtAdmission,
    );
    item.uploading = true;
    _notify();
    try {
      final SpaceDraft draft = await gateway.getDraft(id);
      _version = draft.version;
      _serverText = draft.text;
      _serverOrder = draft.images.map((SpaceImage i) => i.imageId).toList();
      pending.remove(item);
      _reconcileAfterUpload(
        draft: draft,
        localOrder: localOrder,
        serverBefore: serverBefore,
        receiptVersion: item.confirmedVersion,
      );
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

  /// Reconciles the confirmed draft after an upload without discarding local
  /// intent: text that was already dirty before the upload stays, an image the
  /// user removed or reordered meanwhile stays removed/reordered, and only
  /// genuinely new server images are appended.
  void _reconcileAfterUpload({
    required SpaceDraft draft,
    required List<String> localOrder,
    required List<String> serverBefore,
    int? receiptVersion,
  }) {
    final List<String> serverNow = draft.images
        .map((SpaceImage i) => i.imageId)
        .toList();
    final List<String> intentOrder = _mergeUploadOrder(
      _order,
      serverBefore,
      draft.images,
    );
    final bool advanced =
        receiptVersion != null && draft.version > receiptVersion;
    final bool localMatchesServer =
        text.text == draft.text && listEquals(intentOrder, serverNow);
    if (advanced && !localMatchesServer) {
      // The upload receipt accepted one version; a confirmation read that sees
      // a newer version means another writer committed afterwards. Adopting it
      // as the local baseline would let the next autosave overwrite them.
      _order = intentOrder;
      _images = _imagesForOrder(draft.images, _order);
      _version = draft.version;
      _baselineVersion = receiptVersion;
      phase = DraftSavePhase.conflict;
      error = '草稿已在别处更新；本机输入已保留，不会被覆盖';
      _persist(dirty: true);
      return;
    }
    final bool textDirty = text.text != draft.text;
    final bool orderChanged = !listEquals(_order, localOrder);
    if (!textDirty && !orderChanged) {
      _order = List<String>.of(_serverOrder);
      _images = List<SpaceImage>.of(draft.images);
      text.text = draft.text;
      if (phase != DraftSavePhase.conflict) {
        _baselineVersion = draft.version;
        phase = DraftSavePhase.saved;
      }
      error = null;
      _persist(dirty: phase != DraftSavePhase.saved);
      return;
    }
    _order = orderChanged
        ? _mergeUploadOrder(_order, serverBefore, draft.images)
        : List<String>.of(_serverOrder);
    _images = _imagesForOrder(draft.images, _order);
    if (phase != DraftSavePhase.conflict) {
      _baselineVersion = draft.version;
      phase = DraftSavePhase.dirty;
      _scheduleSave();
    }
    _persist(dirty: true);
  }

  Future<void> _upload(PendingDraftImage item) async {
    final String? id = _id;
    final int? version = _version;
    if (id == null || version == null) {
      item.error = '草稿尚未创建';
      _notify();
      return;
    }
    final List<String> localOrder = List<String>.of(_order);
    final List<String> serverBefore = List<String>.of(_serverOrder);
    item.localOrderAtAdmission = List<String>.of(_order);
    item.serverOrderAtAdmission = List<String>.of(_serverOrder);
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
      final int receiptVersion = operation.resourceVersion ?? version;
      _version = receiptVersion;
      item.uploaded = true;
      item.confirmedVersion = receiptVersion;
      final SpaceDraft draft = await gateway.getDraft(id);
      _version = draft.version;
      _serverText = draft.text;
      _serverOrder = draft.images.map((SpaceImage i) => i.imageId).toList();
      pending.remove(item);
      _reconcileAfterUpload(
        draft: draft,
        localOrder: localOrder,
        serverBefore: serverBefore,
        receiptVersion: receiptVersion,
      );
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

  /// Publishes whatever is on screen at the moment of the tap.
  ///
  /// The content is captured on entry, so a pending autosave or a keystroke
  /// landing mid-request can neither block the tap nor change what goes out:
  /// publish waits for the in-flight write, syncs the draft to this snapshot,
  /// and only then asks the server to publish. Images are the one exception —
  /// they must exist server-side before a post can reference them.
  Future<bool> publish() async {
    if (_publishing) {
      return false;
    }
    final String snapshotText = text.text;
    final List<String> snapshotOrder = List<String>.of(_order);
    if (snapshotText.trim().isEmpty &&
        snapshotOrder.isEmpty &&
        pending.isEmpty &&
        !hasReference) {
      error = '写一点正文或添加一张图片后再发布';
      _notify();
      return false;
    }
    _publishing = true;
    // A scheduled autosave would race this request for `expectedVersion`.
    _debounce?.cancel();
    publishError = null;
    _notify();
    try {
      if (_id == null) {
        await start();
      }
      if (_id == null || _disposed || _discarded) {
        return false;
      }
      await _awaitUploads();
      if (pending.any((PendingDraftImage p) => p.error != null)) {
        error = '有图片上传失败，请重试或移除后再发布';
        _notify();
        return false;
      }
      await _settleSave();
      if (_serverText != snapshotText ||
          !listEquals(_serverOrder, snapshotOrder)) {
        await saveNow(
          snapshotText: snapshotText,
          snapshotOrder: snapshotOrder,
        );
      }
      final int? version = _version;
      final bool synced =
          _serverText == snapshotText &&
          listEquals(_serverOrder, snapshotOrder);
      if (version == null || !synced) {
        // The save failed or another writer moved the draft. Surface the phase
        // the save left behind rather than publishing stale content.
        error ??= '草稿尚未同步，请重试';
        _notify();
        return false;
      }
      if (_publishOpId == null || _publishVersion != version) {
        _publishOpId = _opId;
        _publishVersion = version;
      }
      final SpaceOperation operation = await gateway.publishDraft(
        draftId: _id!,
        operationId: _publishOpId!,
        expectedVersion: version,
      );
      publishedPostId = operation.resourceId;
      _publishOpId = null;
      _publishVersion = null;
      publishError = null;
      store.deleteDraft(_id!);
      return publishedPostId != null;
    } on AuthFailure catch (failure) {
      publishError = spaceErrorText(failure);
      if (failure.code == 'version_conflict') {
        phase = DraftSavePhase.conflict;
      }
      _persist(dirty: true);
      return false;
    } catch (failure) {
      publishError = spaceErrorText(failure);
      _persist(dirty: true);
      return false;
    } finally {
      _publishing = false;
      _notify();
    }
  }

  /// Waits for queued image uploads.
  ///
  /// A post can only reference media the server already stored, so these cannot
  /// be skipped the way a text save can.
  Future<void> _awaitUploads() async {
    const int ticks = 1200; // 60s at 50ms
    for (int i = 0; i < ticks; i++) {
      if (_disposed || !pending.any((PendingDraftImage p) => p.uploading)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
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
