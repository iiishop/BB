import '../../models/space_models.dart';

/// Human-facing labels used by the Space surface.
///
/// All strings are UI copy only; the wire contract lives in
/// `server/contract/space-v1.json` and is consumed through `SpaceGateway`.
String spaceRelativeTime(String iso, {DateTime? now}) {
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) {
    return '';
  }
  final DateTime current = (now ?? DateTime.now()).toLocal();
  final DateTime local = parsed.toLocal();
  final Duration delta = current.difference(local);
  if (delta.isNegative || delta.inMinutes < 1) {
    return '刚刚';
  }
  if (delta.inMinutes < 60) {
    return '${delta.inMinutes} 分钟前';
  }
  final bool sameDay =
      current.year == local.year &&
      current.month == local.month &&
      current.day == local.day;
  if (sameDay) {
    return '${_two(local.hour)}:${_two(local.minute)}';
  }
  final DateTime yesterday = current.subtract(const Duration(days: 1));
  if (yesterday.year == local.year &&
      yesterday.month == local.month &&
      yesterday.day == local.day) {
    return '昨天 ${_two(local.hour)}:${_two(local.minute)}';
  }
  if (current.year == local.year) {
    return '${local.month} 月 ${local.day} 日';
  }
  return '${local.year} 年 ${local.month} 月 ${local.day} 日';
}

String spaceExactTime(String iso) {
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) {
    return '';
  }
  final DateTime local = parsed.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// `甲、乙等 3 人赞了你的说说`.
String likeNotificationLabel(SpaceNotification notification) {
  final List<SpaceAuthor> actors = notification.actors;
  final String names = actors
      .take(2)
      .map((SpaceAuthor a) => a.username)
      .join('、');
  final int count = notification.actorCount;
  if (count <= 2 || names.isEmpty) {
    return count <= 1 ? '$names 赞了你的说说' : '$names 赞了你的说说';
  }
  return '$names 等 $count 人赞了你的说说';
}

String notificationTitle(SpaceNotification notification) {
  switch (notification.kind) {
    case 'like':
      return likeNotificationLabel(notification);
    case 'comment':
      final String who = notification.actors.isEmpty
          ? '有人'
          : notification.actors.first.username;
      return '$who 评论了你的说说';
    case 'reply':
      final String who = notification.actors.isEmpty
          ? '有人'
          : notification.actors.first.username;
      return '$who 回复了你的评论';
    case 'repost':
      final String who = notification.actors.isEmpty
          ? '有人'
          : notification.actors.first.username;
      return '$who 转发了你的说说';
    default:
      return '新的互动';
  }
}

/// Live target fragments are resolved by the server; a deleted target never
/// falls back to a cached body.
String notificationSnippet(SpaceNotification notification) {
  if (notification.deleted) {
    return '内容已删除';
  }
  if (notification.snippet == null || notification.snippet!.isEmpty) {
    return '打开查看';
  }
  return notification.snippet!;
}

String draftPreview(SpaceDraft draft) {
  final String text = draft.text.trim();
  if (text.isEmpty) {
    return draft.images.isEmpty ? '空白草稿' : '[图片 ${draft.images.length} 张]';
  }
  return text.length > 80 ? '${text.substring(0, 80)}…' : text;
}

/// The reference card is one level deep by contract; this label states whether
/// the direct source can still be opened.
String referenceStateLabel(SpaceReference reference) {
  if (reference.deleted) {
    return '原说说已被删除';
  }
  if (reference.text != null && reference.text!.isNotEmpty) {
    return reference.text!;
  }
  if (reference.image != null) {
    return '[图片]';
  }
  return '查看原说说';
}
