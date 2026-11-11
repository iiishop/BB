import '../models/auth_models.dart';
import 'auth_api_client.dart';
import 'auth_session.dart';

/// The client-side auth surface shared by the Flutter UI and the local control
/// API. One implementation, one set of DTOs, one error model.
abstract class AuthGateway {
  /// Registers an account and returns the server-assigned identity.
  Future<AuthUser> register({
    required String username,
    required String password,
  });

  /// Logs in with the assigned account, stores the token in the client session
  /// and returns the identity only.
  Future<AuthUser> login({required String account, required String password});

  /// Drops the in-memory session.
  void signOut();
}

/// Default gateway: talks to the FastAPI service and owns the client session.
class AuthService implements AuthGateway {
  AuthService({required this.api, required this.session});

  final AuthApiClient api;
  final AuthSession session;

  @override
  Future<AuthUser> register({
    required String username,
    required String password,
  }) {
    return api.register(username: username.trim(), password: password);
  }

  @override
  Future<AuthUser> login({
    required String account,
    required String password,
  }) async {
    final LoginResult result = await api.login(
      account: account.trim(),
      password: password,
    );
    session.establish(token: result.token, user: result.user);
    return result.user;
  }

  @override
  void signOut() {
    session.clear();
  }
}
