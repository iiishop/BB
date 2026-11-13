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

  /// Server-side logout followed by the local credential clear.
  ///
  /// Default keeps STEP-1 gateways working (local-only logout); [AuthService]
  /// overrides it to call `POST /auth/logout`.
  Future<LogoutResult> logout() async {
    await signOut();
    return const LogoutResult(serverNotified: false);
  }
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
    final int generation = store?.nextGeneration() ?? session.generation + 1;
    session.establish(
      token: result.token,
      user: result.user,
      generation: generation,
    );
    try {
      await _persist(result.user, result.token, generation: generation);
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
      final int generation = stored.generation > 0
          ? stored.generation
          : (store.nextGeneration());
      session.establish(
        token: stored.token,
        user: user,
        generation: generation,
      );
      if (user.account != stored.account || user.username != stored.username) {
        await _persist(user, stored.token, generation: session.generation);
      }
      return user;
    } on AuthFailure catch (failure) {
      if (failure.status == 401) {
        // Only invalidate the token this restore was validating. A login that
        // completed while the request/file operation was in flight wins.
        try {
          await signOut(expectedToken: stored.token);
        } on AuthFailure catch (clearFailure) {
          if (clearFailure.code == sessionStorageUnavailable.code) {
            rethrow;
          }
          if (session.tokenForRequest == stored.token) {
            session.clear();
          }
        }
      }
      rethrow;
    } on SessionStorageException {
      if (session.tokenForRequest == stored.token) {
        session.clear();
      }
      throw sessionStorageUnavailable;
    }
  }

  @override
  Future<void> signOut({String? expectedToken}) async {
    final String? currentToken = session.tokenForRequest;
    // A token-aware invalidation may target a stored credential that was never
    // established in memory (restoreSession's 401 path).
    final String? oldToken = expectedToken ?? currentToken;
    if (oldToken == null) {
      return;
    }
    // The token-aware caller must not clear a login that replaced this one
    // before sign-out began.
    if (expectedToken != null &&
        currentToken != null &&
        currentToken != expectedToken) {
      return;
    }
    final SessionStore? store = this.store;
    try {
      if (store != null) {
        await store.clear();
      }
      // A new login may have completed while the deletion was in flight. Its
      // file can have been removed by that deletion; restore it before the
      // conditional memory commit below.
      await _repersistNewLogin(oldToken);
    } on SessionStorageException {
      await _repersistNewLogin(oldToken);
      throw sessionStorageUnavailable;
    }
    // Clear only the credential this sign-out owned. A new login that
    // committed during the await must survive in memory too.
    if (session.tokenForRequest == oldToken) {
      session.clear();
    }
  }

  /// A login completed while the old credential's deletion was awaited. Its
  /// file may have been removed by that deletion; rewrite the current session
  /// so memory and disk agree. Never touches a newer/absent session.
  Future<void> _repersistNewLogin(String oldToken) async {
    // The repair write itself is asynchronous. A later login may complete
    // while it is in flight; after every write, verify that the token on disk
    // is still the current one and rewrite the latest login if not. Bounded
    // so a continuous login stream cannot spin forever; the final best-effort
    // write still gives the current credential the last word.
    for (int attempt = 0; attempt < 4; attempt++) {
      final String? token = session.tokenForRequest;
      final AuthUser? user = session.user;
      if (token == null || token == oldToken || user == null) {
        return;
      }
      try {
        await _persist(user, token, generation: session.generation);
      } on SessionStorageException {
        // The in-memory login is valid; a later persist/restart retries the
        // disk copy rather than clearing it.
        return;
      }
      if (session.tokenForRequest == token) {
        return;
      }
    }
    final String? latestToken = session.tokenForRequest;
    final AuthUser? latestUser = session.user;
    if (latestToken == null || latestToken == oldToken || latestUser == null) {
      return;
    }
    try {
      await _persist(
        latestUser,
        latestToken,
        generation: session.generation,
      );
    } on SessionStorageException {
      // Keep the in-memory login; disk can be repaired by the next login.
    }
  }

  /// Updates the cached identity after a successful profile edit.
  ///
  /// Best effort on disk: the server change already happened, so a storage
  /// fault must not turn a successful nickname update into an error.
  Future<void> rememberUser(AuthUser user) async {
    session.updateUser(user);
    final String? token = session.tokenForRequest;
    if (token == null) {
      return;
    }
    try {
      await _persist(user, token, generation: session.generation);
    } on SessionStorageException {
      // The in-memory identity is correct; a restart re-reads the server.
    }
  }

  @override
  Future<LogoutResult> logout() async {
    final String? token = session.tokenForRequest;
    bool serverNotified = false;
    AuthFailure? warning;
    if (token != null) {
      try {
        await api.logout(token);
        serverNotified = true;
      } on AuthFailure catch (failure) {
        if (failure.status == 401) {
          // The session was already invalid; local cleanup is still correct.
          serverNotified = true;
        } else {
          // Network/timeout: keep the credential only if the local clear fails.
          warning = failure;
        }
      }
    }
    await signOut();
    return LogoutResult(serverNotified: serverNotified, warning: warning);
  }

  Future<void> _persist(
    AuthUser user,
    String token, {
    int? generation,
  }) async {
    final SessionStore? store = this.store;
    if (store == null) {
      return;
    }
    await store.write(
      PersistedSession(
        account: user.account,
        username: user.username,
        token: token,
        generation: generation ?? session.generation,
      ),
    );
  }
}
