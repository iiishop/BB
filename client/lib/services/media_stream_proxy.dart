import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../models/auth_models.dart';
import '../models/chat_models.dart';
import 'auth_session.dart';
import 'chat_api_client.dart';
import 'conversation_access.dart';
import 'http_transport.dart';

/// Bytes delivered through the loopback stream for the current request.
///
/// [requestBytes] is only this Range response, while [mediaBytes] is the full
/// media size from `Content-Range`/`Content-Length`. Callers must label them
/// separately and never present a completed short Range as the whole video.
class MediaStreamProgress {
  const MediaStreamProgress({
    required this.receivedBytes,
    this.requestBytes,
    this.mediaBytes,
    this.rangeStart,
    this.rangeEnd,
  });

  final int receivedBytes;

  /// Declared length of the current request, when the server sent one.
  final int? requestBytes;

  /// Full media size, when the server declared it.
  final int? mediaBytes;

  final int? rangeStart;
  final int? rangeEnd;
}

/// A click-scoped, loopback-only media stream.
///
/// The URL is opened only when the human presses play. The proxy forwards the
/// player's Range request to the authenticated server media endpoint and streams
/// the response; it never downloads or caches the complete original first.
abstract interface class MediaStreamHandle {
  Uri get uri;

  /// Real delivered-byte progress for the current range request. Broadcast so
  /// the viewer can subscribe before the player issues its first request.
  Stream<MediaStreamProgress> get progress;

  Future<void> close();
}

class MediaStreamProxy {
  MediaStreamProxy({required this.api, required this.session});

  final ChatApiClient api;
  final AuthSession session;
  final Set<_LoopbackStream> _open = <_LoopbackStream>{};

  /// Reused across streams so each open does not rebuild the TLS connection.
  late final HttpTransport _http = HttpTransport(
    connectionTimeout: const Duration(seconds: 15),
  );

