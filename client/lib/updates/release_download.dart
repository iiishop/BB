part of 'release_client.dart';

class DownloadReport {
  const DownloadReport({required this.peakRequests, required this.fellBack});

  /// Peak concurrent requests including response-body consumption.
  final int peakRequests;
  final bool fellBack;
}

class _PackageDownload {
  _PackageDownload(this.client, this.asset, this.file, this.progress);

  // Keep small downloads on the existing single-request path.
  static const _minSegmentBytes = 2 * 1024 * 1024;
  static final _strongETag = RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$');
  static final _contentRange = RegExp(
    r'^bytes +(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  );

  final ReleaseClient client;
  final UpdateAsset asset;
  final File file;
  final void Function(int) progress;
  int _received = 0;
  int _active = 0;
  int _peak = 1;

  Future<DownloadReport> run() async {
    if (asset.size > 2 * 1024 * 1024 * 1024) {
      throw StateError('安装包超过 2 GiB 限制。');
    }
    final initial = ReleaseClient._assetUri(asset);
    final possible = asset.size ~/ _minSegmentBytes;
    final lanes = possible < client.downloadConcurrency
        ? possible
        : client.downloadConcurrency;
    if (lanes < 2) {
      await _single(await client._get(initial, asset: true));
      return const DownloadReport(peakRequests: 1, fellBack: false);
    }

    var endpoint = initial;
    try {
      final (probe, finalUri) = await client._request(
        initial,
        asset: true,
        range: (start: 0, end: 0),
        isRangeProbe: true,
      );
      endpoint = finalUri;
      if (probe.statusCode == HttpStatus.ok) {
        await _useFullProbe(probe);
        return const DownloadReport(peakRequests: 1, fellBack: true);
      }
      final etag = await _validateProbe(probe);
      // Reuse the validated endpoint so each piece does not request a new
      // GitHub API redirect or bind to a different signed URL.
      await _parallel(endpoint, etag, lanes);
      return DownloadReport(peakRequests: _peak, fellBack: false);
    } on _UnreliableRange catch (error) {
      client._ensureOpen();
      client._http.close(force: true);
      client._http = client._openHttp();
      if (_received > 0) {
        _received = 0;
        progress(0);
      }
      await _single(await client._get(error.endpoint ?? endpoint, asset: true));
      return DownloadReport(peakRequests: _peak, fellBack: true);
    }
  }

  Future<void> _useFullProbe(HttpClientResponse response) async {
    // A 200 can carry the full package. If this response to Range is unusable,
    // allow the same plain-GET fallback as for a failed 206 probe.
    try {
      await _single(response);
    } on _InvalidPackageBody {
      throw const _UnreliableRange();
    } on Exception catch (error) {
      if (!ReleaseClient._isTransportFailure(error)) rethrow;
      throw const _UnreliableRange();
    }
  }

  Future<String> _validateProbe(HttpClientResponse response) async {
    // The optional probe establishes range support. A final response that
    // rejects Range can still succeed as a plain GET. _request handles rate
    // limits and redirect trust before any response reaches this check.
    try {
      final etag = _uniqueHeader(response, HttpHeaders.etagHeader);
      if (etag == null ||
          !_strongETag.hasMatch(etag) ||
          !_matches(response, 0, 0)) {
        await ReleaseClient._discard(response);
        throw const _UnreliableRange();
      }
      var bytes = 0;
      await for (final chunk in _body(response)) {
        bytes += chunk.length;
        if (bytes > 1) throw const _UnreliableRange();
      }
      if (bytes != 1) throw const _UnreliableRange();
      return etag;
    } on Exception catch (error) {
      if (!ReleaseClient._isTransportFailure(error)) rethrow;
      throw const _UnreliableRange();
    }
  }

  Future<void> _parallel(Uri endpoint, String etag, int lanes) async {
    final out = await file.open(mode: FileMode.writeOnly);
    final tasks = <TaskHandle<void>>[];
    (Object, StackTrace)? failure;
    var writes = Future<void>.value();

    void ensureActive() {
      client._ensureOpen();
      if (failure != null) throw const TaskCancelled();
    }

    void cancelTasks() {
      for (final task in tasks) {
        task.cancel();
      }
    }

    // A RandomAccessFile permits one pending operation. Serialize each seek
    // and write together, keeping at most one waiting chunk per task.
    Future<void> writeAt(int offset, List<int> chunk) {
      writes = writes.then((_) async {
        ensureActive();
        await out.setPosition(offset);
        await out.writeFrom(chunk);
        ensureActive();
        _received += chunk.length;
        progress(_received);
      });
      return writes;
    }

    client._cancelRanges = cancelTasks;
    try {
      ensureActive();
      final scheduler = TaskScheduler(maxConcurrent: lanes);
      for (var index = 0; index < lanes; index++) {
        final start = asset.size * index ~/ lanes;
        final end = asset.size * (index + 1) ~/ lanes - 1;
        tasks.add(
          scheduler.submit(() async {
            try {
              await _range(endpoint, etag, start, end, ensureActive, writeAt);
            } catch (error, stack) {
              if (failure == null) {
                failure = (error, stack);
                cancelTasks();
                client._http.close(force: true);
              }
              rethrow;
            }
          }, execution: TaskExecution.caller),
        );
      }
      // Join every task before closing the file or resetting a failed download.
      await Future.wait(tasks.map((task) => task.result));
      await out.flush();
    } catch (_) {
      client._ensureOpen();
      final error = failure;
      if (error != null) Error.throwWithStackTrace(error.$1, error.$2);
      rethrow;
    } finally {
      client._cancelRanges = null;
      await out.close();
    }
  }

  Future<void> _range(
    Uri endpoint,
    String etag,
    int start,
    int end,
    void Function() ensureActive,
    Future<void> Function(int, List<int>) writeAt,
  ) async {
    var offset = start;
    for (var attempt = 0; ; attempt++) {
      ensureActive();
      _active++;
      if (_active > _peak) _peak = _active;
      try {
        final (response, finalUri) = await client._request(
          endpoint,
          asset: true,
          range: (start: offset, end: end),
          etag: etag,
        );
        if (const [500, 502, 503, 504].contains(response.statusCode)) {
          await ReleaseClient._discard(response);
          throw const _RetryRange();
        }
        if (finalUri != endpoint ||
            _uniqueHeader(response, HttpHeaders.etagHeader) != etag ||
            !_matches(response, offset, end)) {
          await ReleaseClient._discard(response);
          throw const _UnreliableRange();
        }
        await for (final chunk in _body(response)) {
          if (offset + chunk.length > end + 1) throw const _UnreliableRange();
          await writeAt(offset, chunk);
          offset += chunk.length;
        }
        if (offset != end + 1) throw const _RetryRange();
        return;
      } on Exception catch (error) {
        if (error is! _RetryRange &&
            !ReleaseClient._isTransportFailure(error)) {
          rethrow;
        }
        ensureActive();
        if (attempt > 0 || offset > end) throw const _UnreliableRange();
        // Resume at the first unwritten byte; If-Range binds the retry to the
        // same representation and progress keeps its existing byte count.
      } finally {
        _active--;
      }
    }
  }

  Future<void> _single(HttpClientResponse response) async {
    if (!_identity(response) ||
        (response.contentLength >= 0 && response.contentLength != asset.size)) {
      await ReleaseClient._discard(response);
      throw _InvalidPackageBody('安装包长度或编码与 Release 不一致。');
    }
    final out = await file.open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in _body(response)) {
        client._ensureOpen();
        if (_received + chunk.length > asset.size) {
          throw _InvalidPackageBody('安装包超过预期长度。');
        }
        await out.writeFrom(chunk);
        client._ensureOpen();
        _received += chunk.length;
        progress(_received);
      }
      if (_received != asset.size) {
        throw _InvalidPackageBody('安装包下载中断或不完整，请重试。');
      }
      await out.flush();
    } finally {
      await out.close();
    }
  }

  bool _matches(HttpClientResponse response, int start, int end) {
    if (response.statusCode != HttpStatus.partialContent ||
        !_identity(response)) {
      return false;
    }
    final header = _uniqueHeader(response, HttpHeaders.contentRangeHeader);
    final match = header == null ? null : _contentRange.firstMatch(header);
    return match != null &&
        int.tryParse(match[1]!) == start &&
        int.tryParse(match[2]!) == end &&
        int.tryParse(match[3]!) == asset.size &&
        (response.contentLength < 0 ||
            response.contentLength == end - start + 1);
  }

  static Stream<List<int>> _body(HttpClientResponse response) =>
      response.timeout(const Duration(seconds: 30));

  static String? _uniqueHeader(HttpClientResponse response, String name) {
    final values = response.headers[name];
    return values != null && values.length == 1 ? values.single : null;
  }

  static bool _identity(HttpClientResponse response) {
    final values = response.headers[HttpHeaders.contentEncodingHeader];
    return values == null ||
        (values.length == 1 && values.single.toLowerCase() == 'identity');
  }
}

class _UnreliableRange implements Exception {
  const _UnreliableRange({this.endpoint});

  final Uri? endpoint;
}

class _RetryRange implements Exception {
  const _RetryRange();
}

class _InvalidPackageBody extends StateError {
  _InvalidPackageBody(super.message);
}
