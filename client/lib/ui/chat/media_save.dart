/// Platform-specific "save media" paths (DEA-471).
///
/// Android saves into the system gallery through MediaStore; iOS reserves the
/// Photos channel but has no runner in this project; Linux/Windows keep the
/// existing `getSaveLocation` file dialog. The two flows are deliberately
/// separate: a gallery insert cannot be expressed as a filesystem path.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/auth_models.dart';
import '../../models/chat_media.dart';
import '../../models/chat_models.dart';
import '../../services/chat_api_client.dart';
import '../../services/chat_service.dart';
import '../../services/media_source.dart';
import 'media_actions.dart';

/// Location reported by the platform after a successful gallery insert.
class GallerySaveOutcome {
  const GallerySaveOutcome({required this.location});

  /// Human-readable album path, e.g. `Pictures/BB/bb_20261114_101500_photo.jpg`.
  final String location;
}

/// A platform gallery (Android MediaStore, iOS Photos).
abstract interface class GallerySaver {
  bool get isSupported;

  Future<GallerySaveOutcome> save({
    required String path,
    required String filename,
    required String mimeType,
    required bool isVideo,
  });
}

/// Method-channel implementation. Native code owns permissions, MediaStore
/// insertion, naming and rollback; Dart never writes to a gallery path.
class PlatformGallerySaver implements GallerySaver {
  const PlatformGallerySaver();

  static const MethodChannel channel = MethodChannel('bb/media_gallery');

  @override
  bool get isSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Future<GallerySaveOutcome> save({
    required String path,
    required String filename,
    required String mimeType,
    required bool isVideo,
  }) async {
    final String method = Platform.isIOS ? 'saveToPhotos' : 'saveToGallery';
    try {
      final String? location = await channel.invokeMethod<String>(method, {
        'path': path,
        'filename': filename,
        'mime_type': mimeType,
        'is_video': isVideo,
      });
      if (location == null || location.trim().isEmpty) {
        throw PlatformException(code: 'save_failed', message: '相册没有返回保存位置');
      }
      return GallerySaveOutcome(location: location);
    } on MissingPluginException {
      throw PlatformException(code: 'unsupported', message: '当前构建未包含相册保存');
    }
  }
}

enum MediaSaveStatus { saved, cancelled, failed }

class MediaSaveResult {
  const MediaSaveResult({required this.status, this.message = ''});

  final MediaSaveStatus status;
  final String message;
}

typedef SaveLocationPicker = Future<String?> Function(String suggestedName);

/// Bytes already written to a private staging file plus its cleanup handle.
class GalleryStagedFile {
  const GalleryStagedFile({required this.path, required this.cleanup});

  final String path;
  final Future<void> Function() cleanup;
}

typedef GalleryFileStager = Future<GalleryStagedFile> Function(
  Uint8List bytes,
  String filename,
);

/// Chooses gallery versus save-dialog and reports where the file landed.
class MediaSaveService {
  MediaSaveService({
    required this.chat,
    this.gallery = const PlatformGallerySaver(),
    SaveLocationPicker? pickSaveLocation,
    GalleryFileStager? stageGalleryFile,
  }) : _pickSaveLocation = pickSaveLocation ?? MediaActions.pickSaveLocation,
       _stageGalleryFile = stageGalleryFile ?? _stageInSystemTemp;

  final ChatService chat;
  final GallerySaver gallery;
  final SaveLocationPicker _pickSaveLocation;
  final GalleryFileStager _stageGalleryFile;

