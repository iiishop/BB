import '../models/auth_models.dart';

/// STEP-2 value rules shared by the Flutter UI and the local control API.
///
/// The server is the source of truth; these checks run before a request is made
/// so the same 422 envelopes appear in the UI and through MCP. Lengths are
/// Unicode code points (`String.runes`), matching Python `len` and NOT UTF-16
/// units or grapheme clusters.

/// Minimum nickname length in code points (server STEP-1 rule).
const int usernameMinCodePoints = 3;

/// Maximum nickname length in code points (server STEP-1 rule).
const int usernameMaxCodePoints = 24;

/// Maximum signature length in code points.
const int signatureMaxCodePoints = 49;

/// Number of Unicode code points in [value].
int codePointLength(String value) => value.runes.length;

AuthFailure _invalid(String field, String code, String message) {
  return AuthFailure(
    status: 422,
    code: 'validation_error',
    message: '输入有误',
    fields: <AuthFieldError>[
      AuthFieldError(field: field, code: code, message: message),
    ],
  );
}

/// Trims and validates a nickname, returning the value to send.
///
/// Null is a type error: `PATCH` omission preserves the field, an explicit null
/// must not silently mean "keep" or "clear".
String normalizeUsername(String? raw) {
  if (raw == null) {
    throw _invalid('username', 'type', '字段类型错误');
  }
  final String trimmed = raw.trim();
  final int length = codePointLength(trimmed);
  if (length < usernameMinCodePoints || length > usernameMaxCodePoints) {
    throw _invalid('username', 'length', '昵称去除首尾空白后须为 3–24 字符');
  }
  return trimmed;
}

/// Trims and validates a signature.
///
/// Missing, null and whitespace-only all clear the signature (`null`).
String? normalizeSignature(String? raw) {
  final String? trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (codePointLength(trimmed) > signatureMaxCodePoints) {
    throw _invalid('signature', 'length', '签名去除首尾空白后最多 49 字符');
  }
  return trimmed;
}

/// `account` from a tool/UI call: absent/null means the current session.
///
/// Specified accounts are eight ASCII digits; full-width digits are rejected
/// exactly like the shared contract cases.
String? normalizeAccount(String? raw) {
  if (raw == null) {
    return null;
  }
  if (!RegExp(r'^[0-9]{8}$').hasMatch(raw)) {
    throw _invalid('account', 'format', '账号必须为 8 位数字');
  }
  return raw;
}

/// True when [path] is absolute on POSIX or Windows.
bool isAbsoluteAvatarPath(String path) {
  if (path.startsWith('/')) {
    return true;
  }
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) {
    return true;
  }
  return RegExp(r'^\\\\').hasMatch(path);
}

/// True when [raw] is an absolute http/https URL without embedded credentials.
bool isSupportedAvatarUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  // A malformed port makes `Uri` throw when accessed; treat it as invalid.
  try {
    uri.port;
  } on FormatException {
    return false;
  }
  return true;
}

/// The allowed `update_avatar` source keys, in contract order.
const List<String> avatarSourceKeys = <String>['path', 'url', 'base64'];

/// Resolves the one and only supplied avatar source.
///
/// Keys count even when their value is null: `{"base64":"x","path":null}` is
/// ambiguous and must fail with `one_source`, never guess.
({String source, String value}) resolveAvatarSource(Map<String, dynamic> body) {
  final List<String> supplied = avatarSourceKeys
      .where(body.containsKey)
      .toList(growable: false);
  if (supplied.length != 1) {
    throw _invalid('body', 'one_source', 'path、url、base64 必须且只能提供一个');
  }
  final String source = supplied.single;
  final Object? raw = body[source];
  if (raw is! String || raw.isEmpty) {
    throw _invalid(source, 'required', '此字段必填');
  }
  if (source == 'path' && !isAbsoluteAvatarPath(raw)) {
    throw _invalid('path', 'format', '必须为本机绝对路径');
  }
  if (source == 'url' && !isSupportedAvatarUrl(raw)) {
    throw _invalid('url', 'format', '必须为有效 http/https URL');
  }
  return (source: source, value: raw);
}
