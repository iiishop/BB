/// Paging layer shared by the chat and Space viewers.
///
/// It exists because `PageView` and `InteractiveViewer` fight over horizontal
/// drags: without pausing the pager while a picture is zoomed, a two-finger
/// pinch is read as a page swipe on the first finger. That rule, the desktop
/// arrows, the arrow-key paging and Escape-to-close are identical on both
/// surfaces, so they live here once.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';

/// Element keys for one viewer instance.
///
/// The prefix keeps two viewers mounted in the same app (and their tests) from
/// colliding while leaving each surface's established key strings unchanged.
class PhotoViewerKeys {
  const PhotoViewerKeys(this.prefix);

  final String prefix;

  Key get pages => Key('$prefix-pages');
  Key get close => Key('$prefix-close');
  Key get save => Key('$prefix-save');
  Key get index => Key('$prefix-index');
  Key get status => Key('$prefix-status');
  Key get original => Key('$prefix-original');
  Key get originalProgress => Key('$prefix-original-progress');
  Key get previewRetry => Key('$prefix-preview-retry');
  Key get previous => Key('$prefix-previous');
  Key get next => Key('$prefix-next');
}

/// Paging request produced by the arrow keys.
///
/// Arrow keys are declared as shortcuts instead of being read in
/// [Focus.onKeyEvent]: `WidgetsApp` binds them to `DirectionalFocusIntent` above
/// the page, so a listener on this node never sees them and the keys travel
/// focus instead of paging. A shortcut closer to the focused node wins.
class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

/// Callbacks a page gets from the pager.
///
/// The page owns gestures (the scale recognizer is closest to the pixels and
/// wins a single finger), so it relays swipes up here; [onZoom] is for the
/// caller's own chrome (the chat viewer keeps a downward-drag-to-close gesture
/// that must not fire while a picture is zoomed).
class PhotoPagerHandlers {
  const PhotoPagerHandlers({
    required this.onZoom,
    required this.onPanDelta,
    required this.onPanEnd,
  });

  final ValueChanged<bool> onZoom;
  final ValueChanged<Offset> onPanDelta;
  final VoidCallback onPanEnd;
}

typedef PhotoPageBuilder =
    Widget Function(BuildContext context, int index, PhotoPagerHandlers handlers);

class PhotoPager extends StatefulWidget {
  const PhotoPager({
    super.key,
    required this.controller,
    required this.initialIndex,
    required this.itemCount,
    required this.itemBuilder,
    required this.keys,
    this.onPageChanged,
    this.onDismiss,
    this.onZoomChanged,
    this.desktopArrows = true,
  });

  final PageController controller;
  final int initialIndex;
  final int itemCount;

  /// Builds one page and hands it the pager callbacks.
  final PhotoPageBuilder itemBuilder;

  final PhotoViewerKeys keys;

  /// Fired after the pager settles on a new page.
  final ValueChanged<int>? onPageChanged;

  /// Escape. Null keeps Escape inert (the chat viewer closes on drag).
  final VoidCallback? onDismiss;

  /// Pinch state of the page on screen, for chrome that must stand down while a
  /// picture is zoomed (the chat viewer's downward-drag-to-close).
  final ValueChanged<bool>? onZoomChanged;

  /// Desktop-only chevrons; mobile stays swipe-only because a persistent arrow
  /// would sit on the photo with no hover to reveal it.
  final bool desktopArrows;

  static bool desktopOf(BuildContext context) {
    final TargetPlatform platform = Theme.of(context).platform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;
  }

  @override
  State<PhotoPager> createState() => _PhotoPagerState();
}

class _PhotoPagerState extends State<PhotoPager> {
  late int _index;

