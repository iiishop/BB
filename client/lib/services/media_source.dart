import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'chat_ledger.dart';
import 'ffmpeg_tool.dart';
import 'http_transport.dart';

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

  /// Reused across calls so the TLS connection is not rebuilt per request.
  late final HttpTransport _http = HttpTransport(connectionTimeout: timeout);

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
    final HttpClient client = _http.client;
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

/// Container-level track check for the two media families that are sniffed by
/// magic bytes.
///
/// The server accepts only real mp4/webm video and requires a cover frame, so an
/// audio-only file in the same container must travel as a generic attachment
/// instead of being blocked by cover extraction. Returns null when the track
/// list is not readable (unknown container, corrupt or truncated file); callers
/// then keep the previous magic-byte classification.
bool? hasVideoTrackInContainer(Uint8List bytes) {
  if (_isEbmlContainer(bytes)) {
    return _ebmlHasVideoTrack(bytes);
  }
  if (_isIsoBmffContainer(bytes)) {
    return _isoBmffHasVideoTrack(bytes);
  }
  return null;
}

bool _isEbmlContainer(Uint8List bytes) {
  return bytes.length >= 4 &&
      bytes[0] == 0x1A &&
      bytes[1] == 0x45 &&
      bytes[2] == 0xDF &&
      bytes[3] == 0xA3;
}

bool _isIsoBmffContainer(Uint8List bytes) {
  if (bytes.length < 8) {
    return false;
  }
  return bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70;
}

const int _ebmlSegmentId = 0x18538067;
const int _ebmlTracksId = 0x1654AE6B;
const int _ebmlTrackEntryId = 0xAE;
const int _ebmlTrackTypeId = 0x83;

class _EbmlElement {
  const _EbmlElement({
    required this.id,
    required this.dataStart,
    required this.dataEnd,
    required this.knownSize,
  });

  final int id;
  final int dataStart;
  final int dataEnd;
  final bool knownSize;
}

/// Reads one EBML element header. Null means malformed/truncated.
_EbmlElement? _readEbmlElement(Uint8List bytes, int offset, int limit) {
  if (offset < 0 || offset >= limit) {
    return null;
  }
  final int idFirst = bytes[offset];
  int idLength = 1;
  while (idLength <= 4 && (idFirst & (0x80 >> (idLength - 1))) == 0) {
    idLength += 1;
  }
  if (idLength > 4 || offset + idLength >= limit) {
    return null;
  }
  int id = 0;
  for (int i = 0; i < idLength; i += 1) {
    id = (id << 8) | bytes[offset + i];
  }
  final int sizeOffset = offset + idLength;
  final int sizeFirst = bytes[sizeOffset];
  if (sizeFirst == 0) {
    return null;
  }
  int sizeLength = 1;
  while (sizeLength <= 8 && (sizeFirst & (0x80 >> (sizeLength - 1))) == 0) {
    sizeLength += 1;
  }
  if (sizeLength > 8 || sizeOffset + sizeLength > limit) {
    return null;
  }
  int size = sizeFirst & (0xFF >> sizeLength);
  for (int i = 1; i < sizeLength; i += 1) {
    size = (size << 8) | bytes[sizeOffset + i];
  }
  final int unknownSizeValue = sizeLength == 8
      ? 0x00FFFFFFFFFFFFFF
      : (1 << (7 * sizeLength)) - 1;
  final bool knownSize = size != unknownSizeValue;
  final int dataStart = sizeOffset + sizeLength;
  final int dataEnd = knownSize ? dataStart + size : limit;
  if (knownSize && (dataEnd < dataStart || dataEnd > limit)) {
    return null;
  }
  return _EbmlElement(
    id: id,
    dataStart: dataStart,
    dataEnd: dataEnd,
    knownSize: knownSize,
  );
}

