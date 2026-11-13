import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/profile_models.dart';
import 'package:bb_client/services/auth_session.dart';
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
  AuthFailure? failure;
  AuthFailure? saveFailure;

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
  Future<AvatarImage> loadAvatar({String? account, AuthIdentity? captured}) async {
    loadAvatarCalls += 1;
    final AuthFailure? error = failure;
    if (error != null) {
      throw error;
    }
    return AvatarImage(
      account: profile.account,
      bytes: avatar,
      version: profile.avatarVersion,
    );
  }

  @override
  Future<AvatarInfo> updateAvatarFromPath(String path, {AuthIdentity? captured}) async {
    avatarSources.add('path:$path');
    return _avatarUpdate();
  }

  @override
  Future<AvatarInfo> updateAvatarFromUrl(String url, {AuthIdentity? captured}) async {
    avatarSources.add('url:$url');
    return _avatarUpdate();
  }

  @override
  Future<AvatarInfo> updateAvatarFromBase64(String payload, {AuthIdentity? captured}) async {
    avatarSources.add('base64:${payload.length}');
    return _avatarUpdate();
  }

  AvatarInfo _avatarUpdate() {
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
  Future<Profile> saveProfile(ProfilePatch patch, {AuthIdentity? captured}) async {
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
  Future<String> viewNickname({String? account, AuthIdentity? captured}) async =>
      (await loadProfile(account: account)).username;

  @override
  Future<String?> viewSignature({String? account, AuthIdentity? captured}) async =>
      (await loadProfile(account: account)).signature;

  @override
  Future<String> updateNickname(String value, {AuthIdentity? captured}) async =>
      (await saveProfile(ProfilePatch(setUsername: true, username: value)))
          .username;

  @override
  Future<String?> updateSignature(String? value, {AuthIdentity? captured}) async =>
      (await saveProfile(ProfilePatch(setSignature: true, signature: value)))
          .signature;

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
