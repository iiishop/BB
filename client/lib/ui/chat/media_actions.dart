import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/chat_models.dart';
import '../../services/media_source.dart';

enum MediaPickKind { image, video, file }

typedef VideoCoverExtractorFn = Future<ResolvedMedia?> Function({
  String? path,
  required Uint8List bytes,
  required String filename,
});

Future<ResolvedMedia?> defaultVideoCoverExtractor({
  String? path,
  required Uint8List bytes,
  required String filename,
}) {
  return MediaActions.extractVideoCover(
    path: path,
    bytes: bytes,
    filename: filename,
  );
}

class PickedMedia {
  const PickedMedia({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    this.path,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;

  /// A real filesystem path when the platform picker or clipboard URI provides
  /// one. Bytes-only clipboard/file-URI reads leave this null and the cover
  /// extractor safely stages a temporary file.
  final String? path;
}

/// Platform file pickers, video covers and save locations.
class MediaActions {
  static const XTypeGroup _imageGroup = XTypeGroup(
    label: '图片',
    extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
  );

  static const MethodChannel _videoCoverChannel = MethodChannel(
    'bb/video_cover',
  );

  static Future<PickedMedia?> pick(MediaPickKind kind) async {
    final XTypeGroup? group = switch (kind) {
      MediaPickKind.image => _imageGroup,
      MediaPickKind.video => const XTypeGroup(
        label: '视频',
        extensions: <String>['mp4', 'webm'],
      ),
      MediaPickKind.file => null,
    };
    final XFile? file = await openFile(
      acceptedTypeGroups: group == null
          ? const <XTypeGroup>[]
          : <XTypeGroup>[group],
      confirmButtonText: '选择',
    );
    if (file == null) {
      return null;
    }
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }
    if (bytes.length > chatMaxUploadBytes) {
      throw const FormatException('文件超过 32 MiB 上限');
    }
    return PickedMedia(
      bytes: bytes,
      filename: file.name.isEmpty ? 'attachment' : file.name,
      mimeType: sniffMime(bytes, file.name),
      path: file.path.isEmpty ? null : file.path,
    );
  }

  static Future<String?> pickSaveLocation(String suggestedName) async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: sanitizeFilename(suggestedName),
      confirmButtonText: '保存',
    );
    return location?.path;
  }

  /// Extracts a real video frame. A path is used directly; bytes-only sources
  /// (clipboard, content URI, URL) are staged in a private temp file that is
  /// always removed. Null means no cover and the send must not proceed.
  static Future<ResolvedMedia?> extractVideoCover({
    String? path,
    required Uint8List bytes,
    required String filename,
  }) async {
    Directory? temporaryDirectory;
    String? source = path;
    try {
      if (source == null || source.isEmpty || !await File(source).exists()) {
        temporaryDirectory = await Directory.systemTemp.createTemp(
          'bb-video-cover-',
        );
        final File staged = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}'
          'source.${extensionForMime(sniffMime(bytes, filename))}',
        );
        await staged.writeAsBytes(bytes, flush: true);
        source = staged.path;
      }
      if (!kIsWeb && Platform.isAndroid) {
        try {
          final Uint8List? thumbnail = await _videoCoverChannel
              .invokeMethod<Uint8List>('extractVideoCover', <String, Object?>{
                'path': source,
              });
          if (thumbnail == null || thumbnail.isEmpty) {
            return null;
          }
          return ResolvedMedia(
            bytes: thumbnail,
            filename: '${_stem(filename)}-cover.png',
            mimeType: 'image/png',
          );
        } on PlatformException {
          return null;
        } on MissingPluginException {
          return null;
        }
      }
      return await FfmpegVideoCoverExtractor().extract(
        path: source,
        filename: filename,
      );
    } finally {
      if (temporaryDirectory != null) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } on FileSystemException {
          // Best-effort cleanup; the media bytes are never uploaded from here.
        }
      }
    }
  }

  static String _stem(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String extensionForMime(String mime) {
    return switch (mime) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'video/mp4' => 'mp4',
      'video/webm' => 'webm',
      _ => 'bin',
    };
  }

  static Future<void> openUrl(Uri uri) async {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', uri.toString()]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', <String>[uri.toString()]);
      return;
    }
    await Process.start('xdg-open', <String>[uri.toString()]);
  }

  static Future<void> openLocalPath(String path) async {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', <String>[path]);
      return;
    }
    await Process.start('xdg-open', <String>[path]);
  }
}
