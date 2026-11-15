import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/chat_models.dart';
import '../../services/media_source.dart';
import 'media_actions.dart';

/// One clipboard probe result.
///
/// [files] are ready-to-attach items in clipboard order. [problems] are
/// user-facing reasons for entries that were skipped (directory, unreadable,
/// empty, too large); they are never silently dropped. An empty result with no
/// problems means "no file/image payload", and the composer falls back to plain
/// text paste.
class ClipboardPaste {
  const ClipboardPaste({
    this.files = const <PickedMedia>[],
    this.problems = const <String>[],
  });

  final List<PickedMedia> files;
  final List<String> problems;

  bool get isEmpty => files.isEmpty && problems.isEmpty;
}

/// Clipboard file/image read seam used by the composer and its widget tests.
abstract interface class ClipboardMediaReader {
  Future<ClipboardPaste> read();
}

/// Production reader: Android content URIs through the platform channel,
/// Windows through a PowerShell clipboard probe, other desktops through the
/// system clipboard tools (wl-paste/xclip/xsel).
class PlatformClipboardMediaReader implements ClipboardMediaReader {
  const PlatformClipboardMediaReader();

  @override
  Future<ClipboardPaste> read() async {
    if (kIsWeb) {
      return const ClipboardPaste();
    }
    if (Platform.isAndroid) {
      return _readAndroidClipboard();
    }
    if (Platform.isIOS) {
      return const ClipboardPaste();
    }
    if (Platform.isWindows) {
      return const WindowsClipboardMediaReader().read();
    }
    return _readDesktopClipboard();
  }

  static const MethodChannel _clipboardChannel = MethodChannel(
    'bb/media_clipboard',
  );

  /// Android keeps its existing ClipData channel, which returns one image or
  /// video content URI. File-manager lists are not part of this issue; other
  /// platforms are covered by the desktop readers below.
  static Future<ClipboardPaste> _readAndroidClipboard() async {
    try {
      final Map<Object?, Object?>? raw = await _clipboardChannel
          .invokeMethod<Map<Object?, Object?>>('readClipboardMedia');
      if (raw == null) {
        return const ClipboardPaste();
      }
      final Object? data = raw['data'];
      final Object? mime = raw['mime_type'];
      final Object? filename = raw['filename'];
      if (data is! Uint8List ||
          mime is! String ||
          !(mime.startsWith('image/') || mime.startsWith('video/'))) {
        return const ClipboardPaste();
      }
      if (data.isEmpty || data.length > chatMaxUploadBytes) {
        return const ClipboardPaste();
      }
      return ClipboardPaste(
        files: <PickedMedia>[
          PickedMedia(
            bytes: data,
            filename: filename is String && filename.isNotEmpty
                ? filename
                : 'clipboard-${DateTime.now().millisecondsSinceEpoch}',
            mimeType: mime,
          ),
        ],
      );
    } on PlatformException {
      return const ClipboardPaste();
    } on MissingPluginException {
      return const ClipboardPaste();
    }
  }

  static Future<ClipboardPaste> _readDesktopClipboard() async {
    // Raw image/video clipboard targets carry their own MIME type and cannot be
    // expressed as a file list.
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
      return ClipboardPaste(
        files: <PickedMedia>[
          PickedMedia(
            bytes: bytes,
            filename:
                'clipboard-${DateTime.now().millisecondsSinceEpoch}'
                '.${_extensionForMime(mime)}',
            mimeType: mime,
          ),
        ],
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
        return ClipboardPaste(files: <PickedMedia>[fromData]);
      }
      final List<Uri> uris = parseClipboardFileUris(text);
      if (uris.isEmpty) {
        continue;
      }
      final List<PickedMedia> files = <PickedMedia>[];
      final List<String> problems = <String>[];
      for (final Uri uri in uris) {
        final _LocalFileRead read = await _readLocalFile(uri);
        if (read.media != null) {
          files.add(read.media!);
        } else if (read.problem != null) {
          problems.add(read.problem!);
        }
      }
      if (files.isNotEmpty || problems.isNotEmpty) {
        return ClipboardPaste(files: files, problems: problems);
      }
    }
    return const ClipboardPaste();
  }

  static Future<_LocalFileRead> _readLocalFile(Uri uri) async {
    final File file = File.fromUri(uri);
    final String name = clipboardBasename(file.path);
    try {
      final FileSystemEntityType type = await FileSystemEntity.type(
        file.path,
        followLinks: true,
      );
      if (type == FileSystemEntityType.directory) {
        return _LocalFileRead.problem('已跳过文件夹：$name');
      }
      if (type != FileSystemEntityType.file) {
        return _LocalFileRead.problem('已跳过不可读文件：$name');
      }
      final int length = await file.length();
      if (length == 0) {
        return _LocalFileRead.problem('已跳过空文件：$name');
      }
      if (length > chatMaxUploadBytes) {
        return _LocalFileRead.problem('已跳过超过 32 MiB 的文件：$name');
      }
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        return _LocalFileRead.problem('已跳过空文件：$name');
      }
      return _LocalFileRead.media(
        PickedMedia(
          bytes: bytes,
          filename: name,
          mimeType: sniffMime(bytes, name),
          path: file.path,
        ),
      );
    } on FileSystemException {
      return _LocalFileRead.problem('已跳过不可读文件：$name');
    }
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
}

