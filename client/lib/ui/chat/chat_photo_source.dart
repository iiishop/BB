/// Adapts chat media to the shared photo contract.
///
/// Handles:
/// * the DEA-471 rule — an image over 100 KiB shows a bounded thumbnail until a
///   human asks for the original;
/// * conversation-scoped original caching (`chat-original-<scopeTag>|<mediaId>`
///   when conversation scope is known, or `chat-original|<mediaId>` otherwise);
/// * immediate invalidation and disk eviction when group membership is revoked,
///   a group is dissolved, or the server rejects media access (403/404).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../config/media_policy.dart';
import '../../models/auth_models.dart';
import '../../models/chat_media.dart';
import '../../models/chat_models.dart';
import '../../services/chat_api_client.dart';
import '../../services/chat_service.dart';
import '../../services/conversation_access.dart';
import '../../services/media_disk_cache.dart';
import '../media/photo_source.dart';

class ChatPhotoSource implements PhotoSource {
  ChatPhotoSource({
    required this.item,
    required this.chat,
    this.heldBytes,
    this.disk,
    this.account,
    ConversationRef? conversation,
    this.access,
    this.onAccessInvalidated,
  }) : conversation =
           conversation ?? item.conversation ?? item.message.conversation,
       _size = item.byteSize {
    final String? acct = _effectiveAccount;
    final ConversationRef? conv = this.conversation;
    if (access != null && acct != null && conv != null) {
      _capturedEpoch = access!.epochFor(acct, conv.id);
      access!.registerMedia(acct, conv.id, item.mediaId);
      _accessListener = _handleAccessChanged;
      access!.addListener(_accessListener!);
    }
  }

  final ChatMediaItem item;
  final ChatService chat;

  /// Bytes this account already holds for a picture it just sent, which skip
  /// both the network and the preview step.
  final Uint8List? heldBytes;

  /// Shared disk cache. Null in widget tests (there is no platform cache
  /// directory there), which simply means every open re-downloads.
  final MediaDiskCache? disk;

  /// Optional account + conversation + access registry for group revocation.
  final String? account;
  final ConversationRef? conversation;
  final ConversationAccessController? access;
  final VoidCallback? onAccessInvalidated;

  final _SourceNotifier _changes = _SourceNotifier();
  int? _size;
  int _capturedEpoch = 0;
  bool _locallyInvalidated = false;
  void Function()? _accessListener;

  String? get _effectiveAccount {
    if (account != null && account!.isNotEmpty) {
      return account;
    }
    return chat.session.identity?.account;
  }

  String get diskKey {
    final String? acct = _effectiveAccount;
    final ConversationRef? conv = conversation;
    if (acct != null && acct.isNotEmpty && conv != null) {
      final String tag = ConversationAccessController.diskScopeTag(
        server: chat.api.baseUri.toString(),
        account: acct,
        conversationId: conv.id,
      );
      return 'chat-original-$tag|${item.mediaId}';
    }
    return 'chat-original|${item.mediaId}';
  }

  void _handleAccessChanged() {
    if (invalidated) {
      unawaited(_purgeDisk());
      _changes.notify();
    }
  }

  Future<void> _purgeDisk() async {
    final MediaDiskCache? store = disk;
    if (store != null) {
      await store.delete(diskKey);
    }
  }

  void _invalidateLocally() {
    if (!_locallyInvalidated) {
      _locallyInvalidated = true;
      unawaited(_purgeDisk());
      onAccessInvalidated?.call();
      _changes.notify();
    }
  }

  void dispose() {
    final void Function()? listener = _accessListener;
    if (listener != null) {
      access?.removeListener(listener);
      _accessListener = null;
    }
    _changes.dispose();
  }

  @override
  int? get byteSize => _size;

  @override
  Uint8List? get heldOriginal => invalidated ? null : heldBytes;

  @override
  Listenable? get changes => _changes;

  @override
  bool get invalidated {
    if (_locallyInvalidated) {
      return true;
    }
    final String? acct = _effectiveAccount;
    final ConversationRef? conv = conversation;
    if (access != null && acct != null && conv != null) {
      return access!.isStale(acct, conv.id, _capturedEpoch);
    }
    return false;
  }

  @override
  Future<Uint8List?> readCachedOriginal() async {
    if (invalidated) {
      await _purgeDisk();
      return null;
    }
    final MediaDiskCache? store = disk;
    if (store == null) {
      return null;
    }
    return store.read(diskKey);
  }

  @override
  Future<PhotoPreview> loadPreview() async {
    if (invalidated) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '无权访问该媒体',
      );
    }
    try {
      final int? size = await _resolveSize();
      final MediaPreview preview = await chat.loadMediaPreview(
        item.mediaId,
        thumbnail: size != null && mediaNeedsExplicitOriginal(size),
      );
      if (invalidated) {
        throw const AuthFailure(
          status: 403,
          code: 'forbidden',
          message: '无权访问该媒体',
        );
      }
      return PhotoPreview(
        bytes: preview.bytes,
        isDerivative: preview.isDerivative,
      );
    } on AuthFailure catch (failure) {
      if (failure.status == 403 || failure.status == 404) {
        _invalidateLocally();
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List> loadOriginal({PhotoProgress? onProgress}) async {
    if (invalidated) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '无权访问该媒体',
      );
    }
    try {
      final MediaResponse media = await chat.fetchOriginalMedia(
        item.mediaId,
        onProgress: onProgress,
      );
      if (invalidated) {
        throw const AuthFailure(
          status: 403,
          code: 'forbidden',
          message: '无权访问该媒体',
        );
      }
      _size = media.bytes.length;
      final MediaDiskCache? store = disk;
      if (store != null) {
        unawaited(store.write(diskKey, media.bytes));
      }
      return media.bytes;
    } on AuthFailure catch (failure) {
      if (failure.status == 403 || failure.status == 404) {
        _invalidateLocally();
      }
      rethrow;
    }
  }

  Future<int?> _resolveSize() async {
    final int? known = _size;
    if (known != null) {
      return known;
    }
    try {
      final Attachment metadata = await chat.loadMediaMetadata(item.mediaId);
      _size = metadata.byteSize;
      return _size;
    } on AuthFailure catch (failure) {
      if (failure.status == 403 || failure.status == 404) {
        _invalidateLocally();
        rethrow;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

class _SourceNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
