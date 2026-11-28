import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';

/// Descriptor for a top-level shell navigation destination.
class HomeNavItem {
  const HomeNavItem({
    required this.itemKey,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final Key itemKey;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Mobile edge-anchored bottom navigation bar (DEA-508 v4).
///
/// Uses warm paper shelf material, a sliding paper-white thumb card with an
/// ink page-edge mark, subtle hover/press tints, a 3px keyboard focus ring,
/// arrow-key traversal, and bottom system safe-area padding.
class HomeBottomNavBar extends StatefulWidget {
  const HomeBottomNavBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<HomeNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const Key thumbKey = Key('home-bottom-nav-thumb');
  static const Key thumbMarkKey = Key('home-bottom-nav-thumb-mark');
  static const Duration slideDuration = Duration(milliseconds: 200);
  static const Curve slideCurve = Cubic(0.2, 0.8, 0.2, 1.0);

  @override
  State<HomeBottomNavBar> createState() => _HomeBottomNavBarState();
}

class _HomeBottomNavBarState extends State<HomeBottomNavBar> {
  late List<FocusNode> _focusNodes = _buildFocusNodes(widget.items.length);

  static List<FocusNode> _buildFocusNodes(int count) =>
      List<FocusNode>.generate(
        count,
        (int index) => FocusNode(debugLabel: 'home-bottom-nav-$index'),
      );

  @override
  void didUpdateWidget(HomeBottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      for (final FocusNode node in _focusNodes) {
        node.dispose();
      }
      _focusNodes = _buildFocusNodes(widget.items.length);
    }
  }

  @override
  void dispose() {
    for (final FocusNode node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final int count = widget.items.length;
    const double gap = 2;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.navShelf,
        border: Border(
          top: BorderSide(color: AppColors.navShelfBorder, width: 1),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          safe.left + 6,
          1,
          safe.right + 6,
          4 + safe.bottom,
        ),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SizedBox(
              height: 50,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double totalWidth = constraints.maxWidth;
                  final double slotWidth = count > 0
                      ? math.max(0.0, (totalWidth - gap * (count - 1)) / count)
                      : 0.0;
                  final double thumbLeft =
                      widget.selectedIndex * (slotWidth + gap) + 3;
                  final double thumbWidth = math.max(0.0, slotWidth - 6);

                  return Stack(
                    children: <Widget>[
                      if (count > 0)
                        AnimatedPositioned(
                          duration: reduceMotion
                              ? Duration.zero
                              : HomeBottomNavBar.slideDuration,
                          curve: HomeBottomNavBar.slideCurve,
                          left: thumbLeft,
                          top: 3,
                          width: thumbWidth,
                          height: 44,
                          child: IgnorePointer(
                            child: Container(
                              key: HomeBottomNavBar.thumbKey,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.brand,
                                ),
                                border: Border.all(
                                  color: AppColors.border,
                                  width: 1,
                                ),
                                boxShadow: const <BoxShadow>[
                                  BoxShadow(
                                    color: Color(0x12161D1E),
                                    blurRadius: 3,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                              alignment: Alignment.topCenter,
                              padding: const EdgeInsets.only(top: 5),
                              child: Container(
                                key: HomeBottomNavBar.thumbMarkKey,
                                width: 24,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: AppColors.ink,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Row(
                        children: <Widget>[
                          for (int i = 0; i < count; i++) ...<Widget>[
                            if (i > 0) const SizedBox(width: gap),
                            Expanded(
                              child: _NavInteractionTarget(
                                key: widget.items[i].itemKey,
                                index: i,
                                count: count,
                                axis: Axis.horizontal,
                                label: widget.items[i].label,
                                selected: i == widget.selectedIndex,
                                reduceMotion: reduceMotion,
                                focusNode: _focusNodes[i],
                                hoverColor: const Color(0x09161D1E),
                                pressColor: const Color(0x0F161D1E),
                                pillInset: const EdgeInsets.all(3),
                                onTap: () => widget.onSelected(i),
                                onMoveAndSelect: (int target) {
                                  _focusNodes[target].requestFocus();
                                  widget.onSelected(target);
                                },
                                builder:
                                    (BuildContext context, Color inkColor) {
                                      final bool selected =
                                          i == widget.selectedIndex;
                                      final HomeNavItem item = widget.items[i];
                                      return SizedBox(
                                        height: 50,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: <Widget>[
                                              Icon(
                                                selected
                                                    ? item.selectedIcon
                                                    : item.icon,
                                                size: 20,
                                                color: inkColor,
                                              ),
                                              const SizedBox(width: 7),
                                              Flexible(
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: Text(
                                                    item.label,
                                                    maxLines: 1,
                                                    softWrap: false,
                                                    style: TextStyle(
                                                      color: inkColor,
                                                      fontSize: 12.5,
                                                      letterSpacing: 0.125,
                                                      fontWeight: selected
                                                          ? FontWeight.w700
                                                          : FontWeight.w500,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop narrow navigation rail (DEA-508 v4).
///
/// Renders on warm paper with a 1px right border; the active ink spine mark is
/// drawn separately via [HomeRailSpineMark] so it straddles the divider line
/// cleanly above the page stack and slides out with the fold transition.
class HomeDesktopNavRail extends StatefulWidget {
  const HomeDesktopNavRail({
    super.key,
    required this.width,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.navLink,
    required this.footer,
  });

  final double width;
  final List<HomeNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final LayerLink navLink;
  final Widget footer;

  static const double itemHeight = 60;
  static const double itemGap = 6;

  @override
  State<HomeDesktopNavRail> createState() => _HomeDesktopNavRailState();
}

class _HomeDesktopNavRailState extends State<HomeDesktopNavRail> {
  late List<FocusNode> _focusNodes = _buildFocusNodes(widget.items.length);

  static List<FocusNode> _buildFocusNodes(int count) =>
      List<FocusNode>.generate(
        count,
        (int index) => FocusNode(debugLabel: 'home-desktop-rail-$index'),
      );

  @override
  void didUpdateWidget(HomeDesktopNavRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      for (final FocusNode node in _focusNodes) {
        node.dispose();
      }
      _focusNodes = _buildFocusNodes(widget.items.length);
    }
  }

  @override
  void dispose() {
    for (final FocusNode node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final int count = widget.items.length;

    return Container(
      width: widget.width,
      decoration: const BoxDecoration(
        color: AppColors.paper,
        border: Border(right: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 22, bottom: 16),
              child: Text(
                'BB',
                textAlign: TextAlign.center,
                style: (text.labelLarge ?? const TextStyle()).copyWith(
                  color: AppColors.accentDeep,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3.6,
                ),
              ),
            ),
            CompositedTransformTarget(
              link: widget.navLink,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int i = 0; i < count; i++) ...<Widget>[
                      if (i > 0)
                        const SizedBox(height: HomeDesktopNavRail.itemGap),
                      _NavInteractionTarget(
                        key: widget.items[i].itemKey,
                        index: i,
                        count: count,
                        axis: Axis.vertical,
                        label: widget.items[i].label,
                        selected: i == widget.selectedIndex,
                        reduceMotion: reduceMotion,
                        focusNode: _focusNodes[i],
                        hoverColor: const Color(0x0A161D1E),
                        pressColor: const Color(0x0F161D1E),
                        pillInset: EdgeInsets.zero,
                        onTap: () => widget.onSelected(i),
                        onMoveAndSelect: (int target) {
                          _focusNodes[target].requestFocus();
                          widget.onSelected(target);
                        },
                        builder: (BuildContext context, Color inkColor) {
                          final bool selected = i == widget.selectedIndex;
                          final HomeNavItem item = widget.items[i];
                          return SizedBox(
                            height: HomeDesktopNavRail.itemHeight,
                            width: double.infinity,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: <Widget>[
                                  Icon(
                                    selected ? item.selectedIcon : item.icon,
                                    color: inkColor,
                                    size: 22,
                                  ),
                                  const SizedBox(height: 3),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      item.label,
                                      maxLines: 1,
                                      softWrap: false,
                                      style: TextStyle(
                                        color: inkColor,
                                        fontSize: 11.5,
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Spacer(),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: AppColors.border, width: 1),
                ),
              ),
              child: Center(child: widget.footer),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sliding ink spine mark straddling the desktop rail's right border.
class HomeRailSpineMark extends StatelessWidget {
  const HomeRailSpineMark({
    super.key,
    required this.itemCount,
    required this.selectedIndex,
  });

  final int itemCount;
  final int selectedIndex;

  static const Key markKey = Key('home-rail-mark');
  static const Duration slideDuration = Duration(milliseconds: 160);
  static const Curve slideCurve = Cubic(0.2, 0.8, 0.2, 1.0);

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final double totalHeight = itemCount > 0
        ? itemCount * HomeDesktopNavRail.itemHeight +
              (itemCount - 1) * HomeDesktopNavRail.itemGap
        : 0.0;
    final double step =
        HomeDesktopNavRail.itemHeight + HomeDesktopNavRail.itemGap;
    final double markTop =
        selectedIndex * step + (HomeDesktopNavRail.itemHeight / 2) - 5.5;

    return SizedBox(
      width: 23,
      height: totalHeight,
      child: Stack(
        children: <Widget>[
          AnimatedPositioned(
            duration: reduceMotion ? Duration.zero : slideDuration,
            curve: slideCurve,
            left: 0,
            top: markTop,
            width: 23,
            height: 11,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: AppColors.paper,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Container(
                key: markKey,
                width: 15,
                height: 3,
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _NavMoveDirection { next, prev, first, last }

class _NavMoveIntent extends Intent {
  const _NavMoveIntent(this.direction);

  const _NavMoveIntent.next() : direction = _NavMoveDirection.next;
  const _NavMoveIntent.prev() : direction = _NavMoveDirection.prev;
  const _NavMoveIntent.first() : direction = _NavMoveDirection.first;
  const _NavMoveIntent.last() : direction = _NavMoveDirection.last;

  final _NavMoveDirection direction;
}

class _NavInteractionTarget extends StatefulWidget {
  const _NavInteractionTarget({
    super.key,
    required this.index,
    required this.count,
    required this.axis,
    required this.label,
    required this.selected,
    required this.reduceMotion,
    required this.focusNode,
    required this.hoverColor,
    required this.pressColor,
    required this.pillInset,
    required this.onTap,
    required this.onMoveAndSelect,
    required this.builder,
  });

  final int index;
  final int count;
  final Axis axis;
  final String label;
  final bool selected;
  final bool reduceMotion;
  final FocusNode focusNode;
  final Color hoverColor;
  final Color pressColor;
  final EdgeInsets pillInset;
  final VoidCallback onTap;
  final ValueChanged<int> onMoveAndSelect;
  final Widget Function(BuildContext context, Color inkColor) builder;

  static const Duration interactionDuration = Duration(milliseconds: 120);
  static const Duration colorDuration = Duration(milliseconds: 140);

  @override
  State<_NavInteractionTarget> createState() => _NavInteractionTargetState();
}

class _NavInteractionTargetState extends State<_NavInteractionTarget> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final Color backgroundColor = widget.selected
        ? Colors.transparent
        : _pressed
        ? widget.pressColor
        : _hovered
        ? widget.hoverColor
        : Colors.transparent;
    final Color targetInkColor = (widget.selected || _hovered || _pressed)
        ? AppColors.ink
        : AppColors.inkMuted;

    final Map<ShortcutActivator, Intent> shortcuts =
        widget.axis == Axis.horizontal
        ? const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowRight):
                _NavMoveIntent.next(),
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                _NavMoveIntent.prev(),
            SingleActivator(LogicalKeyboardKey.home): _NavMoveIntent.first(),
            SingleActivator(LogicalKeyboardKey.end): _NavMoveIntent.last(),
          }
        : const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowDown):
                _NavMoveIntent.next(),
            SingleActivator(LogicalKeyboardKey.arrowUp): _NavMoveIntent.prev(),
            SingleActivator(LogicalKeyboardKey.home): _NavMoveIntent.first(),
            SingleActivator(LogicalKeyboardKey.end): _NavMoveIntent.last(),
          };

    final Map<Type, Action<Intent>> actions = <Type, Action<Intent>>{
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onTap();
          return null;
        },
      ),
      _NavMoveIntent: CallbackAction<_NavMoveIntent>(
        onInvoke: (_NavMoveIntent intent) {
          if (widget.count <= 0) {
            return null;
          }
          final int target = switch (intent.direction) {
            _NavMoveDirection.next => (widget.index + 1) % widget.count,
            _NavMoveDirection.prev =>
              (widget.index - 1 + widget.count) % widget.count,
            _NavMoveDirection.first => 0,
            _NavMoveDirection.last => widget.count - 1,
          };
          widget.onMoveAndSelect(target);
          return null;
        },
      ),
    };

    return Semantics(
      button: true,
      selected: widget.selected,
      inMutuallyExclusiveGroup: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hovered) {
            setState(() => _hovered = true);
          }
        },
        onExit: (_) {
          if (_hovered) {
            setState(() => _hovered = false);
          }
        },
        child: FocusableActionDetector(
          focusNode: widget.focusNode,
          shortcuts: shortcuts,
          actions: actions,
          onShowFocusHighlight: (bool value) {
            if (_focused != value) {
              setState(() => _focused = value);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: () {
              if (!widget.focusNode.hasFocus) {
                widget.focusNode.requestFocus();
              }
              widget.onTap();
            },
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    padding: widget.pillInset,
                    child: AnimatedContainer(
                      duration: widget.reduceMotion
                          ? Duration.zero
                          : _NavInteractionTarget.interactionDuration,
                      curve: Curves.ease,
                      decoration: BoxDecoration(
                        color: backgroundColor,
                        borderRadius: BorderRadius.circular(AppRadius.brand),
                      ),
                    ),
                  ),
                ),
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: targetInkColor),
                  duration: widget.reduceMotion
                      ? Duration.zero
                      : _NavInteractionTarget.colorDuration,
                  curve: Curves.ease,
                  builder: (BuildContext context, Color? color, Widget? _) {
                    return widget.builder(context, color ?? targetInkColor);
                  },
                ),
                if (_focused)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(AppRadius.brand),
                          border: Border.all(color: AppColors.ink, width: 3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
