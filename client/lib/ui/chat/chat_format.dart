import 'package:flutter/material.dart';

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

bool shouldShowGapLabel(DateTime? previous, DateTime current) {
  if (previous == null) {
    return false;
  }
  return current.difference(previous).abs() >= const Duration(minutes: 5);
}

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