bool? _ebmlHasVideoTrack(Uint8List bytes) {
  int cursor = 0;
  while (cursor < bytes.length) {
    final _EbmlElement? element = _readEbmlElement(bytes, cursor, bytes.length);
    if (element == null) {
      return null;
    }
    if (element.id == _ebmlSegmentId) {
      int child = element.dataStart;
      while (child < element.dataEnd) {
        final _EbmlElement? entry = _readEbmlElement(
          bytes,
          child,
          element.dataEnd,
        );
        if (entry == null) {
          return _scanEbmlTracks(bytes, element.dataStart, element.dataEnd);
        }
        if (entry.id == _ebmlTracksId) {
          return _parseEbmlTracks(bytes, entry);
        }
        if (!entry.knownSize) {
          return _scanEbmlTracks(bytes, child, element.dataEnd);
        }
        child = entry.dataEnd;
      }
      return null;
    }
    if (!element.knownSize) {
      return _scanEbmlTracks(bytes, element.dataStart, bytes.length);
    }
    cursor = element.dataEnd;
  }
  return null;
}

bool? _parseEbmlTracks(Uint8List bytes, _EbmlElement tracks) {
  bool foundEntry = false;
  bool foundVideo = false;
  int cursor = tracks.dataStart;
  while (cursor < tracks.dataEnd) {
    final _EbmlElement? entry = _readEbmlElement(bytes, cursor, tracks.dataEnd);
    if (entry == null) {
      break;
    }
    if (entry.id == _ebmlTrackEntryId) {
      foundEntry = true;
      if (_ebmlTrackType(bytes, entry) == 1) {
        foundVideo = true;
      }
    }
    if (!entry.knownSize) {
      break;
    }
    cursor = entry.dataEnd;
  }
  return foundEntry ? foundVideo : null;
}

int? _ebmlTrackType(Uint8List bytes, _EbmlElement trackEntry) {
  int cursor = trackEntry.dataStart;
  while (cursor < trackEntry.dataEnd) {
    final _EbmlElement? entry = _readEbmlElement(
      bytes,
      cursor,
      trackEntry.dataEnd,
    );
    if (entry == null) {
      return null;
    }
    if (entry.id == _ebmlTrackTypeId &&
        entry.dataEnd > entry.dataStart &&
        entry.dataEnd - entry.dataStart <= 8) {
      int value = 0;
      for (int i = entry.dataStart; i < entry.dataEnd; i += 1) {
        value = (value << 8) | bytes[i];
      }
      return value;
    }
    if (!entry.knownSize) {
      return null;
    }
    cursor = entry.dataEnd;
  }
  return null;
}

/// Fallback for unknown-size containers: locate a structurally valid Tracks
/// element. Parsing must yield a track list, otherwise the result stays null.
bool? _scanEbmlTracks(Uint8List bytes, int from, int to) {
  for (int i = from; i + 4 <= to; i += 1) {
    if (bytes[i] != 0x16 ||
        bytes[i + 1] != 0x54 ||
        bytes[i + 2] != 0xAE ||
        bytes[i + 3] != 0x6B) {
      continue;
    }
    final _EbmlElement? element = _readEbmlElement(bytes, i, to);
    if (element == null || element.id != _ebmlTracksId) {
      continue;
    }
    final bool? result = _parseEbmlTracks(bytes, element);
    if (result != null) {
      return result;
    }
  }
  return null;
}

class _IsoBox {
  const _IsoBox(this.type, this.dataStart, this.dataEnd);

  final String type;
  final int dataStart;
  final int dataEnd;
}

/// Reads one ISO-BMFF box. Null means malformed/truncated.
_IsoBox? _readIsoBox(Uint8List bytes, int offset, int limit) {
  if (offset + 8 > limit) {
    return null;
  }
  int size =
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
  final String type = String.fromCharCodes(bytes, offset + 4, offset + 8);
  int dataStart;
  int dataEnd;
  if (size == 1) {
    if (offset + 16 > limit) {
      return null;
    }
    int largeSize = 0;
    for (int i = 0; i < 8; i += 1) {
      largeSize = (largeSize << 8) | bytes[offset + 8 + i];
    }
    if (largeSize < 16 || largeSize > limit - offset) {
      return null;
    }
    size = largeSize;
    dataStart = offset + 16;
    dataEnd = offset + largeSize;
  } else if (size == 0) {
    dataStart = offset + 8;
    dataEnd = limit;
  } else {
    if (size < 8 || size > limit - offset) {
      return null;
    }
    dataStart = offset + 8;
    dataEnd = offset + size;
  }
  if (dataEnd < dataStart) {
    return null;
  }
  return _IsoBox(type, dataStart, dataEnd);
}

