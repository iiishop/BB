import 'dart:typed_data';

/// STEP-2 Profile wire models.
///
/// The shapes mirror `docs/contracts/profile-step2.md` and
/// `server/contract/profile-local-schema.json` exactly:
/// * server Profile `{account, username, signature, avatar_url, avatar_version}`
/// * avatar mutation `{avatar_url, avatar_version}`
/// * local view_avatar `{account, mime_type, data, avatar_version}`
///
/// `nickname` is UI wording for `username`; there is no second stored field.

/// A Profile as returned by `GET /users/{account}/profile` and `PATCH /me/profile`.
class Profile {
  const Profile({
    required this.account,
    required this.username,
    required this.signature,
    required this.avatarUrl,
    required this.avatarVersion,
  });

  final String account;
  final String username;
  final String? signature;
  final String avatarUrl;
  final String avatarVersion;

  factory Profile.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('profile must be an object');
    }
    final Object? account = json['account'];
    final Object? username = json['username'];
    final Object? signature = json['signature'];
    final Object? avatarUrl = json['avatar_url'];
    final Object? avatarVersion = json['avatar_version'];
    if (account is! String ||
        username is! String ||
        avatarUrl is! String ||
        avatarVersion is! String ||
        (signature != null && signature is! String)) {
      throw const FormatException('profile is missing fields');
    }
    return Profile(
      account: account,
      username: username,
      signature: signature as String?,
      avatarUrl: avatarUrl,
      avatarVersion: avatarVersion,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'username': username,
    'signature': signature,
    'avatar_url': avatarUrl,
    'avatar_version': avatarVersion,
  };
}

/// Avatar metadata returned by `POST`/`DELETE /me/avatar`.
class AvatarInfo {
  const AvatarInfo({required this.avatarUrl, required this.avatarVersion});

  final String avatarUrl;
  final String avatarVersion;

  factory AvatarInfo.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('avatar must be an object');
    }
    final Object? url = json['avatar_url'];
    final Object? version = json['avatar_version'];
    if (url is! String || version is! String || version.isEmpty) {
      throw const FormatException('avatar is missing fields');
    }
    return AvatarInfo(avatarUrl: url, avatarVersion: version);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'avatar_url': avatarUrl,
    'avatar_version': avatarVersion,
  };
}

/// Decoded avatar bytes plus the opaque server version they belong to.
class AvatarImage {
  const AvatarImage({
    required this.account,
    required this.bytes,
    required this.version,
    this.mimeType = 'image/png',
  });

  final String account;
  final Uint8List bytes;
  final String version;
  final String mimeType;
}

/// One `PATCH /me/profile` body.
///
/// A field participates only when its `set*` flag is true: omitted fields keep
/// their server value, while an explicitly null `signature` clears it.
class ProfilePatch {
  const ProfilePatch({
    this.username,
    this.setUsername = false,
    this.signature,
    this.setSignature = false,
  });

  final String? username;
  final bool setUsername;
  final String? signature;
  final bool setSignature;

  bool get isEmpty => !setUsername && !setSignature;

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> body = <String, dynamic>{};
    if (setUsername) {
      body['username'] = username;
    }
    if (setSignature) {
      body['signature'] = signature;
    }
    return body;
  }
}
