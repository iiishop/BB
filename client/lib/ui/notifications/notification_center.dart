import 'dart:math' as math;
import 'dart:ui' show DisplayFeature;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../display_features.dart';

/// Presentation values only. The integration maps the shared server contract
/// here; this widget never stores read/handled facts or invents action results.
class NotificationEntry {
  const NotificationEntry({
    required this.id,
    this.type,
    required this.title,
    required this.body,
    required this.timeLabel,
    this.read = false,
    this.statusLabel,
    this.invalidated = false,
    this.actions = const <NotificationEntryAction>[],
    this.onOpenDetails,
    this.onMarkRead,
  });

  final String id;
  final String? type;
  final String title;
  final String body;
  final String timeLabel;
  final bool read;
  final String? statusLabel;
  final bool invalidated;
  final List<NotificationEntryAction> actions;
  final VoidCallback? onOpenDetails;
  final VoidCallback? onMarkRead;

  bool get pending => !invalidated && actions.any((a) => a.available);
}

class NotificationEntryAction {
  const NotificationEntryAction({
    required this.id,
    required this.label,
    this.available = true,
    this.onPressed,
  });

  final String id;
  final String label;
  final bool available;
  final VoidCallback? onPressed;
}

/// General BB notifications, separate from the Space subtree and its badges.
class NotificationCenter extends StatefulWidget {
  const NotificationCenter({
    super.key,
    this.entries = const <NotificationEntry>[],
    this.available = true,
    this.loading = false,
    this.error,
    this.onRetry,
    this.pendingOnly,
    this.onFilterChanged,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreError,
    this.onLoadMore,
    this.allCount,
    this.pendingCount,
    this.unreadCount,
  });

  final List<NotificationEntry> entries;
  final bool available;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final bool? pendingOnly;
  final ValueChanged<bool>? onFilterChanged;
  final bool hasMore;
  final bool loadingMore;
  final String? loadMoreError;
  final VoidCallback? onLoadMore;
  final int? allCount;
  final int? pendingCount;
  final int? unreadCount;

  static const Key allKey = Key('notifications-all');
  static const Key pendingKey = Key('notifications-pending');
  static const Key loadMoreKey = Key('notifications-load-more');
  static Key entryKey(String id) => ValueKey('notification-$id');
  static Key actionKey(String id, String action) =>
      ValueKey('notification-$id-action-$action');
  static Key moreKey(String id) => ValueKey('notification-$id-more');
  static Key sheetActionKey(String id, String action) =>
      ValueKey('notification-$id-sheet-$action');

  @override
  State<NotificationCenter> createState() => _NotificationCenterState();
}

enum _TileTone { accent, success, neutral }

class _TypeVisual {
  const _TypeVisual({required this.icon, required this.tone});

  final IconData icon;
  final _TileTone tone;
}

class _SecondaryAction {
  const _SecondaryAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

class _NotificationCenterState extends State<NotificationCenter> {
  static const Color _hairColor = Color(0xFFF1EDE6);
  static const Color _neutralSoft = Color(0xFFF3F0EA);
  static const Color _accentLine = Color(0xFFBFD9D5);
  static const Color _countActiveBg = Color(0xFFD5E8E3);
  static const Color _unreadSurface = Color(0xFFFFFDF9);
  static const Color _unreadBorder = Color(0xFFD8D2C8);
  static const Color _infoBorder = Color(0xFFE7E2DA);
  static const Color _readBorder = Color(0xFFE9E4DC);
  static const Color _readBodyColor = Color(0xFF667273);
  static const Color _ledeSeparator = Color(0xFFB4AEA4);

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _scrollContentKey = GlobalKey();
  final GlobalKey _splitKey = GlobalKey();
  final GlobalKey _leftColumnKey = GlobalKey();
  final GlobalKey _rightColumnKey = GlobalKey();

  bool _pendingOnly = false;
  BuildContext? _openSheetContext;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _selectFilter(bool pendingOnly) {
    if (widget.pendingOnly == null) {
      setState(() => _pendingOnly = pendingOnly);
    }
    widget.onFilterChanged?.call(pendingOnly);
  }

