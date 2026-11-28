import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/chat_models.dart';
import '../../models/group_models.dart';
import '../widgets/profile_avatar.dart';

/// Shared conversation header used by both pushed mobile routes and the
/// embedded desktop/foldable split pane.
class ChatHeader extends StatelessWidget implements PreferredSizeWidget {
  const ChatHeader({
    super.key,
    required this.displayName,
    required this.isGroup,
    required this.avatarBytes,
    required this.avatarLoading,
    required this.avatarSemanticLabel,
    required this.onAvatarTap,
    required this.onRefresh,
    this.groupNumber,
    this.groupCounts,
    this.groupCountsLoading = false,
    this.groupCountsChangeTick = 0,
    this.peerPresence,
    this.embedded = false,
    this.leading,
  });

  static const double headerHeight = 72;
  static const double headerAvatarSize = 48;

  static const Key headerNameKey = Key('chat-header-name');
  static const Key headerStatusKey = Key('chat-header-status');
  static const Key headerProfileKey = Key('chat-header-profile');
  static const Key headerGroupCountKey = Key('chat-header-group-count');
  static const Key refreshKey = Key('chat-refresh');

  final String displayName;
  final bool isGroup;
  final Uint8List? avatarBytes;
  final bool avatarLoading;
  final String avatarSemanticLabel;
  final VoidCallback onAvatarTap;
  final VoidCallback? onRefresh;
  final String? groupNumber;
  final GroupMemberCounts? groupCounts;
  final bool groupCountsLoading;
  final int groupCountsChangeTick;
  final Presence? peerPresence;
  final bool embedded;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(headerHeight);