  Future<MediaSaveResult> save(
    ChatMediaItem item, {
    void Function(int received, int? total)? onProgress,
  }) async {
    try {
      final _ResolvedSaveMedia resolved = await _resolve(item);
      if (gallery.isSupported) {
        return await _saveToGallery(item, resolved, onProgress);
      }
      final String? target = await _pickSaveLocation(resolved.filename);
      if (target == null || target.trim().isEmpty) {
        return const MediaSaveResult(status: MediaSaveStatus.cancelled);
      }
      final String saved = await chat.saveAs(
        mediaId: item.mediaId,
        targetPath: target,
      );
      return MediaSaveResult(
        status: MediaSaveStatus.saved,
        message: '已保存到 $saved',
      );
    } on AuthFailure catch (failure) {
      return MediaSaveResult(
        status: MediaSaveStatus.failed,
        message: failure.message,
      );
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') {
        return const MediaSaveResult(status: MediaSaveStatus.cancelled);
      }
      return MediaSaveResult(
        status: MediaSaveStatus.failed,
        message: _platformMessage(error),
      );
    } on FileSystemException {
      return const MediaSaveResult(
        status: MediaSaveStatus.failed,
        message: '保存失败：无法写入目标位置',
      );
    } catch (_) {
      return const MediaSaveResult(
        status: MediaSaveStatus.failed,
        message: '保存失败，请重试',
      );
    }
  }

  Future<MediaSaveResult> _saveToGallery(
    ChatMediaItem item,
    _ResolvedSaveMedia resolved,
    void Function(int received, int? total)? onProgress,
  ) async {
    final MediaResponse media = await chat.fetchOriginalMedia(
      item.mediaId,
      onProgress: onProgress,
    );
    final GalleryStagedFile staged = await _stageGalleryFile(
      media.bytes,
      resolved.filename,
    );
    try {
      final GallerySaveOutcome outcome = await gallery.save(
        path: staged.path,
        filename: resolved.filename,
        mimeType: resolved.mimeType,
        isVideo: resolved.isVideo,
      );
      return MediaSaveResult(
        status: MediaSaveStatus.saved,
        message: '已保存到相册 ${outcome.location}',
      );
    } finally {
      await staged.cleanup();
    }
  }

  /// Default stager: a private temp file outside the media caches. Kept behind
  /// a seam so widget tests never touch real disk I/O.
  static Future<GalleryStagedFile> _stageInSystemTemp(
    Uint8List bytes,
    String filename,
  ) async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'bb-gallery-',
    );
    final File staged = File(
      '${directory.path}${Platform.pathSeparator}'
      '${sanitizeFilename(filename)}',
    );
    await staged.writeAsBytes(bytes, flush: true);
    return GalleryStagedFile(
      path: staged.path,
      cleanup: () async {
        try {
          if (await staged.exists()) {
            await staged.delete();
          }
        } on FileSystemException {
          // The gallery already has its own copy; a stale temp file is
          // harmless and the OS clears its own temp directory.
        }
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } on FileSystemException {
          // Best effort.
        }
      },
    );
  }

  Future<_ResolvedSaveMedia> _resolve(ChatMediaItem item) async {
    String? filename = item.filename;
    String? mimeType = item.mimeType;
    if (filename == null || mimeType == null) {
      final Attachment metadata = await chat.loadMediaMetadata(item.mediaId);
      filename ??= metadata.filename;
      mimeType ??= metadata.mimeType;
    }
    final bool isVideo = item.isVideo;
    final String resolvedMime = mimeType;
    final String resolvedFilename = filename;
    final String safe = sanitizeFilename(resolvedFilename);
    final String withExtension = safe.contains('.')
        ? safe
        : '$safe.${_extensionForMime(resolvedMime)}';
    return _ResolvedSaveMedia(
      filename: withExtension,
      mimeType: resolvedMime,
      isVideo: isVideo,
    );
  }

  static String _platformMessage(PlatformException error) {
    return switch (error.code) {
      'permission_denied' => '保存失败：没有相册写入权限',
      'cancelled' => '已取消保存',
      'unsupported' => '当前平台暂不支持保存到相册',
      'file_missing' => '保存失败：下载文件已不存在',
      _ => '保存失败，请重试',
    };
  }
}

class _ResolvedSaveMedia {
  const _ResolvedSaveMedia({
    required this.filename,
    required this.mimeType,
    required this.isVideo,
  });

  final String filename;
  final String mimeType;
  final bool isVideo;
}

String _extensionForMime(String mime) {
  return switch (mime) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    _ => 'bin',
  };
}