  _TypeVisual _typeVisual(NotificationEntry entry) {
    final _TypeVisual base = switch (entry.type) {
      'group_invitation' || 'group_invite' => const _TypeVisual(
        icon: Icons.mark_email_unread_outlined,
        tone: _TileTone.accent,
      ),
      'group_application' => const _TypeVisual(
        icon: Icons.person_add_alt_1_outlined,
        tone: _TileTone.accent,
      ),
      'group_join_result' || 'group_member_joined' => const _TypeVisual(
        icon: Icons.check_circle_outline_rounded,
        tone: _TileTone.success,
      ),
      'group_member_left' => const _TypeVisual(
        icon: Icons.arrow_back_rounded,
        tone: _TileTone.neutral,
      ),
      'group_member_removed' => const _TypeVisual(
        icon: Icons.person_remove_outlined,
        tone: _TileTone.neutral,
      ),
      'group_dissolved' => const _TypeVisual(
        icon: Icons.link_off_rounded,
        tone: _TileTone.neutral,
      ),
      _ => _TypeVisual(
        icon: entry.pending
            ? Icons.mark_email_unread_outlined
            : Icons.notifications_none_rounded,
        tone: entry.pending ? _TileTone.accent : _TileTone.neutral,
      ),
    };
    if (!entry.pending && !entry.invalidated && entry.statusLabel == '已处理') {
      return _TypeVisual(icon: base.icon, tone: _TileTone.success);
    }
    return base;
  }

  List<_SecondaryAction> _secondaryActions(NotificationEntry entry) {
    final List<_SecondaryAction> items = <_SecondaryAction>[];
    if (entry.onOpenDetails != null) {
      items.add(
        _SecondaryAction(
          id: 'details',
          label: '查看资料',
          icon: Icons.arrow_forward_rounded,
          onPressed: entry.onOpenDetails!,
        ),
      );
    }
    if (!entry.read && !entry.invalidated && entry.onMarkRead != null) {
      items.add(
        _SecondaryAction(
          id: 'mark-read',
          label: '标为已读',
          icon: Icons.check_rounded,
          onPressed: entry.onMarkRead!,
        ),
      );
    }
    return items;
  }

