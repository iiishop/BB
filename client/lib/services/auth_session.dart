import '../models/auth_models.dart';

/// In-memory client session.
///
/// The server token is held here, never in a widget and never in a local control
/// API response. This step defines no token refresh or persistence policy, so a
/// process exit simply drops the session (matching the plugin contract that no
/// login state survives it).
class AuthSession {
  String? _token;
  AuthUser? _user;

  bool get hasToken => _token != null;

  AuthUser? get user => _user;

  /// Attaches the server token to the account it belongs to.
  void establish({required String token, required AuthUser user}) {
    if (token.isEmpty) {
      throw ArgumentError.value(token, 'token', 'token 不能为空');
    }
    _token = token;
    _user = user;
  }

  /// Credential for future authenticated requests. Not for serialization.
  String? get tokenForRequest => _token;

  void clear() {
    _token = null;
    _user = null;
  }
}
