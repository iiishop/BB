/// Data model for the STEP-1 account contract.
///
/// The shapes mirror the FastAPI contract exactly:
/// `{account, username}` on success and
/// `{"error": {code, message, fields:[{field, code, message}]}}` on failure.
library;

/// One field-level validation reason returned by the server (HTTP 422).
class AuthFieldError {
  const AuthFieldError({
    required this.field,
    required this.code,
    required this.message,
  });

  factory AuthFieldError.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('field error must be an object');
    }
    final Object? field = json['field'];
    final Object? code = json['code'];
    final Object? message = json['message'];
    if (field is! String || code is! String || message is! String) {
      throw const FormatException('field error has missing keys');
    }
    return AuthFieldError(field: field, code: code, message: message);
  }

  final String field;
  final String code;
  final String message;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'field': field,
    'code': code,
    'message': message,
  };
}

/// An authenticated (or freshly registered) account identity.
///
/// Deliberately contains no token: the token lives in [AuthSession] only.
class AuthUser {
  const AuthUser({required this.account, required this.username});

  final String account;
  final String username;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
  };
}

/// Internal login payload. Never serialized by the local control API.
class LoginResult {
  const LoginResult({required this.user, required this.token});

  final AuthUser user;
  final String token;
}

/// A typed auth failure that can be rendered in the UI or returned on the
/// local control API without leaking internals.
class AuthFailure implements Exception {
  const AuthFailure({
    required this.status,
    required this.code,
    required this.message,
    this.fields = const <AuthFieldError>[],
  });

  /// HTTP status returned to callers (401/422 pass through; 502/504 for an
  /// unreachable or slow upstream).
  final int status;
  final String code;
  final String message;
  final List<AuthFieldError> fields;

  /// `{"error": {...}}` body shared by the server and the local control API.
  Map<String, dynamic> toEnvelope() => <String, dynamic>{
    'error': <String, dynamic>{
      'code': code,
      'message': message,
      'fields': fields.map((AuthFieldError f) => f.toJson()).toList(),
    },
  };

  @override
  String toString() => 'AuthFailure($status $code: $message)';
}

/// Upstream was unreachable (connection refused, DNS, TLS handshake).
const AuthFailure upstreamUnavailable = AuthFailure(
  status: 502,
  code: 'upstream_unavailable',
  message: '无法连接服务器，请检查服务地址或网络后重试',
);

/// Upstream did not answer in time.
const AuthFailure upstreamTimeout = AuthFailure(
  status: 504,
  code: 'upstream_timeout',
  message: '请求超时，请稍后重试',
);

/// Upstream answered with something that is not the agreed envelope.
const AuthFailure upstreamMalformed = AuthFailure(
  status: 502,
  code: 'upstream_unavailable',
  message: '服务器响应无法识别，请稍后重试',
);

/// The stored credential was rejected by `GET /auth/session`.
const AuthFailure unauthenticated = AuthFailure(
  status: 401,
  code: 'unauthenticated',
  message: '请重新登录',
);

/// Reading/writing/clearing the local session file failed.
///
/// Returned as a normal contract envelope (`500`) so the UI can explain it and
/// the local HTTP API never reports a false success.
const AuthFailure sessionStorageUnavailable = AuthFailure(
  status: 500,
  code: 'session_storage_unavailable',
  message: '会话存储不可用',
);