bool? _isoBmffHasVideoTrack(Uint8List bytes) {
  _IsoBox? moov;
  int cursor = 0;
  while (cursor < bytes.length) {
    final _IsoBox? box = _readIsoBox(bytes, cursor, bytes.length);
    if (box == null) {
      break;
    }
    if (box.type == 'moov') {
      moov = box;
      break;
    }
    if (box.dataEnd <= cursor) {
      break;
    }
    cursor = box.dataEnd;
  }
  if (moov == null) {
    return null;
  }
  bool foundTrack = false;
  bool foundVideo = false;
  cursor = moov.dataStart;
  while (cursor < moov.dataEnd) {
    final _IsoBox? box = _readIsoBox(bytes, cursor, moov.dataEnd);
    if (box == null) {
      break;
    }
    if (box.type == 'trak') {
      foundTrack = true;
      if (_isoHandlerType(bytes, box) == 'vide') {
        foundVideo = true;
      }
    }
    if (box.dataEnd <= cursor) {
      break;
    }
    cursor = box.dataEnd;
  }
  return foundTrack ? foundVideo : null;
}

String? _isoHandlerType(Uint8List bytes, _IsoBox trak) {
  _IsoBox? mdia;
  int cursor = trak.dataStart;
  while (cursor < trak.dataEnd) {
    final _IsoBox? box = _readIsoBox(bytes, cursor, trak.dataEnd);
    if (box == null) {
      break;
    }
    if (box.type == 'mdia') {
      mdia = box;
      break;
    }
    if (box.dataEnd <= cursor) {
      break;
    }
    cursor = box.dataEnd;
  }
  if (mdia == null) {
    return null;
  }
  cursor = mdia.dataStart;
  while (cursor < mdia.dataEnd) {
    final _IsoBox? box = _readIsoBox(bytes, cursor, mdia.dataEnd);
    if (box == null) {
      break;
    }
    if (box.type == 'hdlr') {
      if (box.dataStart + 12 > box.dataEnd) {
        return null;
      }
      return String.fromCharCodes(bytes, box.dataStart + 8, box.dataStart + 12);
    }
    if (box.dataEnd <= cursor) {
      break;
    }
    cursor = box.dataEnd;
  }
  return null;
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
    // Audio-only ISO-BMFF brands (m4a/m4b/f4a) otherwise look like video/mp4;
    // the server only accepts real mp4/webm video and requires a cover frame,
    // so they are sent as the contract's generic "other" file type instead.
    if (asciiAt(8, 'M4A ') || asciiAt(8, 'M4B ') || asciiAt(8, 'F4A ')) {
      return 'application/octet-stream';
    }
    // The brand alone cannot tell an audio-only mp4 from a video: check the
    // actual track list before promising a cover frame exists.
    if (hasVideoTrackInContainer(bytes) == false) {
      return 'application/octet-stream';
    }
    return 'video/mp4';
  }
  if (startsWith(const <int>[0x1A, 0x45, 0xDF, 0xA3])) {
    if (hasVideoTrackInContainer(bytes) == false) {
      return 'application/octet-stream';
    }
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
/// Desktop uses `ffmpeg`: Windows release packages resolve the executable that
/// ships inside the application directory (see [resolveFfmpegExecutable]);
/// other desktops keep the system tool. Android resolves covers in the Flutter
/// UI layer with the platform thumbnailer. Returning null means "no cover" and
/// the caller must not pretend the upload succeeded.
abstract interface class VideoCoverExtractor {
  Future<ResolvedMedia?> extract({
    required String path,
    required String filename,
  });
}

class FfmpegVideoCoverExtractor implements VideoCoverExtractor {
  FfmpegVideoCoverExtractor({String? executable})
    : executable = executable ?? resolveFfmpegExecutable();

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
