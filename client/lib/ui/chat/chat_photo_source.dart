/// Adapts chat media to the shared photo contract.
///
/// Two behaviours the old chat-only viewer had get one owner here:
///
/// * the DEA-471 rule — an image over 100 KiB shows a bounded thumbnail until a
///   human asks for the original;
/// * the original, once downloaded, is written to the on-disk cache under
/// `chat-original|mediaId`, so reopening the viewer shows the original again
/// instead of falling back to the thumbnail.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../config/media_policy.dart';
import '../../models/chat_media.dart';
import '../../models/chat_models.dart';
import '../../services/chat_api_client.dart';
import '../../services/chat_service.dart';
import '../../services/media_disk_cache.dart';
import '../media/photo_source.dart';

class ChatPhotoSource implements PhotoSource {
  ChatPhotoSource({
    required this.item,
    required this.chat,
    this.heldBytes,
    this.disk,
  }) : _size = item.byteSize;

  final ChatMediaItem item;
  final ChatService chat;

  /// Bytes this account already holds for a picture it just sent, which skip
  /// both the network and the preview step.
  final Uint8List? heldBytes;

  /// Shared disk cache. Null in widget tests (there is no platform cache
  /// directory there), which simply means every open re-downloads.
  final MediaDiskCache? disk;

  int? _size;

  static String _originalKey(String mediaId) => 'chat-original|$mediaId';

  @override
  int? get byteSize => _size;

  @override
  Uint8List? get heldOriginal => heldBytes;

  /// Chat media ids are immutable once sent, so nothing can invalidate them.
  @override
  Listenable? get changes => null;

  @override
  bool get invalidated => false;

  @override
  Future<Uint8List?> readCachedOriginal() async {
    final MediaDiskCache? store = disk;
    if (store == null) {
      return null;
    }
    return store.read(_originalKey(item.mediaId));
  }

  @override
  Future<PhotoPreview> loadPreview() async {
    final int? size = await _resolveSize();
    final MediaPreview preview = await chat.loadMediaPreview(
      item.mediaId,
      thumbnail: size != null && mediaNeedsExplicitOriginal(size),
    );
    return PhotoPreview(
      bytes: preview.bytes,
      isDerivative: preview.isDerivative,
    );
  }

  @override
  Future<Uint8List> loadOriginal({PhotoProgress? onProgress}) async {
    final MediaResponse media = await chat.fetchOriginalMedia(
      item.mediaId,
      onProgress: onProgress,
    );
    _size = media.bytes.length;
    // Background write: the caller gets its bytes now, and a failed write only
    // costs a future re-download.
    final MediaDiskCache? store = disk;
    if (store != null) {
      unawaited(store.write(_originalKey(item.mediaId), media.bytes));
    }
    return media.bytes;
  }

  /// Historical body images carry no size, so it is probed once and remembered;
  /// a metadata failure is not fatal — the preview then just asks for the
  /// original bytes instead of guessing.
  Future<int?> _resolveSize() async {
    final int? known = _size;
    if (known != null) {
      return known;
    }
    try {
      final Attachment metadata = await chat.loadMediaMetadata(item.mediaId);
      _size = metadata.byteSize;
      return _size;
    } catch (_) {
      return null;
    }
  }
}
