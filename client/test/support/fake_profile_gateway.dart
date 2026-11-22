import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_session.dart';
import 'package:bb_client/services/avatar_source.dart';
import 'package:bb_client/services/profile_service.dart';

/// In-memory ProfileGateway used by widget tests.
class FakeProfileGateway implements ProfileGateway {
  FakeProfileGateway({
    this.profile = const Profile(
      account: '40218765',
      username: 'muse.tester',
      signature: '把日子过成自己的节奏。',
      avatarUrl: '/avatars/40218765.png',
      avatarVersion: 'v1',
    ),
  });

  Profile profile;
  Uint8List avatar = _png;

  /// Avatar bytes per account; falls back to [avatar] for unknown accounts.
  final Map<String, Uint8List> avatars = <String, Uint8List>{};
  final Map<String, int> loadAvatarByAccount = <String, int>{};
  final List<String> loadAvatarAccounts = <String>[];

  /// Variant requested on each [loadAvatar] call: lists and bubbles ask for the
  /// derivative, profile detail asks for the original.
  final List<bool> thumbCalls = <bool>[];
  AuthFailure? failure;
  AuthFailure? avatarFailure;
  AuthFailure? avatarUpdateFailure;
  Duration avatarDelay = Duration.zero;
  AuthFailure? saveFailure;

  /// Display cover returned by [loadCover]. Null keeps the contract's packaged
  /// default (the page then renders its bundled asset), which widget tests do
  /// not need to decode from the server.
  CoverImage? cover;
  AuthFailure? coverFailure;
  AuthFailure? coverUpdateFailure;
  Duration coverDelay = Duration.zero;
  int loadCoverCalls = 0;
  final List<String> coverSources = <String>[];
  final List<String?> coverViewAccounts = <String?>[];

  int loadProfileCalls = 0;
  int loadAvatarCalls = 0;
  int logoutCalls = 0;
  int heartbeatCalls = 0;
  final List<ProfilePatch> patches = <ProfilePatch>[];
  final List<String> avatarSources = <String>[];

  @override
  Future<Profile> loadProfile({String? account, AuthIdentity? captured}) async {
    loadProfileCalls += 1;
    final AuthFailure? error = failure;
    if (error != null) {
      throw error;
    }
    return profile;
  }

  @override
  Future<AvatarImage> loadAvatar({
    String? account,
    AuthIdentity? captured,
    bool thumb = false,
  }) async {
    loadAvatarCalls += 1;
    final String target = account ?? profile.account;
    loadAvatarAccounts.add(target);
    thumbCalls.add(thumb);
    loadAvatarByAccount[target] = (loadAvatarByAccount[target] ?? 0) + 1;
    if (avatarDelay > Duration.zero) {
      await Future<void>.delayed(avatarDelay);
    }
    final AuthFailure? error = avatarFailure ?? failure;
    if (error != null) {
      throw error;
    }
    final Uint8List bytes = avatars[target] ?? avatar;
    return AvatarImage(
      account: target,
      bytes: bytes,
      version: 'v-$target-${bytes.length}',
    );
  }

  @override
  Future<AvatarInfo> updateAvatarFromPath(
    String path, {
    AuthIdentity? captured,
  }) async {
    avatarSources.add('path:$path');
    return _avatarUpdate();
  }

  @override
  Future<AvatarInfo> updateAvatarFromBytes(
    Uint8List bytes, {
    AuthIdentity? captured,
  }) async {
    avatarSources.add('bytes:${bytes.length}');
    return _avatarUpdate();
  }

  @override
  Future<AvatarInfo> updateAvatarFromUrl(
    String url, {
    AuthIdentity? captured,
  }) async {
    avatarSources.add('url:$url');
    return _avatarUpdate();
  }

  @override
  Future<AvatarInfo> updateAvatarFromBase64(
    String payload, {
    AuthIdentity? captured,
  }) async {
    avatarSources.add('base64:${payload.length}');
    return _avatarUpdate();
  }

  AvatarInfo _avatarUpdate() {
    final AuthFailure? error = avatarUpdateFailure;
    if (error != null) {
      throw error;
    }
    final int next =
        (int.tryParse(profile.avatarVersion.replaceAll('v', '')) ?? 1) + 1;
    profile = Profile(
      account: profile.account,
      username: profile.username,
      signature: profile.signature,
      avatarUrl: profile.avatarUrl,
      avatarVersion: 'v$next',
    );
    return AvatarInfo(
      avatarUrl: profile.avatarUrl,
      avatarVersion: profile.avatarVersion,
    );
  }

