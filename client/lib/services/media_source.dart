import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'chat_ledger.dart';

/// A client-side media source: exactly one of path/url/base64/bytes.
class MediaSource {
  const MediaSource({
    this.path,
    this.url,
    this.base64,
    this.bytes,
    this.filename,
    this.mimeType,
  });

  final String? path;
  final String? url;
  final String? base64;
  final Uint8List? bytes;
  final String? filename;
  final String? mimeType;

  bool get hasExactlyOne =>
      <Object?>[
        path,
        url,
        base64,
        bytes,
      ].where((Object? v) => v != null).length ==
      1;

  /// Content fingerprint used by operation digests. It is stable for the same
  /// bytes and makes a changed file at the same path a different operation.
  String get contentFingerprint {
    String hashOf(List<int> value) => sha256Hex(value);
    if (bytes != null) {
      return 'bytes:${hashOf(bytes!)}:${bytes!.length}';
    }
    if (base64 != null) {
      try {
        final String raw = base64!.trim();
        final int comma = raw.startsWith('data:') ? raw.indexOf(',') : -1;
        final List<int> decoded = base64Decode(
          comma >= 0 ? raw.substring(comma + 1) : raw,
        );
        return 'base64:${hashOf(decoded)}:${decoded.length}';
      } on FormatException {
        return 'base64:invalid';
      }
    }
    if (path != null) {
      try {
        final FileStat stat = File(path!).statSync();
        return 'path:${hashOf(utf8.encode('$path|${stat.size}|'
        '${stat.modified.millisecondsSinceEpoch}'))}:${stat.size}';
      } on FileSystemException {
        return 'path:missing:$path';
      }
    }
    if (url != null) {
      return 'url:${hashOf(utf8.encode(url!))}';
    }
    return 'none';
  }

  factory MediaSource.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('source must be an object');
    }
    String? text(Object? value) {
      if (value == null) {
        return null;
      }
      if (value is! String) {
        throw const FormatException('source field must be a string');
      }
      return value.isEmpty ? null : value;
    }

    return MediaSource(
      path: text(json['path']),
      url: text(json['url']),
      base64: text(json['base64']),
      filename: text(json['filename']),
      mimeType: text(json['mime_type']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (path != null) 'path': path,
    if (url != null) 'url': url,
    if (base64 != null) 'base64': base64,
    if (filename != null) 'filename': filename,
    if (mimeType != null) 'mime_type': mimeType,
    'source_digest': contentFingerprint,
  };
}

/// Bytes plus the metadata needed for an upload.
class ResolvedMedia {
  const ResolvedMedia({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;
}

/// Resolves MCP/UI sources into bytes. Reads paths, URLs and base64 only on the
/// client side; the plugin never touches the filesystem or network itself.
class MediaSourceResolver {
  MediaSourceResolver({
    this.timeout = const Duration(seconds: 20),
    this.maxBytes = chatMaxUploadBytes,
  });

  final Duration timeout;
  final int maxBytes;

  Future<ResolvedMedia> resolve(MediaSource source) async {
    if (!source.hasExactlyOne) {
      throw _badSource('来源必须且只能提供 path、url、base64 或 bytes 之一');
    }
    final Uint8List bytes;
    final String? hintedName;
    if (source.bytes != null) {
      bytes = source.bytes!;
      hintedName = source.filename;
    } else if (source.base64 != null) {
      final String raw = source.base64!.trim();
      final int comma = raw.startsWith('data:') ? raw.indexOf(',') : -1;
      final String payload = comma >= 0 ? raw.substring(comma + 1) : raw;
      try {
        bytes = base64Decode(payload);
      } on FormatException {
        throw _badSource('base64 不是有效编码');
      }
      hintedName = source.filename;
    } else if (source.path != null) {
      final File file = File(source.path!);
      if (!await file.exists()) {
        throw _badSource('文件不存在');
      }
      final int length = await file.length();
      if (length > maxBytes) {
        throw _tooLarge();
      }
      bytes = await file.readAsBytes();
      hintedName = source.filename ?? file.uri.pathSegments.last;
    } else {
      final Uri? uri = Uri.tryParse(source.url!);
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw _badSource('只支持 http(s) URL');
      }
      bytes = await _download(uri);
      hintedName =
          source.filename ??
          (uri.pathSegments.isEmpty ? null : uri.pathSegments.last);
    }
    if (bytes.length > maxBytes) {
      throw _tooLarge();
    }
    if (bytes.isEmpty) {
      throw _badSource('文件为空');
    }
    final String filename = sanitizeFilename(
      (hintedName == null || hintedName.trim().isEmpty)
          ? 'attachment'
          : hintedName,
    );
    final String mime = (source.mimeType != null && source.mimeType!.isNotEmpty)
        ? source.mimeType!
        : sniffMime(bytes, filename);
    return ResolvedMedia(bytes: bytes, filename: filename, mimeType: mime);
  }

  Future<Uint8List> _download(Uri uri) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(timeout);
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _badSource('下载来源失败（HTTP ${response.statusCode}）');
      }
      final int length = response.contentLength;
      if (length > maxBytes) {
        throw _tooLarge();
      }
      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw _tooLarge();
        }
      }
      return builder.takeBytes();
    } on SocketException {
      throw _badSource('无法连接来源地址');
    } on TimeoutException {
      throw _badSource('来源地址请求超时');
    } finally {
      client.close(force: true);
    }
  }

  static AuthFailure _badSource(String message) => AuthFailure(
    status: 422,
    code: 'validation_error',
    message: message,
    fields: const <AuthFieldError>[
      AuthFieldError(field: 'source', code: 'invalid', message: '来源无效'),
    ],
  );

  static AuthFailure _tooLarge() => const AuthFailure(
    status: 413,
    code: 'payload_too_large',
    message: '文件超过 32 MiB 上限',
  );
}

