import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureType;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../services/chat_service.dart';
import '../../services/presence_directory.dart';
import '../../services/profile_service.dart';
import 'chat_page.dart';
import 'users_view.dart';

/// Two-pane chat surface for desktop and unfolded foldables.
///
/// It deliberately composes the same widgets the phone flow uses
/// ([UsersListView], [ChatPage] and therefore [MessageBubble] / the shared
/// [MediaViewer]); there is no second chat implementation here. Only the
/// arrangement, the account-keyed selection, and the foldable toggle are new.
class ChatWorkspace extends StatefulWidget {
  const ChatWorkspace({
    super.key,
    required this.chat,
    required this.profile,
    required this.listHeader,
    this.presence,
    this.onlineFilter,
    this.onSessionExpired,
    this.visible = true,
    this.foldController,
    this.displayWidth,
  });

  final ChatService chat;
  final ProfileGateway profile;

  /// Brand/「消息」header shown above the conversation list only.
  final Widget listHeader;
  final PresenceDirectory? presence;
  final ValueNotifier<bool>? onlineFilter;
  final VoidCallback? onSessionExpired;

  /// Whether the host section that owns this workspace is the one on screen.
  ///
  /// A host that keeps this workspace mounted behind another section (the
  /// signed-in shell swaps chat and Space with an [IndexedStack]) still polls,
  /// but the reader cannot see the arrivals, so they must not become display
  /// facts. Selection alone answers "which conversation", not "is it shown".
  final bool visible;

  /// Host-owned animation for the full-screen fold transition.
  ///
  /// The host needs the same progress to slide its navigation rail out of the
  /// way while the chat grows over it: at 1024 px the chat has to reach screen
  /// x = 0, not the workspace's own local 0. Null keeps an internal controller
  /// for surfaces without a rail.
  final AnimationController? foldController;

  /// Physical display width when the host hides part of the screen from this
  /// widget (the signed-in shell reserves 92 px for its rail). The unfolded
  /// breakpoint is a device width; without this, an 800 px unfolded device
  /// would be judged at 708 px and lose its second pane.
  final double? displayWidth;

  /// Below this width the phone layout (route-pushed [ChatPage]) is used.
  static const double splitMinWidth = 900;

  /// With a real hinge or fold, the unfolded foldable can split from 720 px up.
  ///
  /// This is a *device* width: an unfolded 800 px foldable has two 400 px
  /// panes even when the host keeps 92 px for its navigation rail. Use
  /// [displayWidth] from the host for this breakpoint and [width] only for the
  /// rail-free desktop threshold.
  static const double foldedSplitMinWidth = 720;

  static const Key listPaneKey = Key('chat-workspace-list-pane');
  static const Key chatPaneKey = Key('chat-workspace-chat-pane');
  static const Key emptyChatKey = Key('chat-workspace-empty');
  static const Key toggleKey = Key('chat-workspace-fold-toggle');

  /// Total width the divider handle takes from the two panes: handle, padding
  /// and horizontal hit area included. The owner capped it at 20 logical
  /// pixels, so the panes keep their content width instead of a wide gutter.
  static const double foldGap = 20;

  /// The visible grip inside [foldGap]; the rest of the band is 2 px padding on
  /// each side. Vertically it keeps a comfortable 56 px target while only
  /// covering 20 px of the divider, so list rows and messages next to it stay
  /// clickable and scrollable.
  static const double foldHandleWidth = 16;
  static const double foldHandleHeight = 56;

  static const Duration foldDuration = Duration(milliseconds: 360);

  /// True when the device gives a physical, non-touchable strip.
  ///
  /// Flutter reports that strip as [DisplayFeatureType.hinge] whatever its
  /// logical size: real units range from 0 through a few pixels to ~40, and a
  /// 4 px hinge is just as untouchable as a 40 px one. Width alone must never
  /// decide this — treating a narrow hinge as a crease put the grip (and the
  /// arrow) on the hinge itself. [DisplayFeatureType.fold] is a crease that
  /// stays touchable, so it may be straddled.
  static bool hasHardHinge(DisplayFeature feature) =>
      feature.type == DisplayFeatureType.hinge;