  @override
  Future<AvatarInfo> removeAvatar({AuthIdentity? captured}) async {
    avatar = _png;
    profile = Profile(
      account: profile.account,
      username: profile.username,
      signature: profile.signature,
      avatarUrl: profile.avatarUrl,
      avatarVersion: 'v-identicon',
    );
    return AvatarInfo(
      avatarUrl: profile.avatarUrl,
      avatarVersion: profile.avatarVersion,
    );
  }

  @override
  Future<Profile> saveProfile(
    ProfilePatch patch, {
    AuthIdentity? captured,
  }) async {
    patches.add(patch);
    final AuthFailure? error = saveFailure;
    if (error != null) {
      throw error;
    }
    profile = Profile(
      account: profile.account,
      username: patch.setUsername
          ? (patch.username ?? profile.username).trim()
          : profile.username,
      signature: patch.setSignature
          ? ((patch.signature?.trim().isEmpty ?? true)
                ? null
                : patch.signature!.trim())
          : profile.signature,
      avatarUrl: profile.avatarUrl,
      avatarVersion: profile.avatarVersion,
    );
    return profile;
  }

  @override
  Future<String> viewNickname({
    String? account,
    AuthIdentity? captured,
  }) async => (await loadProfile(account: account)).username;

  @override
  Future<String?> viewSignature({
    String? account,
    AuthIdentity? captured,
  }) async => (await loadProfile(account: account)).signature;

  @override
  Future<String> updateNickname(String value, {AuthIdentity? captured}) async =>
      (await saveProfile(ProfilePatch(setUsername: true, username: value)))
          .username;

  @override
  Future<String?> updateSignature(
    String? value, {
    AuthIdentity? captured,
  }) async =>
      (await saveProfile(ProfilePatch(setSignature: true, signature: value)))
          .signature;

  @override
  Future<CoverImage> loadCover({
    String? account,
    AuthIdentity? captured,
  }) async {
    loadCoverCalls += 1;
    coverViewAccounts.add(account);
    if (coverDelay > Duration.zero) {
      await Future<void>.delayed(coverDelay);
    }
    final AuthFailure? error = coverFailure;
    if (error != null) {
      throw error;
    }
    final String target = account ?? profile.account;
    final CoverImage? current = cover;
    if (current == null) {
      // Packaged default: empty bytes tell the page to draw its bundled crop.
      return CoverImage(
        account: target,
        bytes: Uint8List(0),
        version: 'sha256-${'0' * 64}',
        mimeType: 'image/png',
        isDefault: true,
      );
    }
    return CoverImage(
      account: target,
      bytes: current.bytes,
      version: current.version,
      mimeType: current.mimeType,
      isDefault: current.isDefault,
    );
  }

  CoverInfo _coverUpdate(Uint8List bytes) {
    final AuthFailure? error = coverUpdateFailure;
    if (error != null) {
      throw error;
    }
    final String version =
        'sha256-${bytes.length.toRadixString(16).padLeft(64, '0')}';
    cover = CoverImage(
      account: profile.account,
      bytes: bytes,
      version: version,
      mimeType: detectImageMime(bytes) ?? 'image/png',
      isDefault: false,
    );
    return CoverInfo(
      coverUrl: '/covers/${profile.account}',
      coverVersion: version,
    );
  }

  @override
  Future<CoverInfo> updateCoverFromPath(
    String path, {
    AuthIdentity? captured,
  }) async {
    coverSources.add('path:$path');
    final AuthFailure? error = coverUpdateFailure;
    if (error != null) {
      throw error;
    }
    return _coverUpdate(avatar);
  }

  @override
  Future<CoverInfo> updateCoverFromBytes(
    Uint8List bytes, {
    AuthIdentity? captured,
  }) async {
    coverSources.add('bytes:${bytes.length}');
    return _coverUpdate(bytes);
  }

  @override
  Future<CoverInfo> updateCoverFromUrl(
    String url, {
    AuthIdentity? captured,
  }) async {
    coverSources.add('url:$url');
    return _coverUpdate(avatar);
  }

  @override
  Future<CoverInfo> updateCoverFromBase64(
    String payload, {
    AuthIdentity? captured,
  }) async {
    coverSources.add('base64:${payload.length}');
    final int comma = payload.indexOf(',');
    final String raw = comma >= 0 ? payload.substring(comma + 1) : payload;
    return _coverUpdate(base64Decode(raw));
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
  }

  @override
  Future<void> heartbeat() async {
    heartbeatCalls += 1;
  }
}

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