  /// Where the current swipe started: pixel offset and page. Snapping compares
  /// against these so a half-page drag returns to where it began.
  double _dragStartPixels = 0;
  int _dragStartPage = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _index = widget.itemCount == 0
        ? 0
        : widget.initialIndex.clamp(0, widget.itemCount - 1);
  }

  /// Single-finger swipe relayed by a page. The `PageView` keeps
  /// `NeverScrollableScrollPhysics` because a page's scale recognizer wins that
  /// arena, so this is the only thing that moves pages by finger.
  void _onPanDelta(Offset delta) {
    final PageController controller = widget.controller;
    if (!controller.hasClients) {
      return;
    }
    final ScrollPosition position = controller.position;
    final double viewport = position.viewportDimension;
    if (viewport <= 0) {
      return;
    }
    if (!_dragging) {
      _dragging = true;
      _dragStartPixels = position.pixels;
      _dragStartPage = (position.pixels / viewport).round();
    }
    controller.jumpTo(
      (position.pixels - delta.dx).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  /// Snaps after a swipe: a quarter of a page is enough to advance, anything
  /// less returns to the page the swipe started on.
  void _onPanEnd() {
    if (!_dragging) {
      return;
    }
    _dragging = false;
    final PageController controller = widget.controller;
    if (!controller.hasClients) {
      return;
    }
    final double viewport = controller.position.viewportDimension;
    if (viewport <= 0) {
      return;
    }
    final double moved = (controller.position.pixels - _dragStartPixels) / viewport;
    int target = _dragStartPage;
    if (moved > 0.25) {
      target += 1;
    } else if (moved < -0.25) {
      target -= 1;
    }
    target = target.clamp(0, widget.itemCount == 0 ? 0 : widget.itemCount - 1);
    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  void _step(int delta) {
    if (widget.itemCount == 0) {
      return;
    }
    final int next = (_index + delta).clamp(0, widget.itemCount - 1);
    if (next == _index) {
      return;
    }
    setState(() => _index = next);
    widget.controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _pagingArrow({
    required Key key,
    required int delta,
    required IconData icon,
    required String tooltip,
    required Alignment alignment,
  }) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        child: IconButton(
          key: key,
          onPressed: () => _step(delta),
          tooltip: tooltip,
          style: IconButton.styleFrom(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 48),
          ),
          icon: Icon(icon, size: 32),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool arrows = widget.desktopArrows && PhotoPager.desktopOf(context);
    final VoidCallback? dismiss = widget.onDismiss;
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft): const _StepIntent(
          -1,
        ),
        const SingleActivator(LogicalKeyboardKey.arrowRight): const _StepIntent(
          1,
        ),
        // Escape only closes where the caller gave a dismiss action.
        if (dismiss != null)
          const SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (_StepIntent intent) {
              _step(intent.delta);
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              dismiss?.call();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: GestureDetector(
            // Fallback for pages that carry no gesture layer of their own (a
            // video page). On an image page the scale recognizer is nearer the
            // pixels and wins the arena, so this never fires there.
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (DragUpdateDetails details) =>
                _onPanDelta(Offset(details.delta.dx, 0)),
            onHorizontalDragEnd: (DragEndDetails details) => _onPanEnd(),
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                PageView.builder(
                  key: widget.keys.pages,
                  controller: widget.controller,
                  // Pages drive paging themselves (single-finger swipes are
                  // relayed by the page's scale recognizer), so the view never
                  // scrolls on its own.
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: widget.itemCount,
                  onPageChanged: (int value) {
                    setState(() => _index = value);
                    widget.onPageChanged?.call(value);
                  },
                  itemBuilder: (BuildContext context, int index) {
                    return widget.itemBuilder(
                      context,
                      index,
                      PhotoPagerHandlers(
                        onZoom: widget.onZoomChanged ?? (bool _) {},
                        onPanDelta: _onPanDelta,
                        onPanEnd: _onPanEnd,
                      ),
                    );
                  },
                ),
                if (arrows && _index > 0)
                  _pagingArrow(
                    key: widget.keys.previous,
                    delta: -1,
                    icon: Icons.chevron_left_rounded,
                    tooltip: '上一张',
                    alignment: Alignment.centerLeft,
                  ),
                if (arrows && _index < widget.itemCount - 1)
                  _pagingArrow(
                    key: widget.keys.next,
                    delta: 1,
                    icon: Icons.chevron_right_rounded,
                    tooltip: '下一张',
                    alignment: Alignment.centerRight,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
