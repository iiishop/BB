import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/profile_models.dart';
import '../../services/profile_service.dart';

/// Avatar bytes for one open conversation, shared by the AppBar and every
/// message bubble.
///
/// One chat visit asks [ProfileGateway.loadAvatar] at most once per account.
/// Both accounts are requested up front so scrolling, polling and rebuilding
/// bubbles never start another request. A failed avatar stays a placeholder for
/// this visit instead of retrying on every frame; the next visit constructs a
/// new controller, which revalidates through the existing `If-None-Match`
/// cache path and can pick up a changed image.
class ChatAvatarController extends ChangeNotifier {
  ChatAvatarController({
    required this.profile,
    required Iterable<String> accounts,
  }) {
    for (final String account in accounts.toSet()) {
      unawaited(ensureLoaded(account));
    }
  }

  final ProfileGateway profile;

  final Map<String, Uint8List> _bytes = <String, Uint8List>{};
  final Map<String, bool> _loading = <String, bool>{};
  final Set<String> _failed = <String>{};
  final Map<String, Future<void>> _requests = <String, Future<void>>{};
  bool _disposed = false;

  Uint8List? bytesFor(String account) => _bytes[account];

  bool isLoading(String account) => _loading[account] ?? false;

  bool hasFailed(String account) => _failed.contains(account);

  /// Requests [account] once. Later calls reuse the same future and never hit
  /// the server again during this visit.
  Future<void> ensureLoaded(String account) {
    if (account.isEmpty) {
      return Future<void>.value();
    }
    return _requests[account] ??= _request(account);
  }

  Future<void> _request(String account) async {
    _loading[account] = true;
    _notify();
    try {
      final AvatarImage image = await profile.loadAvatar(account: account);
      _bytes[account] = image.bytes;
      _failed.remove(account);
    } catch (_) {
      // Avatars are supplementary. The explicit ProfileAvatar placeholder is
      // the terminal state for this visit; never fall back to initials and
      // never spin forever.
      _failed.add(account);
    } finally {
      _loading[account] = false;
      _notify();
    }
  }

  void _notify() {
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
