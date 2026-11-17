import 'package:flutter/material.dart';

import '../../../app.dart';
import '../../../models/space_models.dart';
import '../../../services/space_download_log.dart';
import '../space_detail_controller.dart';
import '../space_detail_view.dart';
import '../space_gateway.dart';
import '../space_image_viewer.dart';
import '../space_layout.dart';
import '../space_local_store.dart';

/// What the home page should do with the card after the detail closes.
class SpaceDetailOutcome {
  const SpaceDetailOutcome({required this.deleted, required this.post});

  final bool deleted;
  final SpacePost? post;
}

/// The existing Space detail surface opened as its own route.
///
/// It reuses [SpaceDetailView] and [SpaceDetailController] unchanged: same
/// body/images/reference/comments, same visit ID semantics, same like and
/// delete actions. Closing it returns the final post so the author home page
/// updates the card in place instead of reloading the timeline and losing the
/// browse position.
class SpacePostDetailPage extends StatefulWidget {
  const SpacePostDetailPage({
    super.key,
    required this.gateway,
    required this.store,
    required this.postId,
    required this.images,
    required this.downloads,
    this.focusCommentId,
    this.historyDepth = 1,
    this.onSessionExpired,
  });

  final SpaceGateway gateway;
  final SpaceLocalStore store;
  final String postId;
  final SpaceImageLoader images;
  final SpaceDownloadLog downloads;
  final String? focusCommentId;
  final int historyDepth;
  final VoidCallback? onSessionExpired;

  static const Key pageKey = Key('space-post-detail-page');

  /// Opens one detail visit and returns the post's final state (or a null post
  /// when the close produced no usable snapshot).
  static Future<SpaceDetailOutcome?> open(
    BuildContext context, {
    required SpaceGateway gateway,
    required SpaceLocalStore store,
    required String postId,
    required SpaceImageLoader images,
    required SpaceDownloadLog downloads,
    String? focusCommentId,
    int historyDepth = 1,
    VoidCallback? onSessionExpired,
  }) {
    return Navigator.of(context).push<SpaceDetailOutcome>(
      MaterialPageRoute<SpaceDetailOutcome>(
        builder: (BuildContext context) => SpacePostDetailPage(
          gateway: gateway,
          store: store,
          postId: postId,
          images: images,
          downloads: downloads,
          focusCommentId: focusCommentId,
          historyDepth: historyDepth,
          onSessionExpired: onSessionExpired,
        ),
      ),
    );
  }

  @override
  State<SpacePostDetailPage> createState() => _SpacePostDetailPageState();
}

class _SpacePostDetailPageState extends State<SpacePostDetailPage> {
  late final SpaceDetailController _detail;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _detail = SpaceDetailController(
      gateway: widget.gateway,
      store: widget.store,
      postId: widget.postId,
      visitId: 'visit-${DateTime.now().microsecondsSinceEpoch}',
      focusCommentId: widget.focusCommentId,
      onSessionExpired: widget.onSessionExpired,
    );
    _detail.addListener(_onChanged);
    _detail.load();
  }

  @override
  void dispose() {
    _detail.removeListener(_onChanged);
    _detail.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _close() {
    if (_closing) {
      return;
    }
    _closing = true;
    Navigator.of(context)
        .pop(SpaceDetailOutcome(deleted: _detail.deleted, post: _detail.post));
  }

  Future<void> _openReference(String postId) async {
    final SpaceDetailOutcome? outcome = await SpacePostDetailPage.open(
      context,
      gateway: widget.gateway,
      store: widget.store,
      postId: postId,
      images: widget.images,
      downloads: widget.downloads,
      historyDepth: widget.historyDepth + 1,
      onSessionExpired: widget.onSessionExpired,
    );
    if (!mounted || outcome == null) {
      return;
    }
    // A reference is projected from the owning post; refetching the current
    // detail keeps a deleted source from staying visible.
    if (outcome.deleted) {
      _detail.onReferenceDeletedEvent(postId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final SpaceLayout layout = SpaceLayout.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _close();
        }
      },
      child: Material(
        key: SpacePostDetailPage.pageKey,
        color: AppColors.paper,
        child: SpaceOcclusion(
          layout: layout,
          child: SafeArea(
            child: SpaceDetailView(
              controller: _detail,
              images: widget.images,
              downloads: widget.downloads,
              layout: layout,
              onClose: _close,
              onBack: () => Navigator.of(context).maybePop(),
              onOpenReference: _openReference,
              historyDepth: widget.historyDepth,
            ),
          ),
        ),
      ),
    );
  }
}
