import 'package:bb_client/app.dart';
import 'package:bb_client/models/auth_models.dart';
import 'package:bb_client/models/chat_models.dart';
import 'package:bb_client/ui/chat/chat_composer.dart';
import 'package:bb_client/ui/chat/chat_drafts.dart';
import 'package:bb_client/ui/updates/update_settings_host.dart';
import 'package:bb_client/ui/updates/update_settings_page.dart';
import 'package:bb_client/updates/update_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_service.dart';
import 'support/fake_update_controller.dart';

const AuthUser _self = AuthUser(account: '10000001', username: 'alice');
const String _peer = '10000002';

void main() {
  late FakeChatService chat;
  late InstallSafetyGate gate;
  late FakeUpdateController controller;
  late UpdateRelease release;

  setUp(() {
    chat = FakeChatService(self: _self, users: const <ChatUser>[]);
    // The draft store and the update contract use the process-wide gate; the
    // test uses the same instance and clears its chat owner in tearDown.
    gate = InstallSafetyGate.instance;
    ChatDrafts.instance.resetForTest();
    ChatDrafts.instance.clearSession(chat);
    controller = FakeUpdateController(safetyGate: gate);
    release = fakeRelease();
    controller.emit(
      UpdateSnapshot(
        phase: UpdatePhase.ready,
        release: release,
        receivedBytes: 1024,
        totalBytes: 1024,
        installedVersion: '0.0.1+2',
      ),
    );
  });

  tearDown(() {
    ChatDrafts.instance.clearSession(chat);
  });

  Future<void> pumpComposer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ChatComposer(
            chat: chat,
            peerAccount: _peer,
            onSent: (List<ChatMessage> _, Map<String, dynamic> _) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpUpdateHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: UpdateSettingsHost(controller: controller),
      ),
    );
    await tester.pump();
  }

  String inputText(WidgetTester tester) {
    return tester
        .widget<TextField>(find.byKey(ChatComposer.inputKey))
        .controller!
        .text;
  }

  testWidgets('离开聊天页后草稿不丢，更新页仍阻止安装；重新进入聊天恢复草稿', (WidgetTester tester) async {
    await pumpComposer(tester);
    await tester.tap(find.byKey(ChatComposer.inputKey));
    await tester.enterText(find.byKey(ChatComposer.inputKey), '还没发的草稿');
    await tester.pump();

    expect(ChatDrafts.instance.read(chat, _peer)?.text, '还没发的草稿');
    expect(gate.blockers, isNotEmpty);

    // Leaving the chat route disposes the composer; the draft and the gate
    // blocker must survive that.
    await pumpUpdateHost(tester);
    expect(gate.blockers, isNotEmpty);
    expect(find.byKey(UpdateSettingsPage.blockedKey), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.installButtonKey), findsNothing);

    await pumpComposer(tester);
    expect(inputText(tester), '还没发的草稿');
  });

  testWidgets('草稿清空后安全门释放，更新页恢复安装入口', (WidgetTester tester) async {
    await pumpComposer(tester);
    await tester.tap(find.byKey(ChatComposer.inputKey));
    await tester.enterText(find.byKey(ChatComposer.inputKey), '待处理');
    await tester.pump();
    expect(gate.blockers, isNotEmpty);

    await pumpUpdateHost(tester);
    expect(find.byKey(UpdateSettingsPage.blockedKey), findsOneWidget);

    // Explicit clear (send/discard path) is the only thing that releases it.
    ChatDrafts.instance.clear(chat, _peer);
    await tester.pump();
    debugPrint(
      'after clear, blocked key: ${find.byKey(UpdateSettingsPage.blockedKey).evaluate().length}, blockers: ${gate.blockers}',
    );
    await tester.pump();
    debugPrint(
      'after second pump, blocked key: ${find.byKey(UpdateSettingsPage.blockedKey).evaluate().length}',
    );
    expect(gate.blockers, isEmpty);
    expect(find.byKey(UpdateSettingsPage.blockedKey), findsNothing);
    expect(find.byKey(UpdateSettingsPage.installButtonKey), findsOneWidget);
  });

  testWidgets('清空输入框也释放安全门，不留下永久阻塞', (WidgetTester tester) async {
    await pumpComposer(tester);
    await tester.tap(find.byKey(ChatComposer.inputKey));
    await tester.enterText(find.byKey(ChatComposer.inputKey), '临时');
    await tester.pump();
    expect(gate.blockers, isNotEmpty);

    await tester.enterText(find.byKey(ChatComposer.inputKey), '');
    await tester.pump();
    expect(gate.blockers, isEmpty);
  });

  testWidgets('安装事务进行中禁止继续编辑草稿', (WidgetTester tester) async {
    await pumpComposer(tester);
    await tester.tap(find.byKey(ChatComposer.inputKey));
    await tester.enterText(find.byKey(ChatComposer.inputKey), '草稿');
    await tester.pump();
    ChatDrafts.instance.clear(chat, _peer);
    await tester.pump();
    expect(gate.blockers, isEmpty);

    gate.acquire();
    await tester.pump();
    final IgnorePointer guard = tester.widget<IgnorePointer>(
      find.byKey(ChatComposer.safetyGateKey),
    );
    expect(guard.ignoring, isTrue);
    gate.release();
  });
}
