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

/// Reports the zoom state of the page it builds.
typedef PhotoPageBuilder =
    Widget Function(BuildContext context, int index, ValueChanged<bool> onZoom);

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
    this.desktopArrows = true,
  });

  final PageController controller;
  final int initialIndex;
  final int itemCount;

  /// Builds one page. The callback it receives flips the pager between
  /// scrollable and frozen.
  final PhotoPageBuilder itemBuilder;

  final PhotoViewerKeys keys;

  /// Fired after the pager settles on a new page, with zoom already reset.
  final ValueChanged<int>? onPageChanged;

  /// Escape. Null keeps Escape inert (the chat viewer closes on drag).
  final VoidCallback? onDismiss;

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

  /// True while the current page is pinch-zoomed.
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _index = widget.itemCount == 0
        ? 0
        : widget.initialIndex.clamp(0, widget.itemCount - 1);
  }

  void _setZoomed(bool zoomed) {
    if (zoomed == _zoomed || !mounted) {
      return;
    }
    setState(() => _zoomed = zoomed);
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
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              PageView.builder(
                key: widget.keys.pages,
                controller: widget.controller,
                // A zoomed picture owns horizontal drags.
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                itemCount: widget.itemCount,
                onPageChanged: (int value) {
                  // A zoomed page must not leave the pager frozen when the user
                  // swipes back to a neighbour.
                  setState(() {
                    _index = value;
                    _zoomed = false;
                  });
                  widget.onPageChanged?.call(value);
                },
                itemBuilder: (BuildContext context, int index) {
                  return widget.itemBuilder(context, index, _setZoomed);
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
    );
  }
}
