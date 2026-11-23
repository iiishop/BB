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

  /// Below this width the phone layout (route-pushed [ChatPage]) is used.
  static const double splitMinWidth = 900;

  /// With a real hinge or fold, the unfolded foldable can split from 720 px up.
  static const double foldedSplitMinWidth = 720;

  static const Key listPaneKey = Key('chat-workspace-list-pane');
  static const Key chatPaneKey = Key('chat-workspace-chat-pane');
  static const Key emptyChatKey = Key('chat-workspace-empty');
  static const Key toggleKey = Key('chat-workspace-fold-toggle');

  /// Real, content-free gutter between the panes on a folded device. The
  /// switch lives here instead of on top of a message avatar.
  static const double foldGap = 56;

  static const Duration foldDuration = Duration(milliseconds: 360);

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
  static bool usesSplit(BuildContext context, double width) {
    if (width < foldedSplitMinWidth) {
      return false;
    }
    return splitFeatureOf(context) != null || width >= splitMinWidth;
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
      // Stop at the divider, not across it; the right pane starts after it.
      return splitFeature.bounds.left.clamp(0.0, math.max(0.0, total - 420));
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
            splitFeature != null && total >= ChatWorkspace.foldedSplitMinWidth;
        if (!canExpand && (_expanded || _fold.value != 0)) {
          // The fold disappeared (window resize / device rotation) while the
          // chat was full screen. Give the rail back on the next frame instead
          // of leaving the host covering it with progress 1.
          _expanded = false;
          _scheduleFoldReset();
        }
        final double dualLeft = splitFeature != null
            ? (splitFeature.bounds.right + ChatWorkspace.foldGap).clamp(
                0.0,
                total - 320,
              )
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
          final double toggleLeft = splitFeature != null
              ? (splitFeature.bounds.right + 6).clamp(
                  8.0,
                  math.max(8.0, total - 52),
                )
              : 8.0;

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _listWidth(total, splitFeature),
                child: _listPane(),
              ),
              Positioned(
                left: chatLeft,
                top: 0,
                bottom: 0,
                width: chatWidth,
                child: _chatPane(canExpand && _expanded),
              ),
              // In the split state the switch sits in the gutter between the
              // panes. Expanded, it moves into the chat AppBar's leading slot
              // so it never covers a message.
              if (canExpand && !_expanded)
                Positioned(
                  left: toggleLeft,
                  top: math.max(8.0, height / 2 - 22),
                  child: _FoldToggle(expanded: false, onTap: _toggleExpanded),
                ),
            ],
          );
        }

        return AnimatedBuilder(animation: _fold, builder: buildPanes);
      },
    );
  }

  Widget _listPane() {
    return Container(
      key: ChatWorkspace.listPaneKey,
      decoration: const BoxDecoration(
        color: AppColors.paper,
        border: Border(right: BorderSide(color: AppColors.border)),
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

  Widget _chatPane(bool withToggle) {
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
            leading: withToggle
                ? _FoldToggle(expanded: true, onTap: _toggleExpanded)
                : null,
          ),
      ],
    );
  }
}

class _FoldToggle extends StatelessWidget {
  const _FoldToggle({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: expanded ? '恢复双栏' : '全屏聊天',
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
        elevation: 3,
        child: InkWell(
          key: ChatWorkspace.toggleKey,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              expanded
                  ? Icons.keyboard_double_arrow_right_rounded
                  : Icons.keyboard_double_arrow_left_rounded,
              size: 20,
              color: AppColors.accentDeep,
            ),
          ),
        ),
      ),
    );
  }
}