  Future<void> _openActionSheet(
    BuildContext context,
    NotificationEntry entry,
    List<_SecondaryAction> actions,
  ) async {
    if (actions.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheetContext) {
        _openSheetContext = sheetContext;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    entry.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                ),
                for (final _SecondaryAction item in actions)
                  InkWell(
                    key: NotificationCenter.sheetActionKey(entry.id, item.id),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      item.onPressed();
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: <Widget>[
                          Icon(item.icon, size: 18, color: AppColors.accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              item.label,
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                const Divider(height: 1, thickness: 1, color: _hairColor),
                InkWell(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(12),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    alignment: Alignment.center,
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      _openSheetContext = null;
    });
  }

  double _computeStickyShift() {
    if (!_scrollController.hasClients) {
      return 0;
    }
    final BuildContext? viewportCtx = _viewportKey.currentContext;
    final BuildContext? contentCtx = _scrollContentKey.currentContext;
    final BuildContext? splitCtx = _splitKey.currentContext;
    final BuildContext? leftCtx = _leftColumnKey.currentContext;
    final BuildContext? rightCtx = _rightColumnKey.currentContext;
    if (viewportCtx == null ||
        contentCtx == null ||
        splitCtx == null ||
        leftCtx == null ||
        rightCtx == null) {
      return 0;
    }
    final RenderBox? viewportBox = viewportCtx.findRenderObject() as RenderBox?;
    final RenderBox? contentBox = contentCtx.findRenderObject() as RenderBox?;
    final RenderBox? splitBox = splitCtx.findRenderObject() as RenderBox?;
    final RenderBox? leftBox = leftCtx.findRenderObject() as RenderBox?;
    final RenderBox? rightBox = rightCtx.findRenderObject() as RenderBox?;
    if (viewportBox == null ||
        contentBox == null ||
        splitBox == null ||
        leftBox == null ||
        rightBox == null ||
        !viewportBox.hasSize ||
        !contentBox.hasSize ||
        !splitBox.hasSize ||
        !leftBox.hasSize ||
        !rightBox.hasSize) {
      return 0;
    }
    final double leftHeight = leftBox.size.height;
    final double rightHeight = rightBox.size.height;
    final double viewportHeight = viewportBox.size.height;
    if (leftHeight > viewportHeight - 48 || rightHeight <= leftHeight) {
      return 0;
    }
    final double splitTop = splitBox
        .localToGlobal(Offset.zero, ancestor: contentBox)
        .dy;
    final double maxShift = rightHeight - leftHeight;
    return (_scrollController.offset - (splitTop - 24)).clamp(0.0, maxShift);
  }

  @override
  Widget build(BuildContext context) {
    final bool pendingOnly = widget.pendingOnly ?? _pendingOnly;
    final List<NotificationEntry> entries = widget.entries
        .where((e) => !pendingOnly || e.pending)
        .toList(growable: false);
    final List<NotificationEntry> pendingEntries = entries
        .where((e) => e.pending)
        .toList(growable: false);
    final List<NotificationEntry> historyEntries = entries
        .where((e) => !e.pending)
        .toList(growable: false);

    final int pendingCount =
        widget.pendingCount ??
        widget.entries.where((NotificationEntry e) => e.pending).length;
    final int unreadCount =
        widget.unreadCount ??
        widget.entries.where((NotificationEntry e) => !e.read).length;
    final int? allCount =
        widget.allCount ??
        (widget.pendingOnly == null ? widget.entries.length : null);

    final MediaQueryData media = MediaQuery.of(context);
    double? foldedWidth;
    for (final DisplayFeature feature in media.displayFeatures) {
      if (isFlatFoldFeature(feature) &&
          isVerticalFeature(feature) &&
          feature.bounds.left > media.padding.left) {
        foldedWidth = (feature.bounds.left - media.padding.left).clamp(
          0,
          media.size.width,
        );
        break;
      }
    }

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Align(
          alignment: foldedWidth == null
              ? Alignment.topCenter
              : Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: foldedWidth ?? 1120),
            child: LayoutBuilder(
              key: _viewportKey,
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth;
                final bool isNarrow = width <= 560;
                final bool isMobile = width <= 720;
                final bool isStacked = width <= 960;
                final double textScale = media.textScaler.scale(1.0);

                if (!isMobile && _openSheetContext != null) {
                  final BuildContext sheetCtx = _openSheetContext!;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (sheetCtx.mounted) {
                      Navigator.of(sheetCtx).maybePop();
                    }
                  });
                }

                final EdgeInsets pagePadding = isNarrow
                    ? const EdgeInsets.fromLTRB(16, 24, 16, 36)
                    : isStacked
                    ? const EdgeInsets.fromLTRB(20, 30, 20, 40)
                    : const EdgeInsets.fromLTRB(32, 36, 32, 56);

                final bool showSummary =
                    !widget.loading && widget.available && widget.error == null;

                return SingleChildScrollView(
                  controller: _scrollController,
                  padding: pagePadding,
                  child: Column(
                    key: _scrollContentKey,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _buildPageHead(
                        context,
                        isNarrow: isNarrow,
                        isStacked: isStacked,
                        pendingOnly: pendingOnly,
                        showSummary: showSummary,
                        allEmpty: allCount == 0 && entries.isEmpty,
                        allCount: allCount,
                        pendingCount: pendingCount,
                        unreadCount: unreadCount,
                      ),
                      SizedBox(height: isNarrow ? 22 : 26),
                      _buildBody(
                        context,
                        viewportHeight: constraints.maxHeight,
                        isNarrow: isNarrow,
                        isMobile: isMobile,
                        isStacked: isStacked,
                        textScale: textScale,
                        pendingOnly: pendingOnly,
                        entries: entries,
                        pendingEntries: pendingEntries,
                        historyEntries: historyEntries,
                        allCount: allCount,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageHead(
    BuildContext context, {
    required bool isNarrow,
    required bool isStacked,
    required bool pendingOnly,
    required bool showSummary,
    required bool allEmpty,
    required int? allCount,
    required int pendingCount,
    required int unreadCount,
  }) {
    final Widget copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '通知',
          style: TextStyle(
            color: AppColors.ink,
            fontSize: isNarrow ? 27 : 30,
            height: 1.18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        if (showSummary) ...<Widget>[
          const SizedBox(height: 7),
          _buildLede(
            allEmpty: allEmpty,
            pendingCount: pendingCount,
            unreadCount: unreadCount,
          ),
        ],
      ],
    );

    final Widget filters = _buildFilters(
      isNarrow: isNarrow,
      pendingOnly: pendingOnly,
      allCount: allCount,
      pendingCount: pendingCount,
    );

    if (isStacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[copy, const SizedBox(height: 16), filters],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(child: copy),
        const SizedBox(width: 24),
        filters,
      ],
    );
  }

  Widget _buildLede({
    required bool allEmpty,
    required int pendingCount,
    required int unreadCount,
  }) {
    if (allEmpty) {
      return const Text(
        '暂无通知',
        style: TextStyle(
          color: AppColors.inkMuted,
          fontSize: 13.5,
          height: 1.4,
        ),
      );
    }
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: AppColors.inkMuted,
          fontSize: 13.5,
          height: 1.4,
        ),
        children: <InlineSpan>[
          if (pendingCount == 0)
            const TextSpan(
              text: '待处理已清空',
              style: TextStyle(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            TextSpan(
              text: '$pendingCount 条需要你处理',
              style: const TextStyle(
                color: AppColors.accentDeep,
                fontWeight: FontWeight.w700,
              ),
            ),
          const TextSpan(
            text: '  ·  ',
            style: TextStyle(color: _ledeSeparator),
          ),
          TextSpan(text: '$unreadCount 条未读'),
        ],
      ),
    );
  }

  Widget _buildFilters({
    required bool isNarrow,
    required bool pendingOnly,
    required int? allCount,
    required int pendingCount,
  }) {
    final Widget allBtn = _buildFilterButton(
      buttonKey: NotificationCenter.allKey,
      label: '全部',
      count: allCount,
      selected: !pendingOnly,
      expand: isNarrow,
      onTap: () => _selectFilter(false),
    );
    final Widget pendingBtn = _buildFilterButton(
      buttonKey: NotificationCenter.pendingKey,
      label: '待处理',
      count: pendingCount,
      selected: pendingOnly,
      expand: isNarrow,
      onTap: () => _selectFilter(true),
    );

    return Container(
      width: isNarrow ? double.infinity : null,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x05161D1E), offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        mainAxisSize: isNarrow ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          if (isNarrow) Expanded(child: allBtn) else allBtn,
          const SizedBox(width: 2),
          if (isNarrow) Expanded(child: pendingBtn) else pendingBtn,
        ],
      ),
    );
  }

