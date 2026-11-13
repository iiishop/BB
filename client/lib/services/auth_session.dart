import '../models/auth_models.dart';
import 'client_identity.dart';

/// Immutable identity captured at the start of an in-flight client operation.
///
/// The exact token and an authentication generation distinguish a real
/// re-login from a Profile nickname refresh. A→B→A and same-account re-login
/// both change the generation, so an old request can never resume under the
/// new login.
class AuthIdentity {
  const AuthIdentity({
    required this.account,
    required this.token,
    required this.generation,
    required this.authGeneration,
  });

  final String account;
  final String token;
  final int generation;

  /// Opaque generation issued by [AuthSession.establish]. Unlike [generation]
  /// it is a random string, so a later process can never mint the same value
  /// by restarting a counter at zero.
  final String authGeneration;

  bool sameAs(AuthIdentity? other) {
    return other != null &&
        other.account == account &&
        other.token == token &&
        other.authGeneration == authGeneration;
  }
}

/// In-memory client session.
///
/// The server token is held here, never in a widget and never in a local control
/// API response. This step defines no token refresh or persistence policy, so a
/// process exit simply drops the session (matching the plugin contract that no
/// login state survives it).
class AuthSession {
  String? _token;
  AuthUser? _user;
  int _generation = 0;

  /// Opaque value rotated on every establish/clear. It is what v2 clients send
  /// as `auth_generation`; an old value is never valid again.
  String? _authGeneration;

  bool get hasToken => _token != null;

  AuthUser? get user => _user;

  /// Authentication generation changes only on establish/clear, never on
  /// [updateUser] (Profile nickname refresh is not a new authentication).
  int get generation => _generation;

  String? get authGeneration => _authGeneration;

  AuthIdentity? get identity {
    final String? token = _token;
    final AuthUser? user = _user;
    final String? authGeneration = _authGeneration;
    if (token == null ||
        token.isEmpty ||
        user == null ||
        authGeneration == null) {
      return null;
    }
    return AuthIdentity(
      account: user.account,
      token: token,
      generation: _generation,
      authGeneration: authGeneration,
    );
  }

  bool isCurrent(AuthIdentity? captured) => captured?.sameAs(identity) ?? false;

  /// Attaches the server token to the account it belongs to.
  void establish({
    required String token,
    required AuthUser user,
    int? generation,
  }) {
    if (token.isEmpty) {
      throw ArgumentError.value(token, 'token', 'token 不能为空');
    }
    _token = token;
    _user = user;
    _generation = (generation != null && generation > _generation)
        ? generation
        : _generation + 1;
    _authGeneration = newAuthGeneration();
  }

  /// Credential for future authenticated requests. Not for serialization.
  String? get tokenForRequest => _token;

  /// Refreshes the cached identity after a Profile edit (nickname == username).
  ///
  /// Deliberately does not bump the authentication generation: this is the same
  /// login, only refreshed display metadata.
  void updateUser(AuthUser user) {
    if (_token != null) {
      _user = user;
    }
  }

  void clear() {
    _token = null;
    _user = null;
    _generation += 1;
    _authGeneration = null;
  }
}
