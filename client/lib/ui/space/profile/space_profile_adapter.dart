import '../../../models/space_models.dart';
import '../../../services/profile_service.dart';
import '../space_gateway.dart';
import 'space_profile_gateway.dart';

/// Production profile adapter built on the existing shared Space contract.
///
/// Today the server already supports the author-scoped `list_posts` page, so
/// the home timeline is real data with real permission filtering and a cursor
/// bound to the author query. The month directory and the follow relationship
/// are still waiting for Forge's contract: this adapter reports them as
/// unsupported so the page hides those controls instead of guessing endpoints.
class SpaceProfileAdapter implements SpaceProfileGateway {
  SpaceProfileAdapter({required this.space, this.profile});

  final SpaceGateway space;

  /// Existing authorized profile entry. The home page identity must not add a
  /// second profile transport, so it reuses this gateway.
  final ProfileGateway? profile;

  @override
  bool get supportsMonths => false;

  @override
  bool get supportsFollow => false;

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
    SpaceProfileMonth? month,
    String? cursor,
    int limit = 20,
  }) async {
    if (month != null) {
      throw const SpaceProfileUnsupported('month_anchor');
    }
    final SpacePagePost page = await space.listPosts(
      author: userId,
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
  Future<List<SpaceProfileMonth>> months(String userId) async {
    throw const SpaceProfileUnsupported('months');
  }

  @override
  Future<bool> following(String userId) async {
    throw const SpaceProfileUnsupported('following');
  }

  @override
  Future<bool> setFollowing({
    required String userId,
    required bool following,
  }) async {
    throw const SpaceProfileUnsupported('following');
  }
}
