import 'dart:typed_data';

import '../models/auth_models.dart';
import '../models/profile_models.dart';
import '../validation/profile_rules.dart';
import 'auth_service.dart';
import 'auth_session.dart';
import 'install_safety_gate.dart';
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
  /// `thumb: true` asks for the small derivative (lists, bubbles, rail).
  /// Profile detail keeps the original so the avatar is sharp at full size.
  Future<AvatarImage> loadAvatar({
    String? account,
    AuthIdentity? captured,
    bool thumb = false,
  });

  /// Always revalidates the display cover with the server. Cached bytes are
  /// reused on 304; the packaged default is returned by the server for accounts
  /// without an uploaded cover.
  Future<CoverImage> loadCover({String? account, AuthIdentity? captured});

  Future<CoverInfo> updateCoverFromPath(String path, {AuthIdentity? captured});

  Future<CoverInfo> updateCoverFromBytes(
    Uint8List bytes, {
    AuthIdentity? captured,
  });

  Future<CoverInfo> updateCoverFromUrl(String url, {AuthIdentity? captured});

  Future<CoverInfo> updateCoverFromBase64(
    String payload, {
    AuthIdentity? captured,
  });

  Future<AvatarInfo> updateAvatarFromPath(
    String path, {
    AuthIdentity? captured,
  });

  /// Uploads image bytes the platform already handed back, e.g. Android's
  /// document picker copy of a content URI that has no usable path. Validation
  /// and upload are the same chain as [updateAvatarFromPath].
  Future<AvatarInfo> updateAvatarFromBytes(
    Uint8List bytes, {
    AuthIdentity? captured,
  });

  Future<AvatarInfo> updateAvatarFromUrl(String url, {AuthIdentity? captured});

  Future<AvatarInfo> updateAvatarFromBase64(
    String payload, {
    AuthIdentity? captured,
  });

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
    AvatarCacheStore? coverCache,
    AvatarSourceReader? sources,
  }) : cache = cache ?? AvatarCache(),
       coverCache = coverCache ?? AvatarCache(),
       sources = sources ?? DefaultAvatarSourceReader();

  final ProfileApiClient api;
  final AuthService auth;
  final AvatarCacheStore cache;

  /// Separate store: the cover and the avatar are different bytes with their
  /// own versions, so they must never share a cache key.
  final AvatarCacheStore coverCache;
  final AvatarSourceReader sources;

  /// Last successful cover metadata per account. A 304 reuses the cached bytes,
  /// but the mime type and default flag are not part of the byte cache, so the
  /// gateway remembers them for the process (and refetches if it cannot).
  final Map<String, ({String mimeType, bool isDefault})> _coverMeta =
      <String, ({String mimeType, bool isDefault})>{};

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
  Future<AvatarImage> loadAvatar({
    String? account,
    AuthIdentity? captured,
    bool thumb = false,
  }) async {
    final String target = _account(account, captured);
    final String token = _token(captured);
    CachedAvatar? cached = await cache.read(target, thumb: thumb);
    AvatarFetch fetched = await api.fetchAvatar(
      token: token,
      account: target,
      ifNoneMatch: cached?.version,
      thumb: thumb,
    );
    _ensureCurrent(captured);
    if (fetched.notModified) {
      if (cached == null) {
        // Defensive: a 304 without a usable cache entry must not produce an
        // empty image; ask the server for the bytes again.
        fetched = await api.fetchAvatar(
          token: token,
          account: target,
          thumb: thumb,
        );
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
    await cache.write(target, fetched.bytes, fetched.version, thumb: thumb);
    return AvatarImage(
      account: target,
      bytes: fetched.bytes,
      version: fetched.version,
    );
  }

  @override
  Future<CoverImage> loadCover({
    String? account,
    AuthIdentity? captured,
  }) async {
    final String target = _account(account, captured);
    final String token = _token(captured);
    final CachedAvatar? cached = await coverCache.read(target);
    CoverFetch fetched = await api.fetchCover(
      token: token,
      account: target,
      ifNoneMatch: cached?.version,
    );
    _ensureCurrent(captured);
    if (fetched.notModified) {
      final ({String mimeType, bool isDefault})? meta = _coverMeta[target];
      if (cached == null || meta == null) {
        // A 304 without the bytes or without the response metadata cannot be
        // materialized correctly; ask once for the full response.
        fetched = await api.fetchCover(token: token, account: target);
        _ensureCurrent(captured);
      } else {
        return CoverImage(
          account: target,
          bytes: cached.bytes,
          version: cached.version,
          mimeType: meta.mimeType,
          isDefault: meta.isDefault,
        );
      }
    }
    if (fetched.bytes.isEmpty) {
      throw upstreamMalformed;
    }
    _ensureCurrent(captured);
    _coverMeta[target] = (
      mimeType: fetched.mimeType,
      isDefault: fetched.isDefault,
    );
    await coverCache.write(target, fetched.bytes, fetched.version);
    return CoverImage(
      account: target,
      bytes: fetched.bytes,
      version: fetched.version,
      mimeType: fetched.mimeType,
      isDefault: fetched.isDefault,
    );
  }

  @override
  Future<CoverInfo> updateCoverFromPath(
    String path, {
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(
    () => _updateCoverFromPath(path, captured: captured),
  );

  Future<CoverInfo> _updateCoverFromPath(
    String path, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readPath(
      path,
      maxBytes: ProfileApiClient.maxCoverUploadBytes,
    );
    return _uploadCover(bytes, captured);
  }

  @override
  Future<CoverInfo> updateCoverFromBytes(
    Uint8List bytes, {
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(() => _uploadCover(bytes, captured));

  @override
  Future<CoverInfo> updateCoverFromUrl(String url, {AuthIdentity? captured}) =>
      InstallSafetyGate.instance.protect(
        () => _updateCoverFromUrl(url, captured: captured),
      );

  Future<CoverInfo> _updateCoverFromUrl(
    String url, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readUrl(
      url,
      maxBytes: ProfileApiClient.maxCoverUploadBytes,
    );
    return _uploadCover(bytes, captured);
  }

  @override
  Future<CoverInfo> updateCoverFromBase64(
    String payload, {
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(
    () => _updateCoverFromBase64(payload, captured: captured),
  );

  Future<CoverInfo> _updateCoverFromBase64(
    String payload, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readBase64(
      payload,
      maxBytes: ProfileApiClient.maxCoverUploadBytes,
    );
    return _uploadCover(bytes, captured);
  }

  Future<CoverInfo> _uploadCover(
    Uint8List bytes,
    AuthIdentity? captured,
  ) async {
    final String account = _account(null, captured);
    _validateCoverBytes(bytes);
    final CoverInfo info = await api.uploadCover(
      token: _token(captured),
      bytes: bytes,
    );
    _ensureCurrent(captured);
    // The server renders the display image; never keep the uploaded source.
    await coverCache.invalidate(account);
    _coverMeta.remove(account);
    return info;
  }

  void _validateCoverBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const AuthFailure(
        status: 422,
        code: 'validation_error',
        message: '封面内容为空',
      );
    }
    if (bytes.length > ProfileApiClient.maxCoverUploadBytes) {
      throw const AuthFailure(
        status: 413,
        code: 'payload_too_large',
        message: '封面超过 8 MB 上限',
      );
    }
    if (detectImageMime(bytes) == null) {
      throw const AuthFailure(
        status: 415,
        code: 'unsupported_media_type',
        message: '仅支持 PNG、JPEG 或 WebP 图片',
      );
    }
  }

  @override
  Future<AvatarInfo> updateAvatarFromPath(
    String path, {
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(
    () => _updateAvatarFromPath(path, captured: captured),
  );

  Future<AvatarInfo> _updateAvatarFromPath(
    String path, {
    AuthIdentity? captured,
  }) async {
    final Uint8List bytes = await sources.readPath(path);
    return _upload(bytes, captured);
  }

  @override
  Future<AvatarInfo> updateAvatarFromBytes(
    Uint8List bytes, {
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(() => _upload(bytes, captured));

  @override
  Future<AvatarInfo> updateAvatarFromUrl(
    String url, {
    AuthIdentity? captured,
  }) => InstallSafetyGate.instance.protect(
    () => _updateAvatarFromUrl(url, captured: captured),
  );

  Future<AvatarInfo> _updateAvatarFromUrl(
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
  }) => InstallSafetyGate.instance.protect(
    () => _updateAvatarFromBase64(payload, captured: captured),
  );

  Future<AvatarInfo> _updateAvatarFromBase64(
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
  Future<Profile> saveProfile(ProfilePatch patch, {AuthIdentity? captured}) =>
      InstallSafetyGate.instance.protect(
        () => _saveProfile(patch, captured: captured),
      );

  Future<Profile> _saveProfile(
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
  Future<String?> viewSignature({
    String? account,
    AuthIdentity? captured,
  }) async {
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
  Future<String?> updateSignature(
    String? value, {
    AuthIdentity? captured,
  }) async {
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