  /// The pane boundary: the conversation list ends and the chat begins here.
  ///
  /// A hinge keeps its own non-touchable strip, so the list stops on its left
  /// edge and the chat starts on its right edge. A fold crease is a single
  /// line: both panes run right up to it, so neither loses width to the grip.
  static double dividerFor(DisplayFeature feature) =>
      hasHardHinge(feature) ? feature.bounds.right : feature.bounds.center.dx;

  /// Left edge of the 20 px grip band, which floats *above* the panes.
  ///
  /// A physical hinge is not touchable, so the grip floats just past its right
  /// edge, clear of the strip even when it is only 4 px wide. A fold crease has
  /// no untouchable strip, so the band is centred on the crease.
  static double bandLeftFor(DisplayFeature feature) => hasHardHinge(feature)
      ? feature.bounds.right
      : feature.bounds.center.dx - foldGap / 2;

  /// Where the conversation list has to stop: before a physical hinge, or on
  /// the fold crease itself (the floating band does not reserve any width).
  static double listStopFor(DisplayFeature feature) =>
      hasHardHinge(feature) ? feature.bounds.left : feature.bounds.center.dx;

  /// The vertical hinge or fold that separates two physical panes.
  ///
  /// A flat, zero-width `fold` is just as much an unfolded split boundary as a
  /// 40 px `hinge`; both are handled here. A horizontal feature (laptop-style
  /// fold) is not a left/right divider and is ignored.
  static DisplayFeature? splitFeatureOf(BuildContext context) {
    for (final DisplayFeature feature in MediaQuery.displayFeaturesOf(
      context,
    )) {
      final bool divider =
          feature.type == DisplayFeatureType.hinge ||
          feature.type == DisplayFeatureType.fold;
      if (divider && feature.bounds.width <= feature.bounds.height) {
        return feature;
      }
    }
    return null;
  }

  /// True when [width] gets the two-pane arrangement.
  ///
  /// Pass [displayWidth] when the host hides part of the screen from this
  /// widget (the signed-in shell keeps a 92 px rail): the unfolded breakpoint
  /// is a device width, so 800 px of display still means two panes even though
  /// only 708 px reach the workspace.
  static bool usesSplit(
    BuildContext context,
    double width, {
    double? displayWidth,
  }) {
    if (splitFeatureOf(context) == null) {
      return width >= splitMinWidth;
    }
    return (displayWidth ?? width) >= foldedSplitMinWidth;
  }

  @override
  State<ChatWorkspace> createState() => _ChatWorkspaceState();
}

