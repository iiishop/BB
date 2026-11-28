import 'package:flutter/material.dart';

import '../../app.dart';
import '../display_features.dart';

/// Presentation values only. The integration maps the shared server contract
/// here; this widget never stores read/handled facts or invents action results.
class NotificationEntry {
  const NotificationEntry({
    required this.id,
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

  static const Key allKey = Key('notifications-all');
  static const Key pendingKey = Key('notifications-pending');
  static const Key loadMoreKey = Key('notifications-load-more');
  static Key entryKey(String id) => ValueKey('notification-$id');
  static Key actionKey(String id, String action) =>
      ValueKey('notification-$id-action-$action');

  @override
  State<NotificationCenter> createState() => _NotificationCenterState();
}

class _NotificationCenterState extends State<NotificationCenter> {
  bool _pendingOnly = false;

  void _selectFilter(bool pendingOnly) {
    if (widget.pendingOnly == null) {
      setState(() => _pendingOnly = pendingOnly);
    }
    widget.onFilterChanged?.call(pendingOnly);
  }

  @override
  Widget build(BuildContext context) {
    final bool pendingOnly = widget.pendingOnly ?? _pendingOnly;
    final List<NotificationEntry> entries = widget.entries
        .where((e) => !pendingOnly || e.pending)
        .toList();
    final MediaQueryData media = MediaQuery.of(context);
    double? foldedWidth;
    for (final feature in media.displayFeatures) {
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
              ? Alignment.center
              : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: foldedWidth ?? 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: Text(
                    '通知',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    children: <Widget>[
                      ChoiceChip(
                        key: NotificationCenter.allKey,
                        label: const Text('全部'),
                        selected: !pendingOnly,
                        onSelected: (_) => _selectFilter(false),
                      ),
                      ChoiceChip(
                        key: NotificationCenter.pendingKey,
                        label: const Text('待处理'),
                        selected: pendingOnly,
                        onSelected: (_) => _selectFilter(true),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Expanded(child: _content(entries, pendingOnly: pendingOnly)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    List<NotificationEntry> entries, {
    required bool pendingOnly,
  }) {
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!widget.available || widget.error != null || entries.isEmpty) {
      final String message =
          widget.error ??
          (!widget.available
              ? '通知暂不可用'
              : pendingOnly
              ? '没有待处理的通知'
              : '暂无通知');
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.notifications_none_rounded,
                size: 36,
                color: AppColors.inkMuted,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(message, textAlign: TextAlign.center),
              if (widget.onRetry != null)
                TextButton(
                  onPressed: widget.onRetry,
                  child: const Text('重新加载'),
                ),
            ],
          ),
        ),
      );
    }
    final bool showFooter =
        widget.hasMore || widget.loadingMore || widget.loadMoreError != null;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      itemCount: entries.length + (showFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        if (index >= entries.length) {
          return _buildLoadMoreFooter(context);
        }
        final NotificationEntry entry = entries[index];
        return Semantics(
          label: entry.read ? '已读' : '未读',
          child: Container(
            key: NotificationCenter.entryKey(entry.id),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(entry.body),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '${entry.timeLabel} · ${entry.read ? '已读' : '未读'}${entry.invalidated
                      ? ' · 已失效'
                      : entry.statusLabel == null
                      ? ''
                      : ' · ${entry.statusLabel}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (entry.onOpenDetails != null ||
                    (!entry.read &&
                        !entry.invalidated &&
                        entry.onMarkRead != null))
                  Wrap(
                    spacing: AppSpacing.xs,
                    children: <Widget>[
                      if (entry.onOpenDetails != null)
                        TextButton(
                          onPressed: entry.onOpenDetails,
                          child: const Text('查看资料'),
                        ),
                      if (!entry.read &&
                          !entry.invalidated &&
                          entry.onMarkRead != null)
                        TextButton(
                          onPressed: entry.onMarkRead,
                          child: const Text('标为已读'),
                        ),
                    ],
                  ),
                if (!entry.invalidated)
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: <Widget>[
                      for (final NotificationEntryAction action
                          in entry.actions)
                        if (action.available)
                          OutlinedButton(
                            key: NotificationCenter.actionKey(
                              entry.id,
                              action.id,
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: action.onPressed,
                            child: Text(action.label),
                          ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
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
