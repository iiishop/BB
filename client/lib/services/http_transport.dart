import 'dart:io';

/// Owns one keep-alive [HttpClient] for a single long-lived API client.
///
/// `HttpClient` *is* the connection pool. Building one per request and closing
/// it with `force: true` throws the socket away, so every call pays a fresh
/// TCP + TLS handshake. On loopback that is ~10 ms and invisible; over the
/// Cloudflare tunnel it is two extra round trips, measured at 0.3-0.4 s per
/// request, and the 2 s event poll plus every avatar fetch were paying it.
///
/// One instance per API client object: the socket is reused for every call to
/// the same origin and lives until the process exits. Nothing closes it per
/// request, and no `Connection: close` header is set.
class HttpTransport {
  HttpTransport({
    this.connectionTimeout = const Duration(seconds: 30),
    HttpClient Function()? factory,
  }) : _factory = factory ?? HttpClient.new;

  /// Bounds a newly opened TCP connection only. Each call still applies its
  /// own request timeout on top of this, so per-endpoint budgets are unchanged.
  final Duration connectionTimeout;

  final HttpClient Function() _factory;
  HttpClient? _client;

  HttpClient get client => _client ??= _create();

  HttpClient _create() {
    final HttpClient client = _factory();
    client.connectionTimeout = connectionTimeout;
    return client;
  }
}
