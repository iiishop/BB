import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

/// DEA-477: Enter sends, Ctrl+Enter inserts a newline, the IME keeps its own
/// Enter, and the old dedicated paste button is gone.
Future<FakeChatService> _pumpComposer(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeChatService chat = FakeChatService(
    self: _self,
    users: const <ChatUser>[],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatComposer(
          chat: chat,
          peerAccount: _peer,
          onSent: (List<ChatMessage> _, Map<String, Uint8List> _) {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(ChatComposer.inputKey));
  await tester.pump();
  return chat;
}

String _inputText(WidgetTester tester) {
  final TextField field = tester.widget<TextField>(
    find.byKey(ChatComposer.inputKey),
  );
  return field.controller!.text;
}

void main() {
  testWidgets('Enter sends exactly once and clears the input', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = await _pumpComposer(tester);
    await tester.enterText(find.byKey(ChatComposer.inputKey), '你好');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chat.sendCalls, 1);
    expect(chat.sentTexts, <String>['你好']);
    expect(_inputText(tester), isEmpty);

    // A second Enter with no draft content must not submit again.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chat.sendCalls, 1);
  });

  testWidgets('Ctrl+Enter inserts a newline instead of sending', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = await _pumpComposer(tester);
    await tester.enterText(find.byKey(ChatComposer.inputKey), '第一行');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(chat.sendCalls, 0);
    expect(_inputText(tester), '第一行\n');
  });

  testWidgets('Enter does not send while the IME is composing', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = await _pumpComposer(tester);
    await tester.showKeyboard(find.byKey(ChatComposer.inputKey));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chat.sendCalls, 0);
  });

  testWidgets('Enter never sends an empty or whitespace-only draft', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = await _pumpComposer(tester);
    await tester.enterText(find.byKey(ChatComposer.inputKey), '   ');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chat.sendCalls, 0);
  });

  testWidgets('holding Enter does not submit a second message', (
    WidgetTester tester,
  ) async {
    final FakeChatService chat = await _pumpComposer(tester);
    await tester.enterText(find.byKey(ChatComposer.inputKey), '长按一次');
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(chat.sendCalls, 1);
    expect(chat.sentTexts, <String>['长按一次']);
  });

  testWidgets('the dedicated paste-media button is gone', (
    WidgetTester tester,
  ) async {
    await _pumpComposer(tester);

    expect(find.byTooltip('粘贴图片或视频'), findsNothing);
    expect(find.byIcon(Icons.content_paste_rounded), findsNothing);
    // The image/file entries live behind the round "+" now.
    expect(find.byKey(ChatComposer.attachMenuKey), findsOneWidget);
    await tester.tap(find.byKey(ChatComposer.attachMenuKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ChatComposer.imageKey), findsOneWidget);
    expect(find.byKey(ChatComposer.fileKey), findsOneWidget);
  });
}
