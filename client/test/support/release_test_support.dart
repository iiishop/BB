import 'dart:convert';
import 'dart:io';

import 'package:bb_client/updates/update_contract.dart';
import 'package:crypto/crypto.dart';

const info = UpdatePlatformInfo(
  os: 'windows',
  architecture: 'x64',
  version: '1.9.0',
  buildNumber: 2,
);
final payload = utf8.encode('isolated package bytes');
String sums({bool wrong = false, List<int>? bytes}) =>
    '${wrong ? '0' * 64 : sha256.convert(bytes ?? payload)}  bb-1.10.0-windows-x64.zip\n';
Map<String, dynamic> release({
  String version = '1.10.0',
  bool draft = false,
  bool pre = false,
  int? size,
}) {
  Map<String, dynamic> asset(String name, int size, int id) => {
    'id': id,
    'name': name,
    'size': size,
    'state': 'uploaded',
    'browser_download_url':
        'https://github.com/iiishop/BB/releases/download/v$version/$name',
  };
  return {
    'id': 123,
    'tag_name': 'v$version',
    'draft': draft,
    'prerelease': pre,
    'body': '# Original\n<script>never execute</script>\n[link](https://example.org)',
    'html_url': 'https://github.com/iiishop/BB/releases/tag/v$version',
    'assets': [
      asset('bb-$version-windows-x64.zip', size ?? payload.length, 7),
      asset('SHA256SUMS', sums().length, 8),
    ],
  };
}

class Installer implements UpdateInstaller {
  int installs = 0;
  @override
  Future<UpdatePlatformInfo> platformInfo() async => info;
  @override
  Future<UpdateInstallResult> install(VerifiedUpdate update) async {
    installs++;
    return UpdateInstallResult.installerOpened;
  }
}

// Only reroutes sockets to a real loopback HTTP server. Production URL and
// redirect validation still execute unchanged before every request.
class LoopbackClient implements HttpClient {
  LoopbackClient(this.port);
  final int port;
  final HttpClient inner = HttpClient();
  @override
  set autoUncompress(bool value) {
    inner.autoUncompress = value;
  }

  @override
  set connectionTimeout(Duration? value) {
    inner.connectionTimeout = value;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      inner.getUrl(uri.replace(scheme: 'http', host: '127.0.0.1', port: port));
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
