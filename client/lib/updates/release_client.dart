import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../tasks/task_scheduler.dart';
import 'release_policy.dart';
import 'update_contract.dart';

part 'release_download.dart';

const _defaultDownloadConcurrency = int.fromEnvironment(
  'BB_UPDATE_DOWNLOAD_CONCURRENCY',
  defaultValue: 1,
);

class ReleaseRateLimit implements Exception {
  const ReleaseRateLimit(this.retryAt);

  final DateTime? retryAt;

  @override
  String toString() => retryAt == null
      ? 'GitHub 请求受限，请稍后手动重试。'
      : 'GitHub 请求受限，请在 ${retryAt!.toLocal()} 后重试。';
}

/// A client is scoped to one action. Closing it cancels all outstanding I/O.
class ReleaseClient {
  ReleaseClient({
    HttpClient Function()? httpFactory,
    this.downloadConcurrency = _defaultDownloadConcurrency,
  }) : _httpFactory = httpFactory ?? HttpClient.new {
    RangeError.checkValueInInterval(downloadConcurrency, 1, 8);
    _http = _openHttp();
  }
  final HttpClient Function() _httpFactory;
  final int downloadConcurrency;
  late HttpClient _http;
  bool _closed = false;
  ReleaseRateLimit? _rateLimit;
  void Function()? _cancelRanges;

  HttpClient _openHttp() => _httpFactory()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 20);

  void close() {
    if (_closed) return;
    _closed = true;
    _cancelRanges?.call();
    _http.close(force: true);
  }

  void _ensureOpen() {
    if (_closed) throw const TaskCancelled();
    final rateLimit = _rateLimit;
    if (rateLimit != null) throw rateLimit;
  }

  static Uri _assetUri(UpdateAsset asset) => Uri.https(
    'api.github.com',
    '/repos/iiishop/BB/releases/assets/${asset.id}',
  );

  Future<HttpClientResponse> _get(Uri initial, {bool asset = false}) async {
    final (response, _) = await _request(initial, asset: asset);
    await _requireFullResponse(response);
    return response;
  }

  Future<(HttpClientResponse, Uri)> _request(
    Uri initial, {
    required bool asset,
    ({int start, int end})? range,
    String? etag,
    bool isRangeProbe = false,
  }) async {
    var uri = initial;
    for (var hop = 0; hop < 5; hop++) {
      _ensureOpen();
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
      final HttpClientResponse response;
      try {
        response = await _send(uri, asset: asset, range: range, etag: etag);
      } on Exception catch (error) {
        if (!isRangeProbe || !_isTransportFailure(error)) rethrow;
        // Preserve the last validated hop even if it never sent headers.
        throw _UnreliableRange(endpoint: uri);
      }
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await _discard(response);
        if (location == null) throw StateError('更新下载缺少重定向地址。');
        uri = uri.resolve(location);
        continue;
      }
      final code = response.statusCode;
      final retryHeader = response.headers.value(HttpHeaders.retryAfterHeader);
      if (code == 403 || code == 429 || (code == 503 && retryHeader != null)) {
        final retryAt = _retryAt(response.headers, retryHeader);
        final previous = _rateLimit?.retryAt;
        if (previous == null ||
            (retryAt != null && retryAt.isAfter(previous))) {
          _rateLimit = ReleaseRateLimit(retryAt);
        }
        await _discard(response);
        throw _rateLimit!;
      }
      return (response, uri);
    }
    throw StateError('更新下载重定向次数过多。');
  }

  Future<HttpClientResponse> _send(
    Uri uri, {
    required bool asset,
    required ({int start, int end})? range,
    required String? etag,
  }) async {
    final request = await _http.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'BB-client-updater');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(
      HttpHeaders.acceptHeader,
      asset ? 'application/octet-stream' : 'application/vnd.github+json',
    );
    if (range != null) {
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=${range.start}-${range.end}',
      );
      if (etag != null) request.headers.set(HttpHeaders.ifRangeHeader, etag);
    }
    return request.close().timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        final error = TimeoutException('等待更新服务器响应超时。');
        request.abort(error);
        throw error;
      },
    );
  }

  static bool _isTransportFailure(Exception error) =>
      error is SocketException ||
      error is HttpException ||
      error is TimeoutException;

  static DateTime? _retryAt(HttpHeaders headers, String? retryAfter) {
    final now = DateTime.now();
    DateTime? deadline;
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter);
      final maxDelaySeconds =
          (8640000000000000 - now.millisecondsSinceEpoch) ~/ 1000;
      if (seconds != null && seconds >= 0 && seconds <= maxDelaySeconds) {
        deadline = now.add(Duration(seconds: seconds));
      } else {
        try {
          deadline = HttpDate.parse(retryAfter);
        } on HttpException {
          // An invalid Retry-After does not hide a valid GitHub reset time.
        }
      }
    }
    final reset = int.tryParse(headers.value('x-ratelimit-reset') ?? '');
    if (headers.value('x-ratelimit-remaining') == '0' &&
        reset != null &&
        reset > 0 &&
        reset <= 8640000000000) {
      final resetAt = DateTime.fromMillisecondsSinceEpoch(reset * 1000);
      if (deadline == null || resetAt.isAfter(deadline)) deadline = resetAt;
    }
    return deadline;
  }

  static Future<void> _discard(HttpClientResponse response) =>
      response.listen(null).cancel();

  static Future<void> _requireFullResponse(HttpClientResponse response) async {
    if (response.statusCode == HttpStatus.ok) return;
    await _discard(response);
    throw HttpException('更新服务器返回 HTTP ${response.statusCode}。');
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
    final bytes = await _bytes(
      await _get(_assetUri(asset), asset: true),
      1024 * 1024,
    );
    if (bytes.length != asset.size) throw StateError('SHA256SUMS 下载不完整。');
    return utf8.decode(bytes);
  }

  Future<DownloadReport> download(
    UpdateAsset asset,
    File file,
    void Function(int) progress,
  ) => _PackageDownload(this, asset, file, progress).run();
}
