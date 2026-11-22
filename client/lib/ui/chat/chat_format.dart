import 'package:flutter/material.dart';

// The shared photo viewer needs the same byte formatting; one implementation
// lives in ui/media and is re-exported here so existing imports keep working.
export '../media/photo_format.dart' show formatBytes;

/// Human-facing date/time formatting for the chat surface.
String formatContactTime(DateTime? time, {DateTime? now}) {
  if (time == null) {
    return '尚未联系';
  }
  final DateTime current = (now ?? DateTime.now()).toLocal();
  final DateTime local = time.toLocal();
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
    return '${local.month}月${local.day}日';
  }
  return '${local.year}年${local.month}月${local.day}日';
}

String formatClockTime(DateTime time) {
  final DateTime local = time.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

/// Day separator label used between message groups.
String formatDaySeparator(DateTime time, {DateTime? now}) {
  final DateTime current = (now ?? DateTime.now()).toLocal();
  final DateTime local = time.toLocal();
  if (current.year == local.year &&
      current.month == local.month &&
      current.day == local.day) {
    return '今天';
  }
  final DateTime yesterday = current.subtract(const Duration(days: 1));
  if (yesterday.year == local.year &&
      yesterday.month == local.month &&
      yesterday.day == local.day) {
    return '昨天';
  }
  if (current.year == local.year) {
    return '${local.month}月${local.day}日';
  }
  return '${local.year}年${local.month}月${local.day}日';
}

bool shouldShowDaySeparator(DateTime? previous, DateTime current) {
  if (previous == null) {
    return true;
  }
  final DateTime a = previous.toLocal();
  final DateTime b = current.toLocal();
  return a.year != b.year || a.month != b.month || a.day != b.day;
}

/// A run is a set of consecutive bubbles from one sender inside this window.
/// It drives avatar grouping and the 12px/3px vertical rhythm; it is a
/// presentation rule only, never a message fact.
const Duration chatMessageRunWindow = Duration(minutes: 5);

bool shouldShowGapLabel(DateTime? previous, DateTime current) {
  if (previous == null) {
    return false;
  }
  return current.difference(previous).abs() >= chatMessageRunWindow;
}

/// Whether [current] continues the run opened by [previous].
bool continuesMessageRun(
  String? previousSender,
  DateTime? previousTime,
  String sender,
  DateTime current,
) {
  if (previousSender == null || previousTime == null) {
    return false;
  }
  if (previousSender != sender) {
    return false;
  }
  final DateTime a = previousTime.toLocal();
  final DateTime b = current.toLocal();
  if (a.year != b.year || a.month != b.month || a.day != b.day) {
    return false;
  }
  return current.difference(previousTime).abs() < chatMessageRunWindow;
}

String initialsOf(String username) {
  final String trimmed = username.trim();
  if (trimmed.isEmpty) {
    return '?';
  }
  final List<int> runes = trimmed.runes.toList();
  return String.fromCharCode(runes.first);
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Unread badge label: nothing at zero, the exact count 1–99, capped at 99+.
///
/// The count itself is the server-derived incoming unread; only this display
/// label is bounded so a wide row never grows.
String? unreadBadgeLabel(int count) {
  if (count <= 0) {
    return null;
  }
  return count > 99 ? '99+' : '$count';
}

/// Shared color hint for attachment icons.
Color attachmentColor(String mimeType) {
  if (mimeType.startsWith('image/')) {
    return const Color(0xFF0E6F68);
  }
  if (mimeType.startsWith('video/')) {
    return const Color(0xFF7A4E9E);
  }
  if (mimeType.startsWith('audio/')) {
    return const Color(0xFF9E6A4E);
  }
  if (mimeType == 'application/pdf') {
    return const Color(0xFFB3261E);
  }
  return const Color(0xFF5C6A6B);
}

IconData attachmentIcon(String mimeType) {
  if (mimeType.startsWith('image/')) {
    return Icons.image_outlined;
  }
  if (mimeType.startsWith('video/')) {
    return Icons.videocam_outlined;
  }
  if (mimeType.startsWith('audio/')) {
    return Icons.audiotrack_outlined;
  }
  if (mimeType == 'application/pdf') {
    return Icons.picture_as_pdf_outlined;
  }
  return Icons.insert_drive_file_outlined;
}