/// Display-only filename sanitizer. Never used as a server path.
String sanitizeFilename(String raw) {
  final String base = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\]'), '_').trim();
  final String stripped = base.replaceFirst(RegExp(r'^\.+$'), '');
  final String name = stripped.isEmpty ? 'attachment' : stripped;
  return name.length <= 180 ? name : name.substring(0, 180);
}

/// Magic-byte first MIME detection. Unknown bytes fall back to the extension,
/// then the server's generic type.
String sniffMime(Uint8List bytes, [String? filename]) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) {
      return false;
    }
    for (int i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  bool asciiAt(int offset, String text) {
    if (bytes.length < offset + text.length) {
      return false;
    }
    for (int i = 0; i < text.length; i++) {
      if (bytes[offset + i] != text.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const <int>[0x89, 0x50, 0x4E, 0x47])) {
    return 'image/png';
  }
  if (startsWith(const <int>[0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg';
  }
  if (asciiAt(0, 'RIFF') && asciiAt(8, 'WEBP')) {
    return 'image/webp';
  }
  if (asciiAt(0, '%PDF')) {
    return 'application/pdf';
  }
  if (asciiAt(4, 'ftyp')) {
    return 'video/mp4';
  }
  if (startsWith(const <int>[0x1A, 0x45, 0xDF, 0xA3])) {
    return 'video/webm';
  }
  if (asciiAt(0, 'RIFF') && asciiAt(8, 'WAVE')) {
    return 'audio/wav';
  }
  if (startsWith(const <int>[0x49, 0x44, 0x33]) ||
      startsWith(const <int>[0xFF, 0xFB])) {
    return 'audio/mpeg';
  }
  final String ext = (filename ?? '').toLowerCase();
  if (ext.endsWith('.mp4')) {
    return 'video/mp4';
  }
  if (ext.endsWith('.webm')) {
    return 'video/webm';
  }
  if (ext.endsWith('.mp3')) {
    return 'audio/mpeg';
  }
  if (ext.endsWith('.wav')) {
    return 'audio/wav';
  }
  if (ext.endsWith('.pdf')) {
    return 'application/pdf';
  }
  if (ext.endsWith('.txt')) {
    return 'text/plain';
  }
  if (ext.endsWith('.png')) {
    return 'image/png';
  }
  if (ext.endsWith('.jpg') || ext.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (ext.endsWith('.webp')) {
    return 'image/webp';
  }
  return 'application/octet-stream';
}

/// Classifies a MIME type into the attachment cache/download kind.
AttachmentKind attachmentKindForMime(String mime) {
  if (mime.startsWith('image/')) {
    return AttachmentKind.image;
  }
  if (mime.startsWith('video/')) {
    return AttachmentKind.video;
  }
  if (mime.startsWith('audio/')) {
    return AttachmentKind.audio;
  }
  if (mime == 'application/pdf' || mime.startsWith('text/')) {
    return AttachmentKind.document;
  }
  return AttachmentKind.other;
}

/// Extracts the first real video frame for the upload cover.
///
/// Desktop uses the system `ffmpeg`; Android resolves covers in the Flutter UI
/// layer with the platform thumbnailer. Returning null means "no cover" and the
/// caller must not pretend the upload succeeded.
abstract interface class VideoCoverExtractor {
  Future<ResolvedMedia?> extract({
    required String path,
    required String filename,
  });
}

class FfmpegVideoCoverExtractor implements VideoCoverExtractor {
  FfmpegVideoCoverExtractor({this.executable = 'ffmpeg'});

  final String executable;

  @override
  Future<ResolvedMedia?> extract({
    required String path,
    required String filename,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return null;
    }
    try {
      final ProcessResult result = await Process.run(executable, <String>[
        '-v',
        'error',
        '-ss',
        '0',
        '-i',
        path,
        '-frames:v',
        '1',
        '-f',
        'image2',
        '-vcodec',
        'png',
        'pipe:1',
      ], stdoutEncoding: null);
      if (result.exitCode != 0) {
        return null;
      }
      final Object? raw = result.stdout;
      final Uint8List bytes = raw is Uint8List
          ? raw
          : Uint8List.fromList((raw as List<int>?) ?? const <int>[]);
      if (bytes.isEmpty) {
        return null;
      }
      return ResolvedMedia(
        bytes: bytes,
        filename: '${_stem(filename)}-cover.png',
        mimeType: 'image/png',
      );
    } on ProcessException {
      return null;
    }
  }

  static String _stem(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
