import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'release_policy.dart';
import 'update_contract.dart';

/// A client is scoped to one action. Closing it cancels all outstanding I/O.
class ReleaseClient {
  ReleaseClient({HttpClient? http}) : _http = http ?? HttpClient() {
    _http.autoUncompress = false;
    _http.connectionTimeout = const Duration(seconds: 20);
  }
  final HttpClient _http;
  void close() => _http.close(force: true);

  Future<HttpClientResponse> _get(Uri initial, {bool asset = false}) async {
    var uri = initial;
    for (var hop = 0; hop < 5; hop++) {
      // Redirects to arbitrary HTTPS hosts are still not trusted. CDN queries
      // are signed by GitHub and only accepted after the repository URL.
      final allowed =
          secureUri(uri) &&
          (asset
              ? (uri == initial ||
                    const [
                      'release-assets.githubusercontent.com',
                      'objects.githubusercontent.com',
                    ].contains(uri.host))
              : uri.host == 'api.github.com' &&
                    uri.path == '/repos/iiishop/BB/releases');
      if (!allowed) throw StateError('更新下载重定向到了不受信任的位置。');
      final request = await _http
          .getUrl(uri)
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'BB-client-updater');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (asset) {
        request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      } else {
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
      }
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (location == null) throw StateError('更新下载缺少重定向地址。');
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        final code = response.statusCode;
        if (code == 403 || code == 429) {
          throw StateError('GitHub 请求受限，请稍后手动重试。');
        }
        throw HttpException('更新服务器返回 HTTP $code。');
      }
      return response;
    }
    throw StateError('更新下载重定向次数过多。');
  }

  Future<List<int>> _bytes(HttpClientResponse response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > limit) throw StateError('更新元数据超过大小限制。');
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<List<dynamic>> releases() async {
    final all = <dynamic>[];
    for (var page = 1; page <= 20; page++) {
      final response = await _get(
        Uri.https('api.github.com', '/repos/iiishop/BB/releases', {
          'per_page': '100',
          'page': '$page',
        }),
      );
      final list = jsonDecode(
        utf8.decode(await _bytes(response, 8 * 1024 * 1024)),
      ) as List<dynamic>;
      all.addAll(list);
      if (list.length < 100) return all;
    }
    throw StateError('Release 列表过长，无法确认最高版本。');
  }

  Future<String> checksums(UpdateAsset asset) async {
    if (asset.size > 1024 * 1024) throw StateError('SHA256SUMS 过大。');
    final bytes = await _bytes(await _get(Uri.https('api.github.com', '/repos/iiishop/BB/releases/assets/${asset.id}'), asset: true), 1024 * 1024);
    if (bytes.length != asset.size) throw StateError('SHA256SUMS 下载不完整。');
    return utf8.decode(bytes);
  }

  Future<void> download(
    UpdateAsset asset,
    File file,
    void Function(int) progress,
  ) async {
    if (asset.size > 2 * 1024 * 1024 * 1024) {
      throw StateError('安装包超过 2 GiB 限制。');
    }
    final response = await _get(Uri.https('api.github.com', '/repos/iiishop/BB/releases/assets/${asset.id}'), asset: true);
    if (response.contentLength >= 0 && response.contentLength != asset.size) {
      throw StateError('安装包长度与 Release 不一致。');
    }
    final out = await file.open(mode: FileMode.writeOnly);
    var received = 0;
    try {
      await for (final bytes in response.timeout(const Duration(seconds: 30))) {
        received += bytes.length;
        if (received > asset.size) throw StateError('安装包超过预期长度。');
        await out.writeFrom(bytes);
        progress(received);
      }
      if (received != asset.size) throw StateError('安装包下载中断或不完整，请重试。');
      await out.flush();
    } finally {
      await out.close();
    }
  }
}
