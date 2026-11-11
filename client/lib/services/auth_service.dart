import '../models/auth_models.dart';
import 'auth_api_client.dart';
import 'auth_session.dart';
import 'session_store.dart';

/// The client-side auth surface shared by the Flutter UI and the local control
/// API. One implementation, one set of DTOs, one error model, one session store.
abstract class AuthGateway {
  /// Registers an account and returns the server-assigned identity.
  Future<AuthUser> register({
    required String username,
    required String password,
  });

  /// Logs in with the assigned account, stores the token in the client session
  /// (and on disk) and returns the identity only.
  Future<AuthUser> login({required String account, required String password});

  /// Restores a persisted credential and verifies it with `GET /auth/session`.
  ///
  /// Returns null when nothing is stored. A 401 clears the stored credential;
  /// a network/timeout failure keeps it and rethrows so the caller can show
  /// "暂时无法验证" instead of pretending the session is valid.
  Future<AuthUser?> restoreSession();

  /// Drops the in-memory session and the stored credential.
  Future<void> signOut();
}

/// Default gateway: talks to the FastAPI service, owns the session and its
/// on-disk copy.
class AuthService implements AuthGateway {
  AuthService({required this.api, required this.session, this.store});

  final AuthApiClient api;
  final AuthSession session;
  final SessionStore? store;

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
    try {
      await _persist(result.user, result.token);
    } on SessionStorageException {
      // Login succeeded at the server, but the restart capability did not. Do
      // not report success: drop the half-established session so the caller
      // cannot mistake it for a durable login.
      session.clear();
      throw sessionStorageUnavailable;
    }
    return result.user;
  }

  @override
  Future<AuthUser?> restoreSession() async {
    final SessionStore? store = this.store;
    if (store == null) {
      return null;
    }
    final PersistedSession? stored;
    try {
      stored = await store.read();
    } on SessionStorageException {
      session.clear();
      throw sessionStorageUnavailable;
    }
    if (stored == null) {
      return null;
    }
    try {
      final AuthUser user = await api.fetchSession(stored.token);
      session.establish(token: stored.token, user: user);
      if (user.account != stored.account || user.username != stored.username) {
        await _persist(user, stored.token);
      }
      return user;
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        try {
          await store.clear();
        } on SessionStorageException {
          session.clear();
          // The credential is invalid but the stale file could not be removed;
          // report the storage fault instead of claiming a clean logout.
          throw sessionStorageUnavailable;
        }
        session.clear();
      }
      rethrow;
    } on SessionStorageException {
      session.clear();
      throw sessionStorageUnavailable;
    }
  }

  @override
  Future<void> signOut() async {
    final SessionStore? store = this.store;
    if (store != null) {
      try {
        await store.clear();
      } on SessionStorageException {
        // Keep the in-memory session: reporting a logout that a restart would
        // undo is worse than surfacing the storage fault.
        throw sessionStorageUnavailable;
      }
    }
    session.clear();
  }

  Future<void> _persist(AuthUser user, String token) async {
    final SessionStore? store = this.store;
    if (store == null) {
      return;
    }
    await store.write(
      PersistedSession(
        account: user.account,
        username: user.username,
        token: token,
      ),
    );
  }
}
