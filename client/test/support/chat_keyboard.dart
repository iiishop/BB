import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Presses Ctrl+V on the currently focused widget.
Future<void> sendPasteShortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Focuses the chat input (like a user clicking it) and presses Ctrl+V.
Future<void> pasteFromClipboard(WidgetTester tester) async {
  await tester.tap(find.byKey(ChatComposer.inputKey));
  await tester.pump();
  await sendPasteShortcut(tester);
}
