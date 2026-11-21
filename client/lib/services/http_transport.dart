import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../models/auth_models.dart';

enum NetworkPhase { opening, sending, headers, body }

enum NetworkErrorKind { socket, tls, http, deadline, cancelled, response }

/// Allowlisted metadata only: never retain exception text, URLs or payloads.
class NetworkDiagnostic {
  const NetworkDiagnostic(
    this.service,
    this.phase,
    this.kind,
    this.errorType,
    this.elapsed,
    this.at, {
    this.status,
  });
  final String service;
  final NetworkPhase phase;
  final NetworkErrorKind kind;
  final String errorType;
  final Duration elapsed;
  final DateTime at;
  final int? status;
}

class RequestCancellation {
  final Set<void Function()> _listeners = {};
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }
}

class TransportResponse {
  const TransportResponse(this.status, this.bytes, this.headers);
  final int status;
  final Uint8List bytes;
  final Map<String, String> headers;

  /// Content-Range is the original size; Content-Length can be a partial range.
  int? get totalBytes => _totalBytes(headers);
  static int? _totalBytes(Map<String, String> headers) {
    final range = headers[HttpHeaders.contentRangeHeader];
    return (range == null
            ? null
            : int.tryParse(range.substring(range.lastIndexOf('/') + 1))) ??
        int.tryParse(headers[HttpHeaders.contentLengthHeader] ?? '');
  }
}

/// One keep-alive pool per API. No request, including writes, is retried here.
class HttpTransport {
  HttpTransport({
    this.connectionTimeout = const Duration(seconds: 30),
    HttpClient Function()? factory,
  }) : _factory = factory ?? HttpClient.new;

  final Duration connectionTimeout;
  final HttpClient Function() _factory;
  HttpClient? _client;
  HttpClient get client => _client ??= _create();
  HttpClient _create() => _factory()..connectionTimeout = connectionTimeout;

  static final Queue<NetworkDiagnostic> _diagnostics =
      Queue<NetworkDiagnostic>();
  static List<NetworkDiagnostic> get diagnostics =>
      List.unmodifiable(_diagnostics);

  /// A single deadline covers opening, upload, headers and the entire body.
  /// Cancellation aborts the request and cancels the response subscription.
  /// DNS/openUrl itself is not cancellable in dart:io: a late request is aborted
  /// before any application headers/body are written. Server commits already
  /// accepted cannot be undone; callers must reconcile uncertain writes.
  Future<TransportResponse> send(
    String method,
    Uri url, {
    required String service,
    required Duration timeout,
    required int maxBytes,
    Map<String, String> headers = const {},
    List<int>? body,
    RequestCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final clock = Stopwatch()..start();
    var phase = NetworkPhase.opening;
    HttpClientRequest? request;
    StreamSubscription<List<int>>? subscription;
    final result = Completer<TransportResponse>();
    bool ended = false;
    void record(NetworkErrorKind kind, String type, {int? status}) {
      _diagnostics.add(
        NetworkDiagnostic(
          service,
          phase,
          kind,
          type,
          clock.elapsed,
          DateTime.now().toUtc(),
          status: status,
        ),
      );
      while (_diagnostics.length > 100) {
        _diagnostics.removeFirst();
      }
    }

    void fail(Object error, {NetworkErrorKind? kind}) {
      if (ended) return;
      ended = true;
      record(
        kind ??
            (error is TlsException
                ? NetworkErrorKind.tls
                : error is SocketException
                ? NetworkErrorKind.socket
                : error is HttpException
                ? NetworkErrorKind.http
                : NetworkErrorKind.response),
        error.runtimeType.toString(),
      );
      request?.abort();
      unawaited(subscription?.cancel());
      result.completeError(
        kind == NetworkErrorKind.deadline
            ? upstreamTimeout
            : error is AuthFailure
            ? error
            : upstreamUnavailable,
      );
    }

    final timer = Timer(
      timeout,
      () => fail(TimeoutException('deadline'), kind: NetworkErrorKind.deadline),
    );
    // Detach on completion so long-lived tokens do not retain old requests.
    void cancelRequest() =>
        fail(StateError('cancelled'), kind: NetworkErrorKind.cancelled);
    cancellation?._listeners.add(cancelRequest);
    if (cancellation?.isCancelled ?? false) {
      fail(StateError('cancelled'), kind: NetworkErrorKind.cancelled);
    }
    Future<void> run() async {
      try {
        if (ended) return;
        final opened = await client.openUrl(method, url);
        request = opened;
        if (ended) {
          opened.abort();
          return;
        }
        // Never follow a redirect with credentials or replay a write.
        opened.followRedirects = false;
        headers.forEach(opened.headers.set);
        phase = NetworkPhase.sending;
        if (body != null) {
          opened.contentLength = body.length;
          opened.add(body);
          await opened.flush();
          if (ended) return;
        }
        phase = NetworkPhase.headers;
        final response = await opened.close();
        if (ended) {
          await response.listen((_) {}).cancel();
          return;
        }
        phase = NetworkPhase.body;
        final responseHeaders = <String, String>{};
        response.headers.forEach((name, values) {
          if (values.isNotEmpty) {
            responseHeaders[name.toLowerCase()] = values.first;
          }
        });
        final total = TransportResponse._totalBytes(responseHeaders);
        final bytes = BytesBuilder(copy: false);
        subscription = response.listen(
          (chunk) {
            if (ended) return;
            bytes.add(chunk);
            if (bytes.length > maxBytes) {
              fail(upstreamMalformed);
              return;
            }
            try {
              onProgress?.call(bytes.length, total);
            } catch (error) {
              fail(error);
            }
          },
          onError: (Object error) => fail(error),
          onDone: () {
            if (ended) return;
            ended = true;
            if (response.statusCode >= 400) {
              record(
                NetworkErrorKind.response,
                'HttpStatus',
                status: response.statusCode,
              );
            }
            result.complete(
              TransportResponse(
                response.statusCode,
                bytes.takeBytes(),
                responseHeaders,
              ),
            );
          },
        );
      } catch (error) {
        fail(error);
      }
    }

    unawaited(run());
    try {
      return await result.future;
    } finally {
      timer.cancel();
      cancellation?._listeners.remove(cancelRequest);
      clock.stop();
    }
  }
}
