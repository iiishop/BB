import 'dart:io';

/// Opens a URL in the user's browser.
///
/// Only `https` targets reach this interface, and only after the user confirmed
/// the exact target in the update surface. Android is handled by the update
/// channel; desktop/other hosts use the platform's default opener.
abstract interface class ExternalLinkOpener {
  Future<bool> open(Uri uri);
}

class PlatformExternalLinkOpener implements ExternalLinkOpener {
  const PlatformExternalLinkOpener();

  @override
  Future<bool> open(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return false;
    }
    try {
      final ProcessResult result;
      if (Platform.isWindows) {
        // Argument array, not a shell string. This is the documented Windows
        // URL handler for the default browser.
        result = await Process.run(
          '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\rundll32.exe',
          <String>['url.dll,FileProtocolHandler', uri.toString()],
        );
      } else if (Platform.isLinux) {
        result = await Process.run('xdg-open', <String>[uri.toString()]);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', <String>[uri.toString()]);
      } else {
        return false;
      }
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
