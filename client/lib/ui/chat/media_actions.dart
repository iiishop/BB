import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../models/chat_models.dart';
import '../../services/media_source.dart';

enum MediaPickKind { image, video, file }

class PickedMedia {
  const PickedMedia({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;
}

/// Platform file pickers and clipboard access used by the Flutter composer.
///
/// File selection and save locations use the official `file_selector` plugin.
/// Clipboard image reads are best effort on Linux; an unavailable tool is
/// surfaced as "not supported", never as a fake success.
class MediaActions {
  static const XTypeGroup _imageGroup = XTypeGroup(
    label: '图片',
    extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
  );

  static const XTypeGroup _videoGroup = XTypeGroup(
    label: '视频',
    extensions: <String>['mp4', 'webm'],
  );

  static Future<PickedMedia?> pick(MediaPickKind kind) async {
    final XTypeGroup? group = switch (kind) {
      MediaPickKind.image => _imageGroup,
      MediaPickKind.video => _videoGroup,
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
    );
  }

  static Future<String?> pickSaveLocation(String suggestedName) async {
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: sanitizeFilename(suggestedName),
      confirmButtonText: '保存',
    );
    return location?.path;
  }

  /// Best-effort image clipboard read for Linux desktops.
  ///
  /// Android/iOS are NOT RUN for paste because Flutter's clipboard channel only
  /// exposes text; the UI reports the limitation instead of pretending.
  static Future<PickedMedia?> readClipboardImage() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return null;
    }
    final List<List<String>> candidates = <List<String>>[
      <String>['wl-paste', '--no-newline', '--type', 'image/png'],
      <String>['xclip', '-selection', 'clipboard', '-t', 'image/png', '-o'],
      <String>['xsel', '--clipboard', '--output'],
    ];
    for (final List<String> command in candidates) {
      try {
        final ProcessResult result = await Process.run(
          command.first,
          command.sublist(1),
          stdoutEncoding: null,
          stderrEncoding: null,
        );
        if (result.exitCode != 0) {
          continue;
        }
        final Object? raw = result.stdout;
        final Uint8List bytes = raw is Uint8List
            ? raw
            : Uint8List.fromList((raw as List<int>?) ?? const <int>[]);
        if (bytes.isEmpty) {
          continue;
        }
        final String mime = sniffMime(bytes);
        if (!mime.startsWith('image/')) {
          continue;
        }
        return PickedMedia(
          bytes: bytes,
          filename:
              'clipboard-${DateTime.now().millisecondsSinceEpoch}'
              '.${mime == 'image/png' ? 'png' : 'jpg'}',
          mimeType: mime,
        );
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  /// Extracts a real video frame. Desktop uses ffmpeg; Android uses the
  /// platform thumbnailer. Null means no cover and the send must not proceed.
  static Future<ResolvedMedia?> extractVideoCover({
    String? path,
    required Uint8List bytes,
    required String filename,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      if (path == null) {
        return null;
      }
      try {
        final Uint8List? thumbnail = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.PNG,
          maxWidth: 720,
          quality: 80,
        );
        if (thumbnail == null || thumbnail.isEmpty) {
          return null;
        }
        return ResolvedMedia(
          bytes: thumbnail,
          filename: '${_stem(filename)}-cover.png',
          mimeType: 'image/png',
        );
      } catch (_) {
        return null;
      }
    }
    if (path == null) {
      return null;
    }
    return FfmpegVideoCoverExtractor().extract(path: path, filename: filename);
  }

  static String _stem(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
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
