/// Runtime configuration for the BB client.
///
/// Nothing is hardcoded: the server base URL and the local control-API address
/// come from compile-time `--dart-define` values (app) or from CLI flags and
/// environment variables (standalone Dart entry).
library;

/// Default upstream API address used when no configuration is supplied.
const String defaultServerBaseUrl = 'http://127.0.0.1:8000';

/// Default port of the local control API consumed by the DSH plugin.
const int defaultLocalPort = 8787;

/// The only host the local control API may bind to.
const String loopbackHost = '127.0.0.1';

/// Parsed, validated client configuration.
class ClientConfig {
  const ClientConfig({
    required this.serverBaseUri,
    this.localHost = loopbackHost,
    this.localPort = defaultLocalPort,
  });

  /// Upstream FastAPI base URL.
  final Uri serverBaseUri;

  /// Loopback address for the local control API.
  final String localHost;

  /// Port for the local control API (0 lets the OS choose, used by tests).
  final int localPort;

  /// Reads `--dart-define` values embedded in the Flutter build.
  ///
  /// Override with:
  /// `flutter run -d linux --dart-define=BB_API_BASE_URL=http://127.0.0.1:8000`
  factory ClientConfig.fromEnvironment() {
    const String rawBaseUrl = String.fromEnvironment(
      'BB_API_BASE_URL',
      defaultValue: defaultServerBaseUrl,
    );
    const String rawPort = String.fromEnvironment(
      'BB_LOCAL_API_PORT',
      defaultValue: '',
    );
    final int? port = rawPort.isEmpty ? null : int.tryParse(rawPort);
    if (rawPort.isNotEmpty && port == null) {
      throw ArgumentError.value(rawPort, 'BB_LOCAL_API_PORT', '本地控制接口端口必须是整数');
    }
    return ClientConfig(
      serverBaseUri: parseServerBaseUrl(rawBaseUrl),
      localPort: port ?? defaultLocalPort,
    );
  }

  ClientConfig copyWith({
    Uri? serverBaseUri,
    String? localHost,
    int? localPort,
  }) {
    return ClientConfig(
      serverBaseUri: serverBaseUri ?? this.serverBaseUri,
      localHost: localHost ?? this.localHost,
      localPort: localPort ?? this.localPort,
    );
  }
}

/// Parses and validates the upstream base URL.
///
/// Only absolute http/https URLs are accepted so a typo cannot silently turn
/// every request into a relative path.
Uri parseServerBaseUrl(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(raw, 'BB_API_BASE_URL', '服务端地址不能为空');
  }
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasScheme ||
      !uri.hasAuthority ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw ArgumentError.value(
      raw,
      'BB_API_BASE_URL',
      '服务端地址必须是完整的 http(s) URL，例如 http://127.0.0.1:8000',
    );
  }
  return uri;
}

/// The local control API may only ever listen on IPv4 loopback.
void assertLoopbackHost(String host) {
  if (host != loopbackHost) {
    throw ArgumentError.value(
      host,
      'BB_CLIENT_HOST',
      '本地控制接口只允许监听 $loopbackHost，拒绝非回环地址',
    );
  }
}

/// The server address baked into the build, or null when the build supplied
/// none.
///
/// `String.fromEnvironment` cannot distinguish an explicit value from its
/// default, so the sentinel here is an empty string: only
/// `--dart-define=BB_API_BASE_URL=...` yields a non-empty value. A null result
/// means "ask the user", not "use the built-in default".
Uri? compiledServerAddress() {
  const String raw = String.fromEnvironment('BB_API_BASE_URL');
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : parseServerBaseUrl(trimmed);
}

final RegExp _schemePrefix = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

/// Accepts what a person actually types and returns a full base URL.
///
/// `bb.example.com` becomes `https://bb.example.com`; a LAN or loopback address
/// such as `192.168.0.104:18980` stays on plain HTTP, because that is how a
/// self-hosted server is served locally. A scheme is always honoured when
/// given. IPv6 literals without a scheme resolve to HTTPS — type the scheme
/// explicitly to reach a LAN host over HTTP.
Uri normalizeServerAddress(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(raw, 'BB_API_BASE_URL', '服务端地址不能为空');
  }
  if (_schemePrefix.hasMatch(trimmed)) {
    return parseServerBaseUrl(trimmed);
  }
  final Uri probe = Uri.parse('https://$trimmed');
  return parseServerBaseUrl(
    '${_isLanHost(probe.host) ? 'http' : 'https'}://$trimmed',
  );
}

/// True for loopback and RFC 1918 addresses, which a self-hosted server serves
/// over plain HTTP.
bool _isLanHost(String host) {
  if (host == 'localhost') {
    return true;
  }
  final List<String> parts = host.split('.');
  if (parts.length != 4) {
    return false;
  }
  final List<int?> octets = parts.map(int.tryParse).toList(growable: false);
  if (octets.any((int? value) => value == null || value < 0 || value > 255)) {
    return false;
  }
  final int first = octets[0]!;
  final int second = octets[1]!;
  return first == 127 ||
      first == 10 ||
      (first == 192 && second == 168) ||
      (first == 172 && second >= 16 && second <= 31);
}
