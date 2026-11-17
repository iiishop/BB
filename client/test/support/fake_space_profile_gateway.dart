import 'dart:async';

import 'package:bb_client/models/space_models.dart';
import 'package:bb_client/ui/space/profile/space_profile_gateway.dart';

import 'space_fixtures.dart';

/// One `timeline` invocation, recorded in request order.
class ProfileTimelineCall {
  ProfileTimelineCall({
    required this.userId,
    required this.month,
    required this.cursor,
    required this.limit,
  });

  final String userId;
  final SpaceProfileMonth? month;
  final String? cursor;
  final int limit;

  @override
  String toString() => 'timeline($userId, month: $month, cursor: $cursor)';
}

/// Scriptable profile gateway. Responses are contract-shaped; the fake replaces
/// only the network.
class FakeSpaceProfileGateway implements SpaceProfileGateway {
  FakeSpaceProfileGateway({
    this.account = spacePeerAccount,
    this.viewer = spaceSelfAccount,
    this.supportsMonths = true,
    this.supportsFollow = true,
    SpaceProfileIdentity? identity,
  }) : identityResult =
           identity ??
           SpaceProfileIdentity(
             account: account,
             username: 'bob',
             signature: '在海边写代码。',
           );

  final String account;
  final String viewer;

  @override
  final bool supportsMonths;

  @override
  final bool supportsFollow;

  SpaceProfileIdentity identityResult;
  Object? identityFailure;

  final List<SpaceProfileMonth> monthList = <SpaceProfileMonth>[];
  Object? monthsFailure;

  /// Keyed by `<latest|sortKey>|<cursor>`.
  final Map<String, SpaceProfileTimelinePage> pages =
      <String, SpaceProfileTimelinePage>{};
  final List<ProfileTimelineCall> calls = <ProfileTimelineCall>[];
  Object? timelineFailure;

  /// When set, every timeline call parks on a fresh gate until the test
  /// completes it, which is how out-of-order responses are exercised.
  bool holdTimeline = false;
  final List<Completer<void>> timelineGates = <Completer<void>>[];

  bool followingState = false;
  Object? followFailure;
  Object? writeFailure;
  final List<bool> writeCalls = <bool>[];

  String get _pagePrefix => 'latest';

  String _key(SpaceProfileMonth? month, String? cursor) =>
      '${month?.sortKey ?? _pagePrefix}|${cursor ?? ''}';

  void putPage({
    SpaceProfileMonth? month,
    String? cursor,
    required List<SpaceProfileEntry> items,
    String? nextCursor,
    bool hasMore = false,
  }) {
    pages[_key(month, cursor)] = SpaceProfileTimelinePage(
      items: items,
      nextCursor: nextCursor,
      hasMore: hasMore,
    );
  }

  @override
  Future<SpaceProfileIdentity> identity(String userId) async {
    final Object? failure = identityFailure;
    if (failure != null) {
      throw failure;
    }
    return identityResult;
  }

  @override
  Future<List<SpaceProfileMonth>> months(String userId) async {
    final Object? failure = monthsFailure;
    if (failure != null) {
      throw failure;
    }
    return monthList;
  }

  @override
  Future<SpaceProfileTimelinePage> timeline({
    required String userId,
    SpaceProfileMonth? month,
    String? cursor,
    int limit = 20,
  }) async {
    calls.add(
      ProfileTimelineCall(
        userId: userId,
        month: month,
        cursor: cursor,
        limit: limit,
      ),
    );
    final Object? failure = timelineFailure;
    if (failure != null) {
      timelineFailure = null;
      throw failure;
    }
    final SpaceProfileTimelinePage page =
        pages[_key(month, cursor)] ??
        const SpaceProfileTimelinePage(
          items: <SpaceProfileEntry>[],
          nextCursor: null,
          hasMore: false,
        );
    if (holdTimeline) {
      final Completer<void> gate = Completer<void>();
      timelineGates.add(gate);
      await gate.future;
    }
    return page;
  }

  @override
  Future<bool> following(String userId) async {
    final Object? failure = followFailure;
    if (failure != null) {
      throw failure;
    }
    return followingState;
  }

  @override
  Future<bool> setFollowing({
    required String userId,
    required bool following,
  }) async {
    writeCalls.add(following);
    final Object? failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    followingState = following;
    return following;
  }
}

/// One shared-timeline entry. [timelineAt] defaults to the post time; pass a
/// different value for a repost row to prove the archive month follows the
/// repost time while the card displays it too.
SpaceProfileEntry profileEntry({
  required String postId,
  required String timelineAt,
  String? postCreatedAt,
  String text = '这是一条说说。',
  SpaceAuthor? author,
  List<SpaceImage> images = const <SpaceImage>[],
  SpaceReference? reference,
  bool canDelete = false,
  int likeCount = 0,
  int commentCount = 0,
  int repostCount = 0,
}) {
  final SpacePost post = spacePost(
    postId: postId,
    author: author,
    createdAt: postCreatedAt ?? timelineAt,
    text: text,
    images: images,
    reference: reference,
    canDelete: canDelete,
    likeCount: likeCount,
    commentCount: commentCount,
    repostCount: repostCount,
  );
  return SpaceProfileEntry(post: post, timelineAt: timelineAt);
}