/// Parses every local file URI/path from a text/uri-list or plain-text
/// clipboard, in clipboard order, removing duplicates.
///
/// Only local files are accepted; remote http(s) sources are deliberately
/// rejected so a clipboard value cannot make the client fetch arbitrary URLs.
List<Uri> parseClipboardFileUris(String raw) {
  final List<Uri> uris = <Uri>[];
  final Set<String> seen = <String>{};
  for (final String line in raw.split(RegExp(r'[\r\n]+'))) {
    String value = line.trim();
    if (value.isEmpty || value.startsWith('#')) {
      continue;
    }
    // Windows "Copy as path" wraps the path in double quotes.
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri == null) {
      continue;
    }
    final Uri? candidate;
    if (uri.scheme == 'file') {
      candidate = uri;
    } else if (uri.scheme.isEmpty &&
        (value.startsWith('/') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
            RegExp(r'^\\\\[^\\]+\\').hasMatch(value))) {
      candidate = Uri.file(value);
    } else {
      candidate = null;
    }
    if (candidate == null) {
      continue;
    }
    if (seen.add(candidate.toString())) {
      uris.add(candidate);
    }
  }
  return uris;
}

/// First local file URI/path from a clipboard text value, if any.
Uri? parseClipboardMediaUri(String raw) {
  final List<Uri> uris = parseClipboardFileUris(raw);
  return uris.isEmpty ? null : uris.first;
}

String clipboardBasename(String path) {
  final int slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final String name = slash >= 0 ? path.substring(slash + 1) : path;
  return name.isEmpty ? 'attachment' : name;
}

String _extensionForMime(String mime) {
  return switch (mime) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    _ => 'bin',
  };
}

class _LocalFileRead {
  const _LocalFileRead._({this.media, this.problem});

  factory _LocalFileRead.media(PickedMedia media) =>
      _LocalFileRead._(media: media);

  factory _LocalFileRead.problem(String problem) =>
      _LocalFileRead._(problem: problem);

  final PickedMedia? media;
  final String? problem;
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

/// Windows clipboard probe.
///
/// The Windows runner has no clipboard plugin, so the probe asks PowerShell for
/// the CF_HDROP file list (Explorer copy) or converts a CF_DIB image to PNG.
/// The script writes a UTF-8 listing into a private temp directory, which keeps
/// non-ASCII file names out of the console code page. Native Windows execution
/// is NOT RUN in this environment; [runner] is the seam used by unit tests.
class WindowsClipboardMediaReader implements ClipboardMediaReader {
  const WindowsClipboardMediaReader({this.runner});

  final WindowsClipboardScriptRunner? runner;

