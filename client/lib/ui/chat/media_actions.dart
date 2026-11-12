import 'dart:async';
import 'dart:convert';
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

/// Clipboard media read seam used by the composer and its widget tests.
abstract interface class ClipboardMediaReader {
  Future<PickedMedia?> read();
}

class PlatformClipboardMediaReader implements ClipboardMediaReader {
  const PlatformClipboardMediaReader();

  @override
  Future<PickedMedia?> read() => MediaActions.readClipboardMedia();
}

/// Parses a text/uri-list or plain path into a local file Uri.
///
/// Only local files are accepted here; remote http(s) sources are deliberately
/// rejected so a clipboard value cannot make the client fetch arbitrary URLs.
Uri? parseClipboardMediaUri(String raw) {
  for (final String line in raw.split(RegExp(r'[\r\n]+'))) {
    final String value = line.trim();
    if (value.isEmpty || value.startsWith('#')) {
      continue;
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri == null) {
      continue;
    }
    if (uri.scheme == 'file') {
      return uri;
    }
    if (uri.scheme.isEmpty &&
        (value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value))) {
      return Uri.file(value);
    }
  }
  return null;
}

/// Platform file pickers, clipboard media and save locations.
class MediaActions {
  static const XTypeGroup _imageGroup = XTypeGroup(
    label: '图片',
    extensions: <String>['png', 'jpg', 'jpeg', 'webp'],
  );

