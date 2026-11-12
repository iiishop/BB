import 'dart:typed_data';

import '../models/auth_models.dart';
import '../models/profile_models.dart';
import '../validation/profile_rules.dart';
import 'auth_service.dart';
import 'avatar_cache.dart';
import 'avatar_source.dart';
import 'profile_api_client.dart';

/// The Profile surface shared by the Flutter UI and the local control API.
///
/// One implementation means the MCP tools and the panels exercise the same
/// validation, cache revalidation and server calls.
abstract class ProfileGateway {
  Future<Profile> loadProfile({String? account});

  /// Always revalidates with the server. Cached bytes are reused only on 304.
  Future<AvatarImage> loadAvatar({String? account});

  Future<AvatarInfo> updateAvatarFromPath(String path);

  Future<AvatarInfo> updateAvatarFromUrl(String url);

  Future<AvatarInfo> updateAvatarFromBase64(String payload);

  Future<AvatarInfo> removeAvatar();

  Future<Profile> saveProfile(ProfilePatch patch);

  Future<String> viewNickname({String? account});

  Future<String?> viewSignature({String? account});

  Future<String> updateNickname(String value);

  Future<String?> updateSignature(String? value);

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

  String get _token {
    final String? token = auth.session.tokenForRequest;
    if (token == null) {
      throw unauthenticated;
    }
    return token;
  }

  String _account(String? account) {
    final String? normalized = normalizeAccount(account);
    if (normalized != null) {
      return normalized;
    }
    final AuthUser? user = auth.session.user;
    if (user == null || !auth.session.hasToken) {
      throw unauthenticated;
    }
    return user.account;
  }

  @override
  Future<Profile> loadProfile({String? account}) async {
    final Profile profile = await api.fetchProfile(
      token: _token,
      account: _account(account),
    );
    if (profile.account == auth.session.user?.account &&
        profile.username != auth.session.user?.username) {
      await auth.rememberUser(
        AuthUser(account: profile.account, username: profile.username),
      );
    }
    return profile;
  }

  @override
  Future<AvatarImage> loadAvatar({String? account}) async {
    final String target = _account(account);
    final String token = _token;
    CachedAvatar? cached = await cache.read(target);
    AvatarFetch fetched = await api.fetchAvatar(
      token: token,
      account: target,
      ifNoneMatch: cached?.version,
    );
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
    await cache.write(target, fetched.bytes, fetched.version);
    return AvatarImage(
      account: target,
      bytes: fetched.bytes,
      version: fetched.version,
    );
  }

  @override
  Future<AvatarInfo> updateAvatarFromPath(String path) async {
    final Uint8List bytes = await sources.readPath(path);
    return _upload(bytes);
  }

  @override
  Future<AvatarInfo> updateAvatarFromUrl(String url) async {
    final Uint8List bytes = await sources.readUrl(url);
    return _upload(bytes);
  }

  @override
  Future<AvatarInfo> updateAvatarFromBase64(String payload) async {
    final Uint8List bytes = await sources.readBase64(payload);
    return _upload(bytes);
  }

  @override
  Future<AvatarInfo> removeAvatar() async {
    final String account = _account(null);
    final AvatarInfo info = await api.deleteAvatar(token: _token);
    await cache.invalidate(account);
    return info;
  }

  Future<AvatarInfo> _upload(Uint8List bytes) async {
    final String account = _account(null);
    validateAvatarBytes(bytes, sourceField: 'body');
    final AvatarInfo info = await api.uploadAvatar(token: _token, bytes: bytes);
    // The server re-encodes the upload; never keep the pre-normalized bytes.
    await cache.invalidate(account);
    return info;
  }

  @override
  Future<Profile> saveProfile(ProfilePatch patch) async {
    final ProfilePatch normalized = ProfilePatch(
      setUsername: patch.setUsername,
      username: patch.setUsername ? normalizeUsername(patch.username) : null,
      setSignature: patch.setSignature,
      signature: patch.setSignature
          ? normalizeSignature(patch.signature)
          : null,
    );
    final Profile profile = await api.patchProfile(
      token: _token,
      patch: normalized,
    );
    if (profile.account == auth.session.user?.account) {
      await auth.rememberUser(
        AuthUser(account: profile.account, username: profile.username),
      );
    }
    return profile;
  }

  @override
  Future<String> viewNickname({String? account}) async {
    return (await loadProfile(account: account)).username;
  }

  @override
  Future<String?> viewSignature({String? account}) async {
    return (await loadProfile(account: account)).signature;
  }

  @override
  Future<String> updateNickname(String value) async {
    final Profile profile = await saveProfile(
      ProfilePatch(setUsername: true, username: value),
    );
    return profile.username;
  }

  @override
  Future<String?> updateSignature(String? value) async {
    final Profile profile = await saveProfile(
      ProfilePatch(setSignature: true, signature: value),
    );
    return profile.signature;
  }

  @override
  Future<void> logout() async {
    await auth.logout();
  }

  @override
  Future<void> heartbeat() async {
    await auth.api.heartbeat(_token);
  }
}