  @override
  Future<ClipboardPaste> read() async {
    final WindowsClipboardScriptRunner run = runner ?? _runPowerShell;
    if (runner == null && !Platform.isWindows) {
      return const ClipboardPaste();
    }
    Directory? temporaryDirectory;
    try {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'bb-clipboard-',
      );
      final String outputPath =
          '${temporaryDirectory.path}${Platform.pathSeparator}clipboard.txt';
      final String script = buildWindowsClipboardScript(outputPath);
      final bool ok = await run(script, outputPath);
      if (!ok) {
        return const ClipboardPaste(
          problems: <String>['无法读取 Windows 剪贴板（剪贴板探测失败）'],
        );
      }
      final List<WindowsClipboardEntry> entries = await _readListing(
        outputPath,
      );
      final ClipboardPaste paste = await _collect(entries);
      return paste;
    } on FileSystemException {
      return const ClipboardPaste(
        problems: <String>['无法读取 Windows 剪贴板（临时目录不可用）'],
      );
    } finally {
      if (temporaryDirectory != null) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } on FileSystemException {
          // Best-effort cleanup of the private probe directory.
        }
      }
    }
  }

  static Future<List<WindowsClipboardEntry>> _readListing(
    String outputPath,
  ) async {
    final File listing = File(outputPath);
    if (!await listing.exists()) {
      return const <WindowsClipboardEntry>[];
    }
    return parseWindowsClipboardListing(await listing.readAsString());
  }

  static Future<ClipboardPaste> _collect(
    List<WindowsClipboardEntry> entries,
  ) async {
    final List<PickedMedia> files = <PickedMedia>[];
    final List<String> problems = <String>[];
    for (final WindowsClipboardEntry entry in entries) {
      if (entry.isImage) {
        final String? imageProblem = await _addImage(entry.path, files);
        if (imageProblem != null) {
          problems.add(imageProblem);
        }
        continue;
      }
      final String name = clipboardBasename(entry.path);
      try {
        final File file = File(entry.path);
        final FileSystemEntityType type = await FileSystemEntity.type(
          entry.path,
          followLinks: true,
        );
        if (type == FileSystemEntityType.directory) {
          problems.add('已跳过文件夹：$name');
          continue;
        }
        if (type != FileSystemEntityType.file) {
          problems.add('已跳过不可读文件：$name');
          continue;
        }
        final int length = await file.length();
        if (length == 0) {
          problems.add('已跳过空文件：$name');
          continue;
        }
        if (length > chatMaxUploadBytes) {
          problems.add('已跳过超过 32 MiB 的文件：$name');
          continue;
        }
        final Uint8List bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          problems.add('已跳过空文件：$name');
          continue;
        }
        files.add(
          PickedMedia(
            bytes: bytes,
            filename: name,
            mimeType: sniffMime(bytes, name),
            path: entry.path,
          ),
        );
      } on FileSystemException {
        problems.add('已跳过不可读文件：$name');
      }
    }
    return ClipboardPaste(files: files, problems: problems);
  }

  static Future<String?> _addImage(String path, List<PickedMedia> files) async {
    try {
      final File image = File(path);
      if (!await image.exists()) {
        return '剪贴板图片已失效';
      }
      final Uint8List bytes = await image.readAsBytes();
      if (bytes.isEmpty) {
        return '剪贴板图片为空';
      }
      if (bytes.length > chatMaxUploadBytes) {
        return '剪贴板图片超过 32 MiB 上限';
      }
      files.add(
        PickedMedia(
          bytes: bytes,
          filename: 'clipboard-${DateTime.now().millisecondsSinceEpoch}.png',
          mimeType: 'image/png',
        ),
      );
      return null;
    } on FileSystemException {
      return '剪贴板图片不可读';
    }
  }

  static Future<bool> _runPowerShell(String script, String outputPath) async {
    final String encoded = _encodePowerShell(script);
    for (final String executable in const <String>[
      'powershell.exe',
      'pwsh.exe',
    ]) {
      try {
        final ProcessResult result = await Process.run(
          executable,
          <String>[
            '-NoProfile',
            '-NonInteractive',
            '-STA',
            '-WindowStyle',
            'Hidden',
            '-EncodedCommand',
            encoded,
          ],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (result.exitCode == 0) {
          return true;
        }
      } on ProcessException {
        continue;
      }
    }
    return false;
  }
}

/// Runs the clipboard probe script. Returns true when the script completed.
typedef WindowsClipboardScriptRunner = Future<bool> Function(
  String script,
  String outputPath,
);

class WindowsClipboardEntry {
  const WindowsClipboardEntry.file(this.path) : isImage = false;

  const WindowsClipboardEntry.image(this.path) : isImage = true;

  final String path;
  final bool isImage;
}

/// Builds the PowerShell probe. The script writes `FILE<TAB>path` and
/// `IMAGE<TAB>png-path` lines to [outputPath] instead of printing, so UTF-8
/// paths survive the Windows console code page.
String buildWindowsClipboardScript(String outputPath) {
  final String escaped = outputPath.replaceAll("'", "''");
  return _windowsClipboardTemplate.replaceFirst('__BB_OUTPUT__', escaped);
}

const String _windowsClipboardTemplate = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$out = '__BB_OUTPUT__'
$lines = New-Object System.Collections.Generic.List[string]
$clip = [System.Windows.Forms.Clipboard]
if ($clip::ContainsFileDropList()) {
  foreach ($path in $clip::GetFileDropList()) {
    if (-not [string]::IsNullOrWhiteSpace($path)) {
      $lines.Add('FILE' + [char]9 + $path)
    }
  }
} elseif ($clip::ContainsImage()) {
  $image = $clip::GetImage()
  if ($null -ne $image) {
    $png = Join-Path (Split-Path -Parent $out) 'clipboard.png'
    $image.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $image.Dispose()
    $lines.Add('IMAGE' + [char]9 + $png)
  }
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($out, $lines, $utf8)
''';

/// Parses the probe listing. Unknown or malformed lines are ignored.
List<WindowsClipboardEntry> parseWindowsClipboardListing(String raw) {
  final List<WindowsClipboardEntry> entries = <WindowsClipboardEntry>[];
  for (final String line in raw.split(RegExp(r'\r?\n'))) {
    final int tab = line.indexOf('\t');
    if (tab <= 0) {
      continue;
    }
    final String kind = line.substring(0, tab);
    final String path = line.substring(tab + 1).trim();
    if (path.isEmpty) {
      continue;
    }
    if (kind == 'FILE') {
      entries.add(WindowsClipboardEntry.file(path));
    } else if (kind == 'IMAGE') {
      entries.add(WindowsClipboardEntry.image(path));
    }
  }
  return entries;
}

String _encodePowerShell(String script) {
  final List<int> bytes = <int>[];
  for (final int unit in script.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return base64Encode(bytes);
}
