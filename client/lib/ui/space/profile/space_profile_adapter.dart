import '../../../models/space_models.dart';
import '../../../services/profile_service.dart';
import '../space_gateway.dart';
import 'space_profile_gateway.dart';

/// Production profile adapter over the fixed DEA-485 Space contract.
///
/// Identity still comes from the existing authorized Profile entry; the
/// timeline and directory are the author-scoped actions with the explicit
/// fixed display offset. Cursors are opaque and bound by the server to
/// viewer/target/month/offset, so this adapter never reuses one across queries.
class SpaceProfileAdapter implements SpaceProfileGateway {
  SpaceProfileAdapter({required this.space, this.profile});

  final SpaceGateway space;

  /// Existing authorized profile entry. The home page identity must not add a
  /// second profile transport, so it reuses this gateway.
  final ProfileGateway? profile;

  @override
  Future<SpaceProfileIdentity> identity(String userId) async {
    final ProfileGateway? gateway = profile;
    if (gateway == null) {
      throw const SpaceProfileUnsupported('identity');
    }
    final loaded = await gateway.loadProfile(account: userId);
    return SpaceProfileIdentity(
      account: loaded.account,
      username: loaded.username,
      signature: loaded.signature,
      avatarUrl: loaded.avatarUrl,
    );
  }

  @override
  Future<SpaceProfileTimelinePage> timeline({
    required String userId,
    required int timezoneOffsetMinutes,
    SpaceProfileMonth? month,
    String? cursor,
    int limit = 20,
  }) async {
    final SpacePagePost page = await space.listProfilePosts(
      targetAccount: userId,
      timezoneOffsetMinutes: timezoneOffsetMinutes,
      month: month == null ? null : spaceProfileMonthWire(month),
      cursor: cursor,
      limit: limit,
    );
    return SpaceProfileTimelinePage(
      items: <SpaceProfileEntry>[
        for (final SpacePost post in page.items)
          SpaceProfileEntry.fromPost(post),
      ],
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    );
  }

  @override
  Future<List<SpaceProfileMonth>> months(
    String userId, {
    required int timezoneOffsetMinutes,
  }) async {
    final SpaceProfileMonthDirectory directory = await space.listProfileMonths(
      targetAccount: userId,
      timezoneOffsetMinutes: timezoneOffsetMinutes,
    );
    return <SpaceProfileMonth>[
      for (final SpaceMonthCoordinate item in directory.items)
        SpaceProfileMonth(year: item.year, month: item.month),
    ];
  }
}
