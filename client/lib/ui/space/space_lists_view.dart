import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/space_models.dart';
import 'space_controller.dart';
import 'space_detail_controller.dart';
import 'space_format.dart';
import 'space_widgets.dart';

/// Interaction notifications. Opening the list never acknowledges anything;
/// each tap acknowledges the version the person actually saw, and "全部标读"
/// is an explicit separate action.
class SpaceNotificationsView extends StatelessWidget {
  const SpaceNotificationsView({super.key, required this.space});

  final SpaceController space;

  static const Key viewKey = Key('space-notifications-view');
  static const Key ackAllKey = Key('space-notification-ack-all');
  static const Key errorKey = Key('space-notifications-error');
  static const Key moreKey = Key('space-notifications-more');
  static Key rowKey(String id) => Key('space-notification-$id');
  static Key unreadKey(String id) => Key('space-notification-unread-$id');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<SpaceNotification> items = space.notifications;
    return Material(
      key: viewKey,
      color: AppColors.paper,
      child: Column(
        children: <Widget>[
          SpaceSectionHeader(
            title: '互动通知',
            subtitle: '浏览不会通知；自己的互动也不会通知自己。',
            onBack: space.showFeed,
            onRefresh: () => space.loadNotifications(reset: true),
          ),
          if (space.notificationsOffline)
            const SpaceInlineBanner(
              message: '当前离线，通知可能不是最新；这不是“没有通知”。',
              icon: Icons.cloud_off_rounded,
            ),
          if (space.acking) const LinearProgressIndicator(minHeight: 2),
          if (space.unreadNotifications > 0)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: TextButton(
                  key: ackAllKey,
                  onPressed: space.acking ? null : space.ackAllLoaded,
                  child: Text('全部标读（${space.unreadNotifications}）'),
                ),
              ),
            ),
          Expanded(
            child: switch (space.notificationsPhase) {
              SpacePhase.loading when items.isEmpty => const Center(
                child: CircularProgressIndicator(),
              ),
              SpacePhase.error when items.isEmpty => SpaceStateView(
                key: errorKey,
                icon: Icons.error_outline_rounded,
                title: '通知读取失败',
                message: space.notificationsError ?? '请稍后重试',
                actionLabel: '重试',
                onAction: () => space.loadNotifications(reset: true),
              ),
              SpacePhase.empty when items.isEmpty => const SpaceStateView(
                icon: Icons.notifications_none_rounded,
                title: '还没有互动通知',
                message: '别人赞、评论、回复或转发你的说说时会出现在这里。',
              ),
              _ => RefreshIndicator(
                onRefresh: () => space.loadNotifications(reset: true),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.xs,
                    AppSpacing.md,
                    AppSpacing.lg,
                  ),
                  itemCount:
                      items.length + (space.notificationsHasMore ? 1 : 0),
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    if (index == items.length) {
                      return Center(
                        child: TextButton(
                          key: moreKey,
                          onPressed: space.loadMoreNotifications,
                          child: const Text('加载更多通知'),
                        ),
                      );
                    }
                    final SpaceNotification item = items[index];
                    return _NotificationTile(
                      notification: item,
                      onTap: () => space.openNotification(item),
                    );
                  },
                ),
              ),
            },
          ),
          if (space.notificationsError != null && items.isNotEmpty)
            SpaceInlineBanner(
              message: space.notificationsError!,
              tone: AppColors.danger,
              background: AppColors.dangerSurface,
              icon: Icons.error_outline_rounded,
              actionLabel: '重试',
              onAction: () => space.loadNotifications(reset: true),
            ),
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text('已读只表示看过提醒，不代表已经回复。', style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final SpaceNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool unavailable = notification.deleted || !notification.accessible;
    final IconData icon = switch (notification.kind) {
      'like' => Icons.favorite_rounded,
      'comment' => Icons.mode_comment_outlined,
      'reply' => Icons.reply_rounded,
      'repost' => Icons.repeat_rounded,
      _ => Icons.notifications_none_rounded,
    };
    return ListTile(
      key: SpaceNotificationsView.rowKey(notification.notificationId),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      leading: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          CircleAvatar(
            radius: 20,
            backgroundColor: unavailable
                ? AppColors.border
                : AppColors.accentSoft,
            child: Icon(
              icon,
              size: 20,
              color: unavailable ? AppColors.inkMuted : AppColors.accent,
            ),
          ),
          if (notification.unread)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                key: SpaceNotificationsView.unreadKey(
                  notification.notificationId,
                ),
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: AppColors.danger,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
      title: Text(
        notificationTitle(notification),
        style: text.bodyMedium?.copyWith(
          fontWeight: notification.unread ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        unavailable ? '内容已删除' : notificationSnippet(notification),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall,
      ),
      trailing: Text(
        spaceRelativeTime(notification.createdAt),
        style: text.bodySmall?.copyWith(fontSize: 11),
      ),
    );
  }
}

/// Draft box. Entering compose creates the server draft; this list is how a
/// person returns to one without pretending it was published.
class SpaceDraftsView extends StatelessWidget {
  const SpaceDraftsView({
    super.key,
    required this.space,
    required this.onOpenDraft,
  });

  final SpaceController space;
  final void Function(SpaceDraft draft) onOpenDraft;

  static const Key viewKey = Key('space-drafts-view');
  static Key rowKey(String id) => Key('space-draft-$id');
  static Key discardKey(String id) => Key('space-draft-discard-$id');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Material(
      key: viewKey,
      color: AppColors.paper,
      child: Column(
        children: <Widget>[
          SpaceSectionHeader(
            title: '草稿',
            subtitle: '草稿只有你自己看得到；发布后不能编辑。',
            onBack: space.showFeed,
            onRefresh: space.loadDrafts,
          ),
          if (space.draftsError != null)
            SpaceInlineBanner(
              message: space.draftsError!,
              tone: AppColors.danger,
              background: AppColors.dangerSurface,
              actionLabel: '重试',
              onAction: space.loadDrafts,
            ),
          Expanded(
            child: space.draftsLoading && space.drafts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : space.drafts.isEmpty
                ? const SpaceStateView(
                    icon: Icons.edit_note_rounded,
                    title: '没有草稿',
                    message: '点“发布”开始写一条，未发布的内容会留在这里。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: space.drafts.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (BuildContext context, int index) {
                      final SpaceDraft draft = space.drafts[index];
                      return Material(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.brand),
                        child: InkWell(
                          key: rowKey(draft.draftId),
                          borderRadius: BorderRadius.circular(AppRadius.brand),
                          onTap: () => onOpenDraft(draft),
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        draftPreview(draft),
                                        style: text.bodyMedium,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '版本 ${draft.version}'
                                        '${draft.images.isEmpty ? '' : ' · ${draft.images.length} 张图片'}',
                                        style: text.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  key: discardKey(draft.draftId),
                                  onPressed: () => space.discardDraft(draft),
                                  tooltip: '丢弃草稿',
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