  static const MethodChannel _clipboardChannel = MethodChannel(
    'bb/media_clipboard',
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

  /// Reads an image or video from the platform clipboard.
  ///
  /// Desktop uses explicit image/video clipboard targets first, then a local
  /// file URI / path from the text clipboard. Android uses the platform
  /// ClipData URI channel implemented in MainActivity.
  static Future<PickedMedia?> readClipboardMedia() async {
    if (kIsWeb) {
      return null;
    }
    if (Platform.isAndroid) {
      return _readAndroidClipboard();
    }
    if (Platform.isIOS) {
      return null;
    }
    return _readDesktopClipboard();
  }

  static Future<PickedMedia?> _readAndroidClipboard() async {
    try {
      final Map<Object?, Object?>? raw = await _clipboardChannel
          .invokeMethod<Map<Object?, Object?>>('readClipboardMedia');
      if (raw == null) {
        return null;
      }
      final Object? data = raw['data'];
      final Object? mime = raw['mime_type'];
      final Object? filename = raw['filename'];
      if (data is! Uint8List ||
          mime is! String ||
          !(mime.startsWith('image/') || mime.startsWith('video/'))) {
        return null;
      }
      if (data.isEmpty || data.length > chatMaxUploadBytes) {
        return null;
      }
      return PickedMedia(
        bytes: data,
        filename: filename is String && filename.isNotEmpty
            ? filename
            : 'clipboard-${DateTime.now().millisecondsSinceEpoch}',
        mimeType: mime,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<PickedMedia?> _readDesktopClipboard() async {
    final List<_ClipboardCommand> binaryCandidates = <_ClipboardCommand>[
      _ClipboardCommand('wl-paste', <String>[
        '--no-newline',
        '--type',
        'image/png',
      ], 'image/png'),
      _ClipboardCommand('wl-paste', <String>[
        '--no-newline',
        '--type',
        'image/jpeg',
      ], 'image/jpeg'),
      _ClipboardCommand('wl-paste', <String>[
        '--no-newline',
        '--type',
        'video/mp4',
      ], 'video/mp4'),
      _ClipboardCommand('wl-paste', <String>[
        '--no-newline',
        '--type',
        'video/webm',
      ], 'video/webm'),
      _ClipboardCommand('xclip', <String>[
        '-selection',
        'clipboard',
        '-t',
        'image/png',
        '-o',
      ], 'image/png'),
      _ClipboardCommand('xclip', <String>[
        '-selection',
        'clipboard',
        '-t',
        'video/mp4',
        '-o',
      ], 'video/mp4'),
    ];
    for (final _ClipboardCommand command in binaryCandidates) {
      final Uint8List? bytes = await command.readBytes();
      if (bytes == null || bytes.isEmpty) {
        continue;
      }
      final String sniffed = sniffMime(bytes);
      if (!sniffed.startsWith('image/') && !sniffed.startsWith('video/')) {
        continue;
      }
      final String mime = sniffed == 'application/octet-stream'
          ? command.mime
          : sniffed;
      return PickedMedia(
        bytes: bytes,
        filename:
            'clipboard-${DateTime.now().millisecondsSinceEpoch}'
            '.${_extensionForMime(mime)}',
        mimeType: mime,
      );
    }

    final List<_ClipboardCommand> textCandidates = <_ClipboardCommand>[
      _ClipboardCommand('wl-paste', <String>[
        '--no-newline',
        '--type',
        'text/uri-list',
      ]),
      _ClipboardCommand('xclip', <String>['-selection', 'clipboard', '-o']),
      _ClipboardCommand('xsel', <String>['--clipboard', '--output']),
    ];
    for (final _ClipboardCommand command in textCandidates) {
      final String? text = await command.readText();
      if (text == null || text.trim().isEmpty) {
        continue;
      }
      final PickedMedia? fromData = _fromDataUri(text);
      if (fromData != null) {
        return fromData;
      }
      final Uri? uri = parseClipboardMediaUri(text);
      if (uri == null) {
        continue;
      }
      try {
        final File file = File.fromUri(uri);
        if (!await file.exists()) {
          continue;
        }
        final int length = await file.length();
        if (length == 0 || length > chatMaxUploadBytes) {
          continue;
        }
        final Uint8List bytes = await file.readAsBytes();
        final String mime = sniffMime(bytes, file.path);
        if (!mime.startsWith('image/') && !mime.startsWith('video/')) {
          continue;
        }
        return PickedMedia(
          bytes: bytes,
          filename: file.uri.pathSegments.isEmpty
              ? 'clipboard'
              : file.uri.pathSegments.last,
          mimeType: mime,
          path: file.path,
        );
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  static PickedMedia? _fromDataUri(String text) {
    final RegExpMatch? match = RegExp(
      r'^data:(image/(?:png|jpeg|webp)|video/(?:mp4|webm));base64,([A-Za-z0-9+/=\s]+)$',
      multiLine: true,
    ).firstMatch(text.trim());
    if (match == null) {
      return null;
    }
    try {
      final Uint8List bytes = base64Decode(
        match.group(2)!.replaceAll(RegExp(r'\s'), ''),
      );
      if (bytes.isEmpty || bytes.length > chatMaxUploadBytes) {
        return null;
      }
      final String mime = match.group(1)!;
      final String sniffed = sniffMime(bytes);
      if (sniffed != mime) {
        return null;
      }
      return PickedMedia(
        bytes: bytes,
        filename:
            'clipboard-${DateTime.now().millisecondsSinceEpoch}'
            '.${_extensionForMime(mime)}',
        mimeType: mime,
      );
    } on FormatException {
      return null;
    }
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
          'source.${_extensionForMime(sniffMime(bytes, filename))}',
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

  static String _extensionForMime(String mime) {
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

class _ClipboardCommand {
  const _ClipboardCommand(this.executable, this.arguments, [this.mime = '']);

  final String executable;
  final List<String> arguments;
  final String mime;

  Future<Uint8List?> readBytes() async {
    try {
      final ProcessResult result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      if (result.exitCode != 0) {
        return null;
      }
      final Object? raw = result.stdout;
      final Uint8List bytes = raw is Uint8List
          ? raw
          : Uint8List.fromList((raw as List<int>?) ?? const <int>[]);
      return bytes.isEmpty ? null : bytes;
    } on ProcessException {
      return null;
    }
  }

  Future<String?> readText() async {
    try {
      final ProcessResult result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) {
        return null;
      }
      final Object? raw = result.stdout;
      return raw is String ? raw : null;
    } on ProcessException {
      return null;
    }
  }
}
