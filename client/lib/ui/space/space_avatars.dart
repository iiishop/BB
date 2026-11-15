import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../models/profile_models.dart';
import '../../services/profile_service.dart';

/// Avatar bytes for one Space page, loaded through the existing authorized
/// Profile entry (`GET /avatars/{account}.png` + ETag cache).
///
/// The server advertises every Space author through `avatar_url`
/// (`/avatars/{account}.png`); accounts without an uploaded image still get a
/// deterministic identicon, so initials are only a placeholder while the bytes
/// are in flight or after a failed fetch. Space keeps no second avatar
/// transport and no separate persistent cache: [ProfileGateway.loadAvatar]
/// revalidates and reuses the shared [AvatarCache] entry.
///
/// One visit asks at most once per account. A failed avatar stays a
/// placeholder for this page visit instead of retrying on every rebuild; the
/// next Space page (new account/server scope) revalidates again.
class SpaceAvatarStore extends ChangeNotifier {
  SpaceAvatarStore({required this.profile});

  final ProfileGateway profile;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  final Set<String> _failed = <String>{};
  final Map<String, Future<void>> _requests = <String, Future<void>>{};
  bool _disposed = false;

  Uint8List? bytesFor(String account) => _bytes[account];

  bool hasFailed(String account) => _failed.contains(account);

  /// Requests [account] once. Later calls reuse the same future and never hit
  /// the server again during this visit.
  ///
  /// The request starts in a microtask so a widget may call this from
  /// `initState`/`didChangeDependencies` without notifying listeners mid-build.
  Future<void> ensureLoaded(String account) {
    if (account.isEmpty) {
      return Future<void>.value();
    }
    return _requests[account] ??= Future<void>.microtask(
      () => _request(account),
    );
  }

  Future<void> _request(String account) async {
    try {
      final AvatarImage image = await profile.loadAvatar(account: account);
      if (image.bytes.isEmpty) {
        _failed.add(account);
      } else {
        _bytes[account] = image.bytes;
        _failed.remove(account);
      }
    } catch (_) {
      // Avatars are supplementary. Keep the deterministic initials instead of
      // spinning or retrying every frame.
      _failed.add(account);
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Makes one [SpaceAvatarStore] available to every Space card, comment row and
/// people sheet without threading a loader through each constructor.
class SpaceAvatarScope extends InheritedNotifier<SpaceAvatarStore> {
  const SpaceAvatarScope({
    super.key,
    required SpaceAvatarStore store,
    required super.child,
  }) : super(notifier: store);

  static SpaceAvatarStore? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SpaceAvatarScope>()
        ?.notifier;
  }

  /// Non-dependent lookup for event handlers that must hand the store to a
  /// route or bottom sheet built outside this subtree.
  static SpaceAvatarStore? read(BuildContext context) {
    return context.getInheritedWidgetOfExactType<SpaceAvatarScope>()?.notifier;
  }
}