class _ChatWorkspaceState extends State<ChatWorkspace>
    with SingleTickerProviderStateMixin {
  String? _selected;
  final List<String> _opened = <String>[];
  final Map<String, ChatUser> _peers = <String, ChatUser>{};
  bool _autoSelected = false;
  bool _resetScheduled = false;

  late bool _expanded = _fold.value > 0;

  AnimationController? _ownedFoldController;

  /// The host controller when one is shared, so the rail and the pane travel
  /// on the same ticker instead of two animations that drift apart.
  AnimationController get _fold =>
      widget.foldController ??
      (_ownedFoldController ??= AnimationController(
        vsync: this,
        duration: ChatWorkspace.foldDuration,
      ));

  @override
  void dispose() {
    _ownedFoldController?.dispose();
    super.dispose();
  }

  void _select(ChatUser user, {bool markViewed = true}) {
    if (!_peers.containsKey(user.account)) {
      _opened.add(user.account);
    }
    if (_selected == user.account) {
      return;
    }
    setState(() {
      _peers[user.account] = user;
      _selected = user.account;
    });
    if (markViewed) {
      // Same view fact the phone entry records; display bookkeeping only.
      unawaited(
        widget.chat
            .markConversationViewed(user.account)
            .then<void>((int _) {})
            .catchError((Object _) {}),
      );
    }
  }

  void _onDirectoryLoaded(List<ChatUser> users) {
    if (!mounted || _autoSelected || users.isEmpty) {
      return;
    }
    _autoSelected = true;
    // Show a conversation on first open instead of an empty right pane. This
    // is a presentation choice; it does not record a "viewed" fact.
    _select(users.first, markViewed: false);
  }

  void _toggleExpanded() {
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    setState(() => _expanded = !_expanded);
    if (reducedMotion) {
      _fold.value = _expanded ? 1 : 0;
      return;
    }
    if (_expanded) {
      _fold.forward();
    } else {
      _fold.reverse();
    }
  }

  void _scheduleFoldReset() {
    if (_resetScheduled) {
      return;
    }
    _resetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetScheduled = false;
      if (mounted && _fold.value != 0) {
        _fold.value = 0;
      }
    });
  }

  double _listWidth(double total, DisplayFeature? splitFeature) {
    if (splitFeature != null) {
      // Stop where the band starts. The 420 px chat floor must not apply here:
      // the divider is fixed by the device, so a floor would only open dead
      // space between the list edge and the fold (measured as a 40 px band at
      // 800 px).
      return ChatWorkspace.listStopFor(splitFeature)
          .clamp(0.0, math.max(0.0, total - ChatWorkspace.foldGap - 120));
    }
    return (total * 0.34).clamp(300.0, 380.0).clamp(0.0, total - 420);
  }

  @override
  Widget build(BuildContext context) {
    final DisplayFeature? splitFeature = ChatWorkspace.splitFeatureOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double total = constraints.maxWidth;
        final double height = constraints.maxHeight;
        final bool canExpand =
            splitFeature != null &&
            (widget.displayWidth ?? total) >= ChatWorkspace.foldedSplitMinWidth;
        if (!canExpand && (_expanded || _fold.value != 0)) {
          // The fold disappeared (window resize / device rotation) while the
          // chat was full screen. Give the rail back on the next frame instead
          // of leaving the host covering it with progress 1.
          _expanded = false;
          _scheduleFoldReset();
        }
        // The chat starts exactly at the pane boundary: the grip band floats
        // above both panes instead of reserving a gutter, so the whole strip on
        // either side of the crease belongs to a pane.
        final double dualLeft = splitFeature != null
            ? ChatWorkspace.dividerFor(splitFeature).clamp(0.0, total)
            : _listWidth(total, null);
        final Curve curve = _expanded
            ? Curves.easeOutBack
            : Curves.easeInOutCubic;
        final bool reducedMotion =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;

        Widget buildPanes(BuildContext context, Widget? child) {
          final double progress = canExpand
              ? (reducedMotion
                    ? (_expanded ? 1.0 : 0.0)
                    : curve.transform(_fold.value))
              : 0.0;
          // easeOutBack overshoots past 1: the chat's left edge travels a few
          // pixels beyond the screen edge, then settles back — a short jelly
          // bounce that never scales the message text or avatars.
          final double chatLeft = dualLeft * (1 - progress);
          final double chatWidth = math.max(0.0, total - chatLeft);
          // The grip band floats above the panes; it takes no layout width.
          final double bandLeft = splitFeature != null
              ? ChatWorkspace.bandLeftFor(splitFeature)
              : 0.0;
          final double bandTop = math.max(
            8.0,
            math.min(
              height - ChatWorkspace.foldHandleHeight - 8,
              height / 2 - 28,
            ),
          );

          return Stack(
            clipBehavior: Clip.hardEdge,
            // Child order stays fixed for a given split feature (line, chat,
            // grip). Reordering it would recreate the ChatPage mid-transition
            // and throw away the reading position. The grip is painted above
            // the chat pane, so it is the only child whose position changes.
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _listWidth(total, splitFeature),
                child: _listPane(divider: splitFeature == null),
              ),
              // A fold crease gets one hairline seam; on a hinge the physical
              // strip already separates the panes, so no extra line is drawn
              // over the chat.
              if (splitFeature != null &&
                  !ChatWorkspace.hasHardHinge(splitFeature))
                Positioned(
                  left: ChatWorkspace.dividerFor(splitFeature) - 0.5,
                  top: 0,
                  bottom: 0,
                  width: 1,
                  child: const ColoredBox(color: AppColors.border),
                ),
              Positioned(
                left: chatLeft,
                top: 0,
                bottom: 0,
                width: chatWidth,
                child: _chatPane(),
              ),
              // One grip, two homes: on the divider in the split state, hugging
              // the left screen edge once the chat is full screen. It only
              // fades in while the chat sweeps over (or off) the divider, so it
              // never floats over messages mid-transition.
              if (canExpand)
                Positioned(
                  left: _expanded ? 0 : bandLeft,
                  top: bandTop,
                  width: ChatWorkspace.foldGap,
                  height: ChatWorkspace.foldHandleHeight,
                  child: Opacity(
                    // Edge grip: only once the chat has almost reached the
                    // screen edge, so it never floats over the rail or the list
                    // mid-transition. Divider grip: full strength at rest,
                    // fading out as the chat sweeps across the crease (and back
                    // in while it retreats), so it never lingers over messages.
                    opacity: _expanded
                        ? ((ChatWorkspace.foldGap + 40 - chatLeft) / 40).clamp(
                            0.0,
                            1.0,
                          )
                        : (1 - progress).clamp(0.0, 1.0),
                    child: _FoldHandle(
                      expanded: _expanded,
                      onTap: _toggleExpanded,
                    ),
                  ),
                ),
            ],
          );
        }

        return AnimatedBuilder(animation: _fold, builder: buildPanes);
      },
    );
  }

  Widget _listPane({bool divider = true}) {
    return Container(
      key: ChatWorkspace.listPaneKey,
      decoration: BoxDecoration(
        color: AppColors.paper,
        // The band's own hairline is the divider in a folded layout, so the
        // list edge does not add a second line next to it.
        border: divider
            ? const Border(right: BorderSide(color: AppColors.border))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          widget.listHeader,
          Expanded(
            child: UsersListView(
              chat: widget.chat,
              profile: widget.profile,
              presence: widget.presence,
              onlineFilter: widget.onlineFilter,
              selectedAccount: _selected,
              onSelect: _select,
              onDirectoryLoaded: _onDirectoryLoaded,
              // The split surface never pushes a route; this keeps the
              // required callback a no-op for the shared list widget.
              onOpenChat: (ChatUser user) async => _select(user),
              onSessionExpired: widget.onSessionExpired,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatPane() {
    if (_selected == null) {
      return Container(
        color: AppColors.paper,
        alignment: Alignment.center,
        child: const Text(
          '选择一个会话开始聊天',
          key: ChatWorkspace.emptyChatKey,
          style: TextStyle(color: AppColors.inkMuted),
        ),
      );
    }
    final int index = _opened.indexOf(_selected!);
    return IndexedStack(
      key: ChatWorkspace.chatPaneKey,
      index: index < 0 ? 0 : index,
      children: <Widget>[
        for (final String account in _opened)
          ChatPage(
            key: ValueKey<String>('chat-workspace-page-$account'),
            peer: _peers[account]!,
            chat: widget.chat,
            profile: widget.profile,
            presence: widget.presence,
            embedded: true,
            // Only the visible conversation may confirm display facts; the
            // hidden pages keep polling data but stage their receipts. A pane
            // that the host section has covered counts as hidden too.
            active: widget.visible && account == _selected,
          ),
      ],
    );
  }
}

/// The narrow divider grip that replaces the old 44 px switch.
///
/// Owner cap: handle, padding and horizontal hit area together must stay
/// inside [ChatWorkspace.foldGap] (20 lp). Only the outline is emphasised —
/// pressed or keyboard-focused — so the control reads as part of the divider
/// instead of a floating button.
class _FoldHandle extends StatefulWidget {
  const _FoldHandle({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  State<_FoldHandle> createState() => _FoldHandleState();
}

class _FoldHandleState extends State<_FoldHandle> {
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool emphasised = _pressed || _focused;
    final BorderRadius radius = BorderRadius.circular(8);
    return Tooltip(
      message: widget.expanded ? '恢复双栏' : '全屏聊天',
      child: SizedBox(
        // The full band is the tap target, so the horizontal hit area is the
        // same 20 px the panes give up — it never reaches into a list row or a
        // message bubble.
        width: ChatWorkspace.foldGap,
        height: ChatWorkspace.foldHandleHeight,
        child: Center(
          child: Focus(
            onFocusChange: (bool hasFocus) =>
                setState(() => _focused = hasFocus),
            child: Material(
              color: AppColors.surface,
              borderRadius: radius,
              child: InkWell(
                key: ChatWorkspace.toggleKey,
                borderRadius: radius,
                onTap: widget.onTap,
                onHighlightChanged: (bool pressed) =>
                    setState(() => _pressed = pressed),
                child: Container(
                  width: ChatWorkspace.foldHandleWidth,
                  height: ChatWorkspace.foldHandleHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: emphasised
                          ? AppColors.accentDeep
                          : AppColors.border,
                    ),
                  ),
                  child: Icon(
                    widget.expanded
                        ? Icons.keyboard_double_arrow_right_rounded
                        : Icons.keyboard_double_arrow_left_rounded,
                    size: 12,
                    color: AppColors.accentDeep,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
