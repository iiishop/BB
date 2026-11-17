import '../../../models/space_models.dart';

/// One author's home-page identity (avatar, nickname, signature).
///
/// The identity is loaded through the existing authorized Profile entry; Space
/// adds no second profile transport.
class SpaceProfileIdentity {
  const SpaceProfileIdentity({
    required this.account,
    required this.username,
    this.signature,
    this.avatarUrl = '',
  });

  final String account;
  final String username;
  final String? signature;
  final String avatarUrl;
}

/// A month that has at least one visible entry, as decided by the server.
///
/// The page never derives the directory from the loaded pages: an empty month
/// must not appear, and a month that only has entries on unloaded pages must
/// still be reachable.
class SpaceProfileMonth implements Comparable<SpaceProfileMonth> {
  const SpaceProfileMonth({required this.year, required this.month});

  final int year;

  /// 1..12.
  final int month;

  String get label => '$year 年 $month 月';

  int get sortKey => year * 12 + (month - 1);

  @override
  int compareTo(SpaceProfileMonth other) => sortKey.compareTo(other.sortKey);

  @override
  bool operator ==(Object other) =>
      other is SpaceProfileMonth && other.year == year && other.month == month;

  @override
  int get hashCode => sortKey;

  @override
  String toString() => label;
}

/// One timeline row: the reused post model plus the author-scoped timeline
/// time.
///
/// `timelineAt` is the time this entry is ordered and archived by (own
/// publication for originals, the author's repost time for reposts). It is the
/// only time the profile page may display or group by; `post.createdAt` stays
/// the post's own publication time.
class SpaceProfileEntry {
  const SpaceProfileEntry({required this.post, required this.timelineAt});

  factory SpaceProfileEntry.fromPost(SpacePost post) =>
      SpaceProfileEntry(post: post, timelineAt: post.createdAt);

  final SpacePost post;
  final String timelineAt;
}

/// One page of an author's timeline.
class SpaceProfileTimelinePage {
  const SpaceProfileTimelinePage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<SpaceProfileEntry> items;
  final String? nextCursor;
  final bool hasMore;
}

/// The server does not expose this profile capability yet.
///
/// Callers degrade explicitly instead of guessing an endpoint or downloading
/// all history and filtering it on the device.
class SpaceProfileUnsupported implements Exception {
  const SpaceProfileUnsupported(this.capability);

  final String capability;

  @override
  String toString() => 'SpaceProfileUnsupported($capability)';
}

/// UI-facing port for the author home page.
///
/// Endpoints, JSON fields and cursor encoding live in the shared Space
/// contract; this port only names the semantics the page needs. Until the
/// server contract for months/follow is fixed the production adapter reports
/// [supportsMonths]/[supportsFollow] as false and the page hides those
/// controls rather than shipping a dead button.
abstract interface class SpaceProfileGateway {
  /// Whether the server can return the visible month directory.
  bool get supportsMonths;

  /// Whether the server can return and write a follow relationship.
  bool get supportsFollow;

  Future<SpaceProfileIdentity> identity(String userId);

  /// Author timeline, newest first. When [month] is set the server starts at
  /// that month's newest entry and keeps going into older months.
  Future<SpaceProfileTimelinePage> timeline({
    required String userId,
    SpaceProfileMonth? month,
    String? cursor,
    int limit = 20,
  });

  /// Visible (non-empty) months, newest first.
  Future<List<SpaceProfileMonth>> months(String userId);

  /// Authoritative current state: is [userId] followed by the viewer?
  Future<bool> following(String userId);

  /// Idempotent desired-state write; returns the authoritative result.
  Future<bool> setFollowing({required String userId, required bool following});
}
