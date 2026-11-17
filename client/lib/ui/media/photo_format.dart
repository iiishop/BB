/// Byte-size formatting shared by the media surfaces.
///
/// Lives here rather than in `chat/chat_format.dart` so the shared photo viewer
/// and the Space viewer can use it without importing the chat feature;
/// `chat_format.dart` re-exports it, so existing call sites keep working.
library;

/// Same output as the original chat-only helper: bytes, then KB, then MB, each
/// with one decimal and no unit above MB.
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
