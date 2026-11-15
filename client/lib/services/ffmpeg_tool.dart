import 'dart:io';

/// Development/QA override for the FFmpeg executable.
///
/// Release packages must not rely on it: Windows packages resolve
/// `ffmpeg/ffmpeg.exe` from the application directory instead.
const String ffmpegPathEnvironmentVariable = 'BB_FFMPEG_PATH';

/// Resolves the FFmpeg executable used for local video-cover extraction.
///
/// Windows release packages carry `ffmpeg/ffmpeg.exe` next to the application
/// executable, so the lookup is anchored to the running application directory
/// and never to the current working directory or the system PATH. Developer
/// builds that do not bundle the tool fall back to `ffmpeg` on PATH; other
/// platforms keep the existing system-tool behaviour (their distribution
/// packaging is unchanged).
///
/// [environmentOverride] is injected by tests; when omitted the
/// [ffmpegPathEnvironmentVariable] environment variable is honoured.
String resolveFfmpegExecutable({
  bool? isWindows,
  String? resolvedExecutable,
  String? pathSeparator,
  String? environmentOverride,
  bool Function(String path)? fileExists,
}) {
  final String override =
      (environmentOverride ??
              Platform.environment[ffmpegPathEnvironmentVariable] ??
              '')
          .trim();
  if (override.isNotEmpty) {
    return override;
  }
  if (!(isWindows ?? Platform.isWindows)) {
    return 'ffmpeg';
  }
  final String executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final String separator = pathSeparator ?? Platform.pathSeparator;
  final int separatorIndex = executable.lastIndexOf(RegExp(r'[\\/]'));
  final String applicationDirectory = separatorIndex > 0
      ? executable.substring(0, separatorIndex)
      : '';
  if (applicationDirectory.isEmpty) {
    return 'ffmpeg';
  }
  final bool Function(String path) exists =
      fileExists ?? (String path) => File(path).existsSync();
  final List<String> candidates = <String>[
    '$applicationDirectory${separator}ffmpeg$separator'
        'ffmpeg.exe',
    '$applicationDirectory${separator}ffmpeg.exe',
  ];
  for (final String candidate in candidates) {
    if (exists(candidate)) {
      return candidate;
    }
  }
  return 'ffmpeg';
}
