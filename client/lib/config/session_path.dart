import 'dart:io';

/// Environment / compile-time override for the session file location.
const String sessionFileEnvironmentVariable = 'BB_SESSION_FILE';

/// Explicit session file override, if any.
///
/// Precedence: `--dart-define=BB_SESSION_FILE` (compiled in) then the runtime
/// environment variable. Returns null when neither is set.
String? sessionFileFromEnvironment([Map<String, String>? environment]) {
  const String compiled = String.fromEnvironment(
    sessionFileEnvironmentVariable,
  );
  if (compiled.trim().isNotEmpty) {
    return compiled.trim();
  }
  final Object? value =
      (environment ?? Platform.environment)[sessionFileEnvironmentVariable];
  if (value is String && value.trim().isNotEmpty) {
    return value.trim();
  }
  return null;
}

/// Whether this platform has a shared desktop session location.
///
/// Android/iOS have no stable home directory in pure Dart; the Flutter entry
/// resolves the app-support directory before calling this.
bool get supportsDesktopSessionPath => !(Platform.isAndroid || Platform.isIOS);

/// Default session file for desktop platforms (CLI and Flutter UI agree).
///
/// * Linux: `$XDG_DATA_HOME/bb/session.json` or `~/.local/share/bb/session.json`
/// * macOS: `~/Library/Application Support/BB/session.json`
/// * Windows: `%APPDATA%\BB\session.json`
String defaultDesktopSessionFilePath({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String os = operatingSystem ?? Platform.operatingSystem;
  String require(String key, String hint) {
    final String? value = env[key];
    if (value == null || value.trim().isEmpty) {
      throw StateError(
        '无法确定会话文件位置（缺少 $key），请设置 $sessionFileEnvironmentVariable（$hint）',
      );
    }
    return value.trim();
  }

  switch (os) {
    case 'windows':
      final String appData = require(
        'APPDATA',
        '例如 %APPDATA%\\BB\\session.json',
      );
      return '$appData${Platform.pathSeparator}BB'
          '${Platform.pathSeparator}session.json';
    case 'macos':
      final String home = require(
        'HOME',
        '例如 ~/Library/Application Support/BB',
      );
      return '$home/Library/Application Support/BB/session.json';
    case 'linux':
      final String? xdg = env['XDG_DATA_HOME'];
      final String base = (xdg != null && xdg.trim().isNotEmpty)
          ? xdg.trim()
          : '${require('HOME', '例如 ~/.local/share/bb')}/.local/share';
      return '$base/bb/session.json';
    default:
      throw UnsupportedError('暂不支持在 $os 上使用默认会话文件路径');
  }
}

/// Resolves the session file, honouring an explicit override.
File resolveSessionFile({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final String? override = sessionFileFromEnvironment(environment);
  if (override != null) {
    return File(override);
  }
  return File(
    defaultDesktopSessionFilePath(
      environment: environment,
      operatingSystem: operatingSystem,
    ),
  );
}