  double get _titleInset {
    if (leading != null) {
      return 8;
    }
    return embedded ? 16 : 8;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AppBar(
      toolbarHeight: headerHeight,
      backgroundColor: AppColors.surface,
      surfaceTintColor: AppColors.surface,
      elevation: 0,
      scrolledUnderElevation: 1,
      shape: isGroup
          ? const Border(bottom: BorderSide(color: AppColors.border))
          : null,
      automaticallyImplyLeading: !embedded && leading == null,
      leading: leading,
      leadingWidth: leading != null ? 56 : (embedded ? null : 48),
      titleSpacing: _titleInset,
      title: Row(
        children: <Widget>[
          ProfileAvatar(
            key: headerProfileKey,
            bytes: avatarBytes,
            size: headerAvatarSize,
            showBorder: true,
            loading: avatarLoading,
            semanticLabel: avatarSemanticLabel,
            onTap: onAvatarTap,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        displayName,
                        key: headerNameKey,
                        style: text.titleLarge?.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isGroup) ...<Widget>[
                      const SizedBox(width: 6),
                      GroupCountBadge(
                        key: headerGroupCountKey,
                        counts: groupCounts,
                        loading: groupCountsLoading,
                        changeTick: groupCountsChangeTick,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                if (isGroup)
                  Text(
                    '群号 ${groupNumber ?? ''}',
                    key: headerStatusKey,
                    style: text.bodySmall?.copyWith(
                      fontSize: 12.5,
                      color: AppColors.inkMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    peerPresence == Presence.online ? '在线' : '离线',
                    key: headerStatusKey,
                    style: text.bodySmall?.copyWith(
                      fontSize: 12.5,
                      color: peerPresence == Presence.online
                          ? AppColors.accent
                          : AppColors.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: <Widget>[
        _HeaderRefreshButton(
          buttonKey: refreshKey,
          loading: isGroup && groupCountsLoading,
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

/// Non-interactive group online/total badge (DEA-512 selected variant A).
class GroupCountBadge extends StatefulWidget {
  const GroupCountBadge({
    super.key,
    required this.counts,
    this.loading = false,
    this.changeTick = 0,
  });

  final GroupMemberCounts? counts;
  final bool loading;
  final int changeTick;

  static const Color zeroBackground = Color(0xFFF1EFEA);
  static const Color unknownBorder = Color(0xFFC2CFCC);

  @override
  State<GroupCountBadge> createState() => _GroupCountBadgeState();
}

class _GroupCountBadgeState extends State<GroupCountBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enterController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late final Animation<double> _enterOpacity = Tween<double>(
    begin: 0.3,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _enterController, curve: Curves.easeOut));
  late final Animation<double> _enterOffsetY = Tween<double>(
    begin: 2.0,
    end: 0.0,
  ).animate(CurvedAnimation(parent: _enterController, curve: Curves.easeOut));

  @override
  void didUpdateWidget(covariant GroupCountBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.counts == null) {
      _enterController.value = 1;
      return;
    }
    if (widget.changeTick != oldWidget.changeTick) {
      final bool reducedMotion =
          MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (reducedMotion) {
        _enterController.value = 1;
      } else {
        _enterController.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _enterController.dispose();
    super.dispose();
  }

  String _semanticLabel(GroupMemberCounts? counts) {
    if (counts == null) {
      return '在线人数暂时未知';
    }
    if (counts.online == 0) {
      return '当前无人在线，共 ${counts.total} 人';
    }
    return '在线 ${counts.online} 人，共 ${counts.total} 人';
  }

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final GroupMemberCounts? counts = widget.counts;
    final bool isUnknown = counts == null;
    final bool isZero = counts != null && counts.online == 0;
    final Color foreground = isUnknown || isZero
        ? AppColors.inkMuted
        : AppColors.accentDeep;
    final Color background = isUnknown
        ? Colors.transparent
        : (isZero ? GroupCountBadge.zeroBackground : AppColors.accentSoft);
    final String onlineText = isUnknown ? '—' : '${counts.online}';
    final String totalText = isUnknown ? '—' : '${counts.total}';

    final Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.0,
                letterSpacing: 0.2,
                color: foreground,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
              children: <InlineSpan>[
                TextSpan(text: onlineText),
                TextSpan(
                  text: '/',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: foreground.withValues(alpha: 0.55),
                  ),
                ),
                TextSpan(text: totalText),
              ],
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ),
    );

    final Widget framed = isUnknown
        ? CustomPaint(
            painter: const _DashedRRectPainter(
              color: GroupCountBadge.unknownBorder,
              radius: 7,
              strokeWidth: 1,
              dashWidth: 3.5,
              dashGap: 2.5,
            ),
            child: content,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(7),
            ),
            child: content,
          );

    return Semantics(
      container: true,
      label: _semanticLabel(counts),
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: widget.loading ? 0.45 : 1.0,
        duration: reducedMotion
            ? Duration.zero
            : const Duration(milliseconds: 120),
        child: AnimatedBuilder(
          animation: _enterController,
          builder: (BuildContext context, Widget? child) {
            return Opacity(
              opacity: _enterOpacity.value,
              child: Transform.translate(
                offset: Offset(0, _enterOffsetY.value),
                child: child,
              ),
            );
          },
          child: framed,
        ),
      ),
    );
  }
}

class _HeaderRefreshButton extends StatefulWidget {
  const _HeaderRefreshButton({
    required this.buttonKey,
    required this.loading,
    required this.onPressed,
  });

  final Key buttonKey;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  State<_HeaderRefreshButton> createState() => _HeaderRefreshButtonState();
}

class _HeaderRefreshButtonState extends State<_HeaderRefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _HeaderRefreshButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loading != widget.loading) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.loading && !reducedMotion) {
      if (!_spinController.isAnimating) {
        _spinController.repeat();
      }
    } else {
      _spinController
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reducedMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Widget icon = const Icon(Icons.refresh_rounded);
    if (widget.loading && reducedMotion) {
      icon = Opacity(opacity: 0.5, child: icon);
    } else if (widget.loading) {
      icon = RotationTransition(turns: _spinController, child: icon);
    }
    return IconButton(
      key: widget.buttonKey,
      tooltip: '刷新消息',
      onPressed: widget.onPressed,
      icon: icon,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dashWidth,
    required this.dashGap,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashWidth;
  final double dashGap;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(strokeWidth / 2);
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }
    final RRect rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(math.max(0, radius - strokeWidth / 2)),
    );
    final Path outline = Path()..addRRect(rrect);
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (final ui.PathMetric metric in outline.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double next = math.min(distance + dashWidth, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.radius != radius ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.dashWidth != dashWidth ||
        oldDelegate.dashGap != dashGap;
  }
}