  Future<MediaStreamHandle> open(
    String mediaId, {
    ConversationRef? conversation,
    ConversationAccessController? access,
  }) async {
    if (mediaId.isEmpty) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: 'media_id 不能为空',
      );
    }
    final AuthIdentity? captured = session.identity;
    if (captured == null) {
      throw unauthenticated;
    }
    final int capturedEpoch = (conversation != null && access != null)
        ? access.epochFor(captured.account, conversation.id)
        : 0;
    if (conversation != null &&
        access != null &&
        access.isStale(captured.account, conversation.id, capturedEpoch)) {
      throw const AuthFailure(
        status: 403,
        code: 'forbidden',
        message: '当前已无权访问该会话媒体',
      );
    }
    final String token = _randomToken();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _LoopbackStream stream = _LoopbackStream(
      server: server,
      token: token,
      mediaId: mediaId,
      api: api,
      session: session,
      identity: captured,
      http: _http,
      conversation: conversation,
      access: access,
      capturedEpoch: capturedEpoch,
      onClosed: (_LoopbackStream value) => _open.remove(value),
    );
    _open.add(stream);
    stream.start();
    return stream;
  }

  Future<void> close() async {
    final List<_LoopbackStream> sessions = _open.toList();
    _open.clear();
    for (final _LoopbackStream stream in sessions) {
      await stream.close();
    }
  }

  static String _randomToken() {
    final Random random = Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 24; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class _ByteRange {
  const _ByteRange({required this.start, required this.end, this.total});

  final int start;
  final int end;
  final int? total;
}

class _LoopbackStream implements MediaStreamHandle {
  _LoopbackStream({
    required this.server,
    required this.token,
    required this.mediaId,
    required this.api,
    required this.session,
    required this.identity,
    required this.http,
    this.conversation,
    this.access,
    this.capturedEpoch = 0,
    required this.onClosed,
  });

  final HttpServer server;
  final String token;
  final String mediaId;
  final ChatApiClient api;
  final AuthSession session;
  final AuthIdentity identity;
  final HttpTransport http;
  final ConversationRef? conversation;
  final ConversationAccessController? access;
  final int capturedEpoch;
  final void Function(_LoopbackStream stream) onClosed;
  bool _closed = false;
  void Function()? _accessListener;
  final StreamController<MediaStreamProgress> _progress =
      StreamController<MediaStreamProgress>.broadcast();

  bool get _accessRevoked =>
      conversation != null &&
      access != null &&
      access!.isStale(identity.account, conversation!.id, capturedEpoch);

  @override
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/stream/$token');

  @override
  Stream<MediaStreamProgress> get progress => _progress.stream;

  void start() {
    if (access != null && conversation != null) {
      _accessListener = () {
        if (_accessRevoked) {
          unawaited(close());
        }
      };
      access!.addListener(_accessListener!);
    }
    server.listen(_handle, onError: (Object _) {});
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != '/stream/$token') {
      await _writeError(request, HttpStatus.notFound);
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _writeError(request, HttpStatus.methodNotAllowed);
      return;
    }
    // A stream opened by A must never serve B's credentials or data.
    if (!session.isCurrent(identity)) {
      await _writeError(request, HttpStatus.unauthorized);
      return;
    }
    if (_accessRevoked) {
      await _writeError(request, HttpStatus.forbidden);
      return;
    }
    final String auth = identity.token;
    if (request.method == 'HEAD') {
      try {
        final MediaProbe probe = await api.probeMedia(
          token: auth,
          mediaId: mediaId,
        );
        if (!session.isCurrent(identity)) {
          await _writeError(request, HttpStatus.unauthorized);
          return;
        }
        final HttpResponse head = request.response;
        head.statusCode = 200;
        head.headers.set(HttpHeaders.contentTypeHeader, probe.mimeType);
        head.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        head.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
        await head.close();
      } on AuthFailure catch (failure) {
        await _writeError(request, failure.status);
      } catch (_) {
        await _writeError(request, HttpStatus.badGateway);
      }
      return;
    }
    final HttpClient client = http.client;
    try {
      final Uri upstream = api.baseUri.resolve(
        '/media/${Uri.encodeComponent(mediaId)}',
      );
      final HttpClientRequest outbound = await client.getUrl(upstream);
      outbound.headers.set(HttpHeaders.authorizationHeader, 'Bearer $auth');
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.isNotEmpty) {
        outbound.headers.set(HttpHeaders.rangeHeader, range);
      }
      final HttpClientResponse upstreamResponse = await outbound.close();
      if (!session.isCurrent(identity)) {
        await upstreamResponse.drain<void>();
        await _writeError(request, HttpStatus.unauthorized);
        return;
      }
      if (upstreamResponse.statusCode != 200 &&
          upstreamResponse.statusCode != 206) {
        request.response.statusCode = upstreamResponse.statusCode;
        await request.response.close();
        return;
      }
      final HttpResponse response = request.response;
      response.statusCode = upstreamResponse.statusCode;
      _copyHeader(upstreamResponse, response, HttpHeaders.contentTypeHeader);
      _copyHeader(upstreamResponse, response, HttpHeaders.contentLengthHeader);
      _copyHeader(upstreamResponse, response, HttpHeaders.contentRangeHeader);
      _copyHeader(upstreamResponse, response, HttpHeaders.acceptRangesHeader);
      _copyHeader(upstreamResponse, response, HttpHeaders.contentDisposition);
      response.headers.set(HttpHeaders.cacheControlHeader, 'private, no-store');
      final int? requestBytes = _contentLength(upstreamResponse);
      final _ByteRange? byteRange = _contentRange(upstreamResponse);
      final int? mediaBytes = byteRange?.total ?? requestBytes;
      int received = 0;
      void report() {
        if (_progress.isClosed) {
          return;
        }
        _progress.add(
          MediaStreamProgress(
            receivedBytes: received,
            requestBytes: requestBytes,
            mediaBytes: mediaBytes,
            rangeStart: byteRange?.start,
            rangeEnd: byteRange?.end,
          ),
        );
      }

      report();
      final Stream<List<int>> counted = upstreamResponse.map((List<int> chunk) {
        received += chunk.length;
        report();
        return chunk;
      });
      await response.addStream(counted);
      await response.close();
    } on HttpException {
      await _writeError(request, HttpStatus.badGateway);
    } on SocketException {
      await _writeError(request, HttpStatus.badGateway);
    } on TimeoutException {
      await _writeError(request, HttpStatus.gatewayTimeout);
    } finally {
      if (_closed) {
        await _stop();
      }
    }
  }

  void _copyHeader(
    HttpClientResponse source,
    HttpResponse target,
    String name,
  ) {
    final String? value = source.headers.value(name);
    if (value != null && value.isNotEmpty) {
      target.headers.set(name, value);
    }
  }

  Future<void> _writeError(HttpRequest request, int status) async {
    final HttpResponse response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write('{"error":{"code":"stream_unavailable"}}');
    await response.close();
  }

  int? _contentLength(HttpClientResponse response) {
    final String? raw = response.headers.value(HttpHeaders.contentLengthHeader);
    return raw == null ? null : int.tryParse(raw);
  }

  _ByteRange? _contentRange(HttpClientResponse response) {
    final String? raw = response.headers.value(HttpHeaders.contentRangeHeader);
    if (raw == null) {
      return null;
    }
    final RegExpMatch? match = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)')
        .firstMatch(raw);
    if (match == null) {
      return null;
    }
    return _ByteRange(
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: match.group(3) == '*' ? null : int.tryParse(match.group(3)!),
    );
  }

  Future<void> _stop() async {
    await server.close(force: true);
    if (!_progress.isClosed) {
      await _progress.close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final void Function()? listener = _accessListener;
    if (listener != null) {
      access?.removeListener(listener);
      _accessListener = null;
    }
    onClosed(this);
    await _stop();
  }
}