  Widget _buildFilterButton({
    required Key buttonKey,
    required String label,
    required int? count,
    required bool selected,
    required bool expand,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: buttonKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : Colors.transparent,
            border: Border.all(
              color: selected ? _accentLine : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: expand ? Alignment.center : null,
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.accentDeep : AppColors.inkMuted,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 7),
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? _countActiveBg : _neutralSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$count',
                    style: TextStyle(
                      color: selected
                          ? AppColors.accentDeep
                          : AppColors.inkMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required double viewportHeight,
    required bool isNarrow,
    required bool isMobile,
    required bool isStacked,
    required double textScale,
    required bool pendingOnly,
    required List<NotificationEntry> entries,
    required List<NotificationEntry> pendingEntries,
    required List<NotificationEntry> historyEntries,
    required int? allCount,
  }) {
    if (widget.loading) {
      return SizedBox(
        height: math.max(200, viewportHeight - 220),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!widget.available || widget.error != null) {
      final String message = widget.error ?? '通知暂不可用';
      return _buildEmptyCard(
        context,
        isNarrow: isNarrow,
        icon: Icons.notifications_none_rounded,
        positive: false,
        title: message,
        actionLabel: widget.onRetry != null ? '重新加载' : null,
        onAction: widget.onRetry,
      );
    }

    final bool showFooter =
        widget.hasMore || widget.loadingMore || widget.loadMoreError != null;

    if (pendingOnly) {
      if (pendingEntries.isEmpty) {
        final bool canShowAll = (allCount ?? 1) > 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildEmptyCard(
              context,
              isNarrow: isNarrow,
              icon: Icons.check_circle_outline_rounded,
              positive: true,
              title: '没有待处理的通知',
              actionLabel: canShowAll ? '查看全部通知' : null,
              onAction: canShowAll ? () => _selectFilter(false) : null,
            ),
            if (showFooter) ...<Widget>[
              const SizedBox(height: 16),
              _buildLoadMoreFooter(context),
            ],
          ],
        );
      }
      return Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildSectionHead('需要你处理', pendingEntries.length, hot: true),
              _buildPendingStack(
                context,
                pendingEntries,
                isMobile: isMobile,
                textScale: textScale,
              ),
              if (showFooter) ...<Widget>[
                const SizedBox(height: 16),
                _buildLoadMoreFooter(context),
              ],
            ],
          ),
        ),
      );
    }

    if (entries.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildEmptyCard(
            context,
            isNarrow: isNarrow,
            icon: Icons.notifications_none_rounded,
            positive: false,
            title: '暂无通知',
          ),
          if (showFooter) ...<Widget>[
            const SizedBox(height: 16),
            _buildLoadMoreFooter(context),
          ],
        ],
      );
    }

    final Widget pendingSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSectionHead('需要你处理', pendingEntries.length, hot: true),
        if (pendingEntries.isNotEmpty)
          _buildPendingStack(
            context,
            pendingEntries,
            isMobile: isMobile,
            textScale: textScale,
          )
        else
          _buildClearedBox(),
      ],
    );

    final Widget historySection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildSectionHead('通知记录', historyEntries.length),
        _buildHistoryPanel(
          context,
          historyEntries,
          isMobile: isMobile,
          textScale: textScale,
        ),
      ],
    );

    if (isStacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          pendingSection,
          const SizedBox(height: 30),
          historySection,
          if (showFooter) ...<Widget>[
            const SizedBox(height: 16),
            _buildLoadMoreFooter(context),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          key: _splitKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: AnimatedBuilder(
                animation: _scrollController,
                child: KeyedSubtree(key: _leftColumnKey, child: pendingSection),
                builder: (BuildContext context, Widget? child) {
                  final double shift = _computeStickyShift();
                  if (shift == 0) {
                    return child!;
                  }
                  return Transform.translate(
                    offset: Offset(0, shift),
                    child: child,
                  );
                },
              ),
            ),
            const SizedBox(width: 30),
            Expanded(
              child: KeyedSubtree(key: _rightColumnKey, child: historySection),
            ),
          ],
        ),
        if (showFooter) ...<Widget>[
          const SizedBox(height: 16),
          _buildLoadMoreFooter(context),
        ],
      ],
    );
  }

  Widget _buildEmptyCard(
    BuildContext context, {
    required bool isNarrow,
    required IconData icon,
    required bool positive,
    required String title,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final TextStyle buttonStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        );
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            isNarrow ? 20 : 24,
            isNarrow ? 44 : 54,
            isNarrow ? 20 : 24,
            isNarrow ? 40 : 50,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: positive ? AppColors.successSurface : _neutralSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 26,
                  color: positive ? AppColors.success : AppColors.inkMuted,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: 22),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accentDeep,
                    foregroundColor: AppColors.surface,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    textStyle: buttonStyle,
                  ),
                  onPressed: onAction,
                  child: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHead(String title, int count, {bool hot = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.05,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            constraints: const BoxConstraints(minWidth: 22, minHeight: 20),
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: hot ? AppColors.accentSoft : _neutralSoft,
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: Text(
              '$count',
              style: TextStyle(
                color: hot ? AppColors.accentDeep : AppColors.inkMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClearedBox() {
    return CustomPaint(
      painter: _DashedRRectPainter(color: _unreadBorder, radius: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: AppColors.successSurface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 16,
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '待处理已清空',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingStack(
    BuildContext context,
    List<NotificationEntry> entries, {
    required bool isMobile,
    required double textScale,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < entries.length; i += 1) ...<Widget>[
          if (i > 0) const SizedBox(height: 14),
          _buildPendingCard(
            context,
            entries[i],
            isMobile: isMobile,
            textScale: textScale,
          ),
        ],
      ],
    );
  }

  Widget _buildPendingCard(
    BuildContext context,
    NotificationEntry entry, {
    required bool isMobile,
    required double textScale,
  }) {
    final _TypeVisual visual = _typeVisual(entry);
    final List<NotificationEntryAction> availableActions = entry.actions
        .where((NotificationEntryAction a) => a.available)
        .toList(growable: false);
    final List<_SecondaryAction> secondary = _secondaryActions(entry);

    return Semantics(
      label: '${entry.read ? '已读' : '未读'} · ${entry.title}',
      child: Container(
        key: NotificationCenter.entryKey(entry.id),
        padding: isMobile
            ? const EdgeInsets.all(14)
            : const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(isMobile ? 18 : 20),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Color(0x06161D1E), offset: Offset(0, 1)),
            BoxShadow(
              color: Color(0x10161D1E),
              blurRadius: 24,
              spreadRadius: -14,
              offset: Offset(0, 14),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildIconTile(
              visual,
              size: isMobile ? 36 : 44,
              radius: isMobile ? 12 : 14,
              iconSize: isMobile ? 18 : 20,
            ),
            SizedBox(width: isMobile ? 10 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildMetaRow(entry),
                  SizedBox(height: isMobile ? 6 : 8),
                  Text(
                    entry.title,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: isMobile ? 15.5 : 17,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                    ),
                  ),
                  SizedBox(height: isMobile ? 3 : 5),
                  Text(
                    entry.body,
                    style: TextStyle(
                      color: entry.read ? _readBodyColor : AppColors.inkMuted,
                      fontSize: isMobile ? 13 : 14,
                      height: 1.55,
                    ),
                  ),
                  if (availableActions.isNotEmpty ||
                      secondary.isNotEmpty) ...<Widget>[
                    SizedBox(height: isMobile ? 10 : 14),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.only(top: isMobile ? 10 : 13),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: _hairColor)),
                      ),
                      child: isMobile
                          ? _buildMobileCardActions(
                              context,
                              entry,
                              availableActions: availableActions,
                              secondary: secondary,
                              textScale: textScale,
                            )
                          : _buildDesktopCardActions(
                              context,
                              entry,
                              availableActions: availableActions,
                              secondary: secondary,
                            ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopCardActions(
    BuildContext context,
    NotificationEntry entry, {
    required List<NotificationEntryAction> availableActions,
    required List<_SecondaryAction> secondary,
  }) {
    final List<Widget> primaryButtons = <Widget>[
      for (final NotificationEntryAction action in availableActions)
        _buildActionButton(context, entry.id, action, compact: false),
    ];
    final List<Widget> linkWidgets = <Widget>[
      for (final _SecondaryAction item in secondary)
        _buildLinkButton(context, item),
    ];
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: <Widget>[
          if (primaryButtons.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 6, children: primaryButtons),
          if (linkWidgets.isNotEmpty)
            Wrap(spacing: 2, runSpacing: 4, children: linkWidgets),
        ],
      ),
    );
  }

  Widget _buildMobileCardActions(
    BuildContext context,
    NotificationEntry entry, {
    required List<NotificationEntryAction> availableActions,
    required List<_SecondaryAction> secondary,
    required double textScale,
  }) {
    if (availableActions.length > 2 || textScale > 1.35) {
      return SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            if (availableActions.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final NotificationEntryAction action in availableActions)
                    _buildActionButton(
                      context,
                      entry.id,
                      action,
                      compact: true,
                    ),
                ],
              ),
            if (secondary.isNotEmpty)
              _buildMoreButton(context, entry, secondary),
          ],
        ),
      );
    }

    return Row(
      children: <Widget>[
        if (availableActions.isNotEmpty)
          Expanded(
            child: Row(
              children: <Widget>[
                for (
                  int i = 0;
                  i < availableActions.length;
                  i += 1
                ) ...<Widget>[
                  if (i > 0) const SizedBox(width: 6),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: SizedBox(
                        width: double.infinity,
                        child: _buildActionButton(
                          context,
                          entry.id,
                          availableActions[i],
                          compact: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (secondary.isNotEmpty) ...<Widget>[
          if (availableActions.isNotEmpty) const SizedBox(width: 6),
          _buildMoreButton(context, entry, secondary),
        ],
      ],
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    String entryId,
    NotificationEntryAction action, {
    required bool compact,
  }) {
    final bool isReject = action.id == 'reject';
    final EdgeInsets padding = compact
        ? const EdgeInsets.symmetric(horizontal: 10)
        : const EdgeInsets.symmetric(horizontal: 18);
    final TextStyle labelStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        );
    if (isReject) {
      return OutlinedButton(
        key: NotificationCenter.actionKey(entryId, action.id),
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.danger,
          minimumSize: const Size(48, 44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: padding,
          side: const BorderSide(color: AppColors.dangerBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: labelStyle,
        ),
        onPressed: action.onPressed,
        child: Text(action.label),
      );
    }
    return FilledButton(
      key: NotificationCenter.actionKey(entryId, action.id),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accentDeep,
        foregroundColor: AppColors.surface,
        minimumSize: const Size(48, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: padding,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: labelStyle,
      ),
      onPressed: action.onPressed,
      child: Text(action.label),
    );
  }

  Widget _buildLinkButton(BuildContext context, _SecondaryAction action) {
    final TextStyle labelStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        );
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentDeep,
        minimumSize: const Size(48, 44),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: labelStyle,
      ),
      onPressed: action.onPressed,
      icon: Icon(action.icon, size: 14, color: AppColors.accent),
      label: Text(action.label),
    );
  }

  Widget _buildMoreButton(
    BuildContext context,
    NotificationEntry entry,
    List<_SecondaryAction> secondary,
  ) {
    return InkWell(
      key: NotificationCenter.moreKey(entry.id),
      borderRadius: BorderRadius.circular(10),
      onTap: () => _openActionSheet(context, entry, secondary),
      child: Container(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '更多',
              style: TextStyle(
                color: AppColors.accentDeep,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: AppColors.accentDeep,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryPanel(
    BuildContext context,
    List<NotificationEntry> entries, {
    required bool isMobile,
    required double textScale,
  }) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 14 : 20,
        2,
        isMobile ? 14 : 20,
        isMobile ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(isMobile ? 20 : 24),
      ),
      child: entries.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Text(
                '还没有通知记录。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkMuted, fontSize: 13.5),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < entries.length; i += 1) ...<Widget>[
                  if (i > 0)
                    const Divider(height: 1, thickness: 1, color: _hairColor),
                  _buildHistoryRow(
                    context,
                    entries[i],
                    isMobile: isMobile,
                    textScale: textScale,
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildHistoryRow(
    BuildContext context,
    NotificationEntry entry, {
    required bool isMobile,
    required double textScale,
  }) {
    final _TypeVisual visual = _typeVisual(entry);
    final List<_SecondaryAction> secondary = _secondaryActions(entry);
    final bool showMobileMore = isMobile && secondary.isNotEmpty;
    final double trailingReserve = showMobileMore
        ? (textScale > 1.35 ? 68 : 52)
        : 0;

    final Widget content = Padding(
      padding: EdgeInsets.symmetric(vertical: isMobile ? 13 : 17),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildIconTile(
            visual,
            size: isMobile ? 32 : 36,
            radius: isMobile ? 10 : 12,
            iconSize: isMobile ? 16 : 18,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(right: trailingReserve),
                  child: _buildMetaRow(entry),
                ),
                SizedBox(height: isMobile ? 4 : 6),
                Padding(
                  padding: EdgeInsets.only(right: trailingReserve),
                  child: Text(
                    entry.title,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: isMobile ? 15 : 15.5,
                      height: 1.4,
                      fontWeight: entry.read
                          ? FontWeight.w500
                          : FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  entry.body,
                  style: TextStyle(
                    color: entry.read ? _readBodyColor : AppColors.inkMuted,
                    fontSize: isMobile ? 13 : 13.5,
                    height: 1.55,
                  ),
                ),
                if (!isMobile && secondary.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 2,
                    runSpacing: 2,
                    children: <Widget>[
                      for (final _SecondaryAction item in secondary)
                        _buildLinkButton(context, item),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: '${entry.read ? '已读' : '未读'} · ${entry.title}',
      child: KeyedSubtree(
        key: NotificationCenter.entryKey(entry.id),
        child: showMobileMore
            ? Stack(
                children: <Widget>[
                  content,
                  Positioned(
                    top: 4,
                    right: 0,
                    child: _buildMoreButton(context, entry, secondary),
                  ),
                ],
              )
            : content,
      ),
    );
  }

  Widget _buildIconTile(
    _TypeVisual visual, {
    required double size,
    required double radius,
    required double iconSize,
  }) {
    final (Color bg, Color fg) = switch (visual.tone) {
      _TileTone.accent => (AppColors.accentSoft, AppColors.accentDeep),
      _TileTone.success => (AppColors.successSurface, AppColors.success),
      _TileTone.neutral => (_neutralSoft, AppColors.inkMuted),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(visual.icon, size: iconSize, color: fg),
    );
  }

  Widget _buildMetaRow(NotificationEntry entry) {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[_buildLifecycleTag(entry), _buildReadTag(entry)],
          ),
          Text(
            entry.timeLabel,
            style: const TextStyle(color: AppColors.chatTime, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildLifecycleTag(NotificationEntry entry) {
    final (
      String label,
      IconData icon,
      Color bg,
      Color border,
      Color fg,
    ) = entry.pending
        ? (
            entry.statusLabel ?? '待处理',
            Icons.outlined_flag_rounded,
            AppColors.accentSoft,
            _accentLine,
            AppColors.accentDeep,
          )
        : entry.invalidated
        ? (
            '已失效',
            Icons.info_outline_rounded,
            _neutralSoft,
            _infoBorder,
            AppColors.inkMuted,
          )
        : entry.statusLabel == '已处理'
        ? (
            '已处理',
            Icons.check_rounded,
            AppColors.successSurface,
            AppColors.successBorder,
            AppColors.success,
          )
        : (
            entry.statusLabel ?? '仅告知',
            Icons.info_outline_rounded,
            _neutralSoft,
            _infoBorder,
            AppColors.inkMuted,
          );

    return _buildTagPill(
      bg: bg,
      border: border,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadTag(NotificationEntry entry) {
    if (entry.read) {
      return _buildTagPill(
        bg: _neutralSoft,
        border: _readBorder,
        child: const Text(
          '已读',
          style: TextStyle(
            color: AppColors.inkMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
        ),
      );
    }
    return _buildTagPill(
      bg: _unreadSurface,
      border: _unreadBorder,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            '未读',
            style: TextStyle(
              color: AppColors.ink,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTagPill({
    required Color bg,
    required Color border,
    required Widget child,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 21),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: child,
    );
  }

  Widget _buildLoadMoreFooter(BuildContext context) {
    if (widget.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (widget.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              widget.loadMoreError!,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            OutlinedButton(
              key: NotificationCenter.loadMoreKey,
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: widget.onLoadMore,
              child: const Text('重试加载更多'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Center(
        child: TextButton(
          key: NotificationCenter.loadMoreKey,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: widget.onLoadMore,
          child: const Text('加载更多'),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final RRect rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(0.5);
    final Path path = Path()..addRRect(rrect);
    const double dash = 5;
    const double gap = 4;
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
