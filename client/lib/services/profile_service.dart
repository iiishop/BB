import 'dart:typed_data';

import '../models/auth_models.dart';
import '../models/profile_models.dart';
import '../validation/profile_rules.dart';
import 'auth_service.dart';
import 'auth_session.dart';
import 'avatar_cache.dart';
import 'avatar_source.dart';
import 'client_identity.dart';
import 'profile_api_client.dart';

/// The Profile surface shared by the Flutter UI and the local control API.
///
/// One implementation means the MCP tools and the panels exercise the same
/// validation, cache revalidation and server calls.
abstract class ProfileGateway {
  Future<Profile> loadProfile({String? account, AuthIdentity? captured});

  /// Always revalidates with the server. Cached bytes are reused only on 304.
  Future<AvatarImage> loadAvatar({String? account, AuthIdentity? captured});

  Future<AvatarInfo> updateAvatarFromPath(String path, {AuthIdentity? captured});

  Future<AvatarInfo> updateAvatarFromUrl(String url, {AuthIdentity? captured});

  Future<AvatarInfo> updateAvatarFromBase64(String payload, {AuthIdentity? captured});

  Future<AvatarInfo> removeAvatar({AuthIdentity? captured});

  Future<Profile> saveProfile(ProfilePatch patch, {AuthIdentity? captured});

  Future<String> viewNickname({String? account, AuthIdentity? captured});

  Future<String?> viewSignature({String? account, AuthIdentity? captured});

  Future<String> updateNickname(String value, {AuthIdentity? captured});

  Future<String?> updateSignature(String? value, {AuthIdentity? captured});

  Future<void> logout();

  Future<void> heartbeat();
}

/// Default gateway: server HTTP + authenticated session + avatar cache.
class ProfileService implements ProfileGateway {
  ProfileService({
    required this.api,
    required this.auth,
    AvatarCacheStore? cache,
    AvatarSourceReader? sources,
  }) : cache = cache ?? AvatarCache(),
       sources = sources ?? DefaultAvatarSourceReader();

  final ProfileApiClient api;
  final AuthService auth;
  final AvatarCacheStore cache;
  final AvatarSourceReader sources;

  /// The request-scoped credential. When [captured] is supplied the caller's
  /// immutable identity/token is used, never the mutable current session.
  String _token(AuthIdentity? captured) {
    if (captured != null) {
      _ensureCurrent(captured);
      return captured.token;
    }
    final String? token = auth.session.tokenForRequest;
    if (token == null) {
      throw unauthenticated;
    }
    return token;
  }

  String _account(String? account, AuthIdentity? captured) {
    final String? normalized = normalizeAccount(account);
    if (normalized != null) {
      return normalized;
    }
    if (captured != null) {
      _ensureCurrent(captured);
      return captured.account;
    }
    final AuthUser? user = auth.session.user;
    if (user == null || !auth.session.hasToken) {
      throw unauthenticated;
    }
    return user.account;
  }

  void _ensureCurrent(AuthIdentity? captured) {
    if (captured != null && !auth.session.isCurrent(captured)) {
      throw staleIdentity;
    }
  }

  @override
  Future<Profile> loadProfile({String? account, AuthIdentity? captured}) async {
    final String token = _token(captured);
    final Profile profile = await api.fetchProfile(
      token: token,
      account: _account(account, captured),
    );
    _ensureCurrent(captured);
    if (profile.account == auth.session.user?.account &&
        profile.username != auth.session.user?.username) {
      await auth.rememberUser(
        AuthUser(account: profile.account, username: profile.username),
      );
    }
    return profile;
  }

  @override
  Future<AvatarImage> loadAvatar({String? account, AuthIdentity? captured}) async {
    final String target = _account(account, captured);
    final String token = _token(captured);
    CachedAvatar? cached = await cache.read(target);
    AvatarFetch fetched = await api.fetchAvatar(
      token: token,
      account: target,
      ifNoneMatch: cached?.version,
    );
    _ensureCurrent(captured);
    if (fetched.notModified) {
      if (cached == null) {
        // Defensive: a 304 without a usable cache entry must not produce an
        // empty image; ask the server for the bytes again.
        fetched = await api.fetchAvatar(token: token, account: target);
      } else {
        return AvatarImage(
          account: target,
          bytes: cached.bytes,
          version: cached.version,
        );
      }
    }
    if (fetched.bytes.isEmpty) {
      throw upstreamMalformed;
    }
    _ensureCurrent(captured);
    await cache.write(target, fetched.bytes, fetched.version);
    return AvatarImage(
      account: target,
      bytes: fetched.bytes,
      version: fetched.version,
    );
  }

  @override
  Future<AvatarInfo> updateAvatarFromPath(
    String path, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readPath(path);
    return _upload(bytes, captured);
  }

  @override
  Future<AvatarInfo> updateAvatarFromUrl(
    String url, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readUrl(url);
    return _upload(bytes, captured);
  }

  @override
  Future<AvatarInfo> updateAvatarFromBase64(
    String payload, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readBase64(payload);
    return _upload(bytes, captured);
  }

  @override
  Future<AvatarInfo> removeAvatar({AuthIdentity? captured}) async {
    final String account = _account(null, captured);
    final AvatarInfo info = await api.deleteAvatar(token: _token(captured));
    _ensureCurrent(captured);
    await cache.invalidate(account);
    return info;
  }

  Future<AvatarInfo> _upload(Uint8List bytes, AuthIdentity? captured) async {
    final String account = _account(null, captured);
    validateAvatarBytes(bytes, sourceField: 'body');
    final AvatarInfo info = await api.uploadAvatar(
      token: _token(captured),
      bytes: bytes,
    );
    _ensureCurrent(captured);
    // The server re-encodes the upload; never keep the pre-normalized bytes.
    await cache.invalidate(account);
    return info;
  }

  @override
  Future<Profile> saveProfile(
    ProfilePatch patch, {
    AuthIdentity? captured,
  }) async {
    final ProfilePatch normalized = ProfilePatch(
      setUsername: patch.setUsername,
      username: patch.setUsername ? normalizeUsername(patch.username) : null,
      setSignature: patch.setSignature,
      signature: patch.setSignature
          ? normalizeSignature(patch.signature)
          : null,
    );
    final Profile profile = await api.patchProfile(
      token: _token(captured),
      patch: normalized,
    );
    _ensureCurrent(captured);
    if (profile.account == auth.session.user?.account &&
        (captured == null || auth.session.isCurrent(captured))) {
      await auth.rememberUser(
        AuthUser(account: profile.account, username: profile.username),
      );
    }
    return profile;
  }

  @override
  Future<String> viewNickname({String? account, AuthIdentity? captured}) async {
    return (await loadProfile(account: account, captured: captured)).username;
  }

  @override
  Future<String?> viewSignature({String? account, AuthIdentity? captured}) async {
    return (await loadProfile(account: account, captured: captured)).signature;
  }

  @override
  Future<String> updateNickname(String value, {AuthIdentity? captured}) async {
    final Profile profile = await saveProfile(
      ProfilePatch(setUsername: true, username: value),
      captured: captured,
    );
    return profile.username;
  }

  @override
  Future<String?> updateSignature(String? value, {AuthIdentity? captured}) async {
    final Profile profile = await saveProfile(
      ProfilePatch(setSignature: true, signature: value),
      captured: captured,
    );
    return profile.signature;
  }

  @override
  Future<void> logout() async {
    await auth.logout();
  }

  @override
  Future<void> heartbeat() async {
    await auth.api.heartbeat(_token(null));
  }
}
