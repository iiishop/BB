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
/// Kept for older servers that predate the DEA-485 extension: callers degrade
/// explicitly instead of guessing an endpoint.
class SpaceProfileUnsupported implements Exception {
  const SpaceProfileUnsupported(this.capability);

  final String capability;

  @override
  String toString() => 'SpaceProfileUnsupported($capability)';
}

/// UI-facing port for the author home page.
///
/// The wire contract is `docs/contracts/dea485-profile-follow.md`. Every date
/// is rendered and grouped with one fixed browsing offset captured when the
/// home page session opens; the same offset is sent to the directory and the
/// timeline so an archived month always matches the visible date.
abstract interface class SpaceProfileGateway {
  Future<SpaceProfileIdentity> identity(String userId);

  /// Author timeline, newest first, ordered by `(created_at, post_id)`.
  /// [month] is a `space-profile` month upper bound; older months stay
  /// reachable by continuing the cursor.
  Future<SpaceProfileTimelinePage> timeline({
    required String userId,
    required int timezoneOffsetMinutes,
    SpaceProfileMonth? month,
    String? cursor,
    int limit = 20,
  });

  /// Visible (non-empty) months under the same fixed offset, newest first.
  Future<List<SpaceProfileMonth>> months(
    String userId, {
    required int timezoneOffsetMinutes,
  });
}

/// `YYYY-MM`, the contract's month selector format.
String spaceProfileMonthWire(SpaceProfileMonth month) =>
    '${month.year.toString().padLeft(4, '0')}-'
    '${month.month.toString().padLeft(2, '0')}';
