import 'package:bb_client/app.dart';
import 'package:bb_client/ui/updates/update_link_opener.dart';
import 'package:bb_client/ui/updates/update_scope.dart';
import 'package:bb_client/ui/updates/update_settings_host.dart';
import 'package:bb_client/ui/updates/update_settings_page.dart';
import 'package:bb_client/updates/android_update_installer.dart';
import 'package:bb_client/updates/update_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_update_controller.dart';

class _FakeLinkOpener implements ExternalLinkOpener {
  final List<Uri> opened = <Uri>[];
  bool result = true;

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return result;
  }
}

void main() {
  late InstallSafetyGate gate;
  late FakeUpdateController controller;
  late _FakeLinkOpener opener;

  setUp(() {
    gate = InstallSafetyGate();
    controller = FakeUpdateController(safetyGate: gate);
    opener = _FakeLinkOpener();
  });

  Future<void> pumpHost(
    WidgetTester tester, {
    AndroidInstallRecovery? recovery,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: UpdateSettingsHost(
          controller: controller,
          recovery: recovery,
          linkOpener: opener,
        ),
      ),
    );
    await tester.pump();
  }

  UpdateSnapshot snapshot(
    UpdatePhase phase, {
    UpdateRelease? release,
    String? message,
    int received = 0,
    int total = 0,
    String? installed = '0.0.1+2',
  }) {
    return UpdateSnapshot(
      phase: phase,
      release: release,
      message: message,
      receivedBytes: received,
      totalBytes: total,
      installedVersion: installed,
    );
  }

  testWidgets('启动检查只在进程根触发一次，重建不重复检查', (WidgetTester tester) async {
    await tester.pumpWidget(
      UpdateScope(
        controller: controller,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();
    expect(controller.checkOnceCalls, 1);

    await tester.pumpWidget(
      UpdateScope(
        controller: controller,
        child: const MaterialApp(home: Text('rebuilt')),
      ),
    );
    await tester.pump();
    expect(controller.checkOnceCalls, 1);
    expect(find.text('rebuilt'), findsOneWidget);
  });

  testWidgets('下载与安装是两个显式动作，状态由契约快照映射', (WidgetTester tester) async {
    final UpdateRelease release = fakeRelease(body: '## 更新内容\n- 自动检查\n');
    controller.emit(snapshot(UpdatePhase.available, release: release));
    await pumpHost(tester);

    expect(find.text('发现新版本 0.1.0+3'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.installButtonKey), findsNothing);
    await tester.tap(find.byKey(UpdateSettingsPage.downloadButtonKey));
    expect(controller.downloadCalls, 1);

    controller.emit(
      snapshot(
        UpdatePhase.downloading,
        release: release,
        received: 512,
        total: 1024,
      ),
    );
    await tester.pump();
    expect(find.byKey(UpdateSettingsPage.progressKey), findsOneWidget);

    controller.emit(
      snapshot(
        UpdatePhase.ready,
        release: release,
        received: 1024,
        total: 1024,
      ),
    );
    await tester.pump();
    expect(find.byKey(UpdateSettingsPage.readyKey), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.installButtonKey));
    expect(controller.installCalls, 1);
  });

  testWidgets('手动重试：检查失败重试检查，下载失败重试下载', (WidgetTester tester) async {
    controller.emit(snapshot(UpdatePhase.failed, message: '无法连接更新服务器'));
    await pumpHost(tester);
    expect(find.text('无法连接更新服务器'), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.retryButtonKey));
    expect(controller.checkCalls, 1);
    expect(controller.downloadCalls, 0);

    controller = FakeUpdateController(safetyGate: gate);
    controller.emit(
      snapshot(
        UpdatePhase.failed,
        release: fakeRelease(),
        message: '安装包 SHA-256 校验失败',
      ),
    );
    await pumpHost(tester);
    await tester.tap(find.byKey(UpdateSettingsPage.retryButtonKey));
    expect(controller.downloadCalls, 1);
  });

  testWidgets('取消下载调用契约 cancel，而不是删除已固定版本', (WidgetTester tester) async {
    controller.emit(
      snapshot(
        UpdatePhase.downloading,
        release: fakeRelease(),
        received: 1,
        total: 2,
      ),
    );
    await pumpHost(tester);
    await tester.tap(find.byKey(UpdateSettingsPage.cancelButtonKey));
    expect(controller.cancelCalls, 1);
  });

  testWidgets('安全门有未处理草稿时不提供安装入口', (WidgetTester tester) async {
    final Object draftOwner = Object();
    gate.setBlocker(draftOwner, '聊天草稿尚未处理：未发送的文字。发送或清空后再安装更新。');
    controller.emit(snapshot(UpdatePhase.ready, release: fakeRelease()));
    await pumpHost(tester);

    expect(find.byKey(UpdateSettingsPage.blockedKey), findsOneWidget);
    expect(find.textContaining('聊天草稿尚未处理'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.installButtonKey), findsNothing);

    gate.setBlocker(draftOwner, null);
    await tester.pump();
    expect(find.byKey(UpdateSettingsPage.blockedKey), findsNothing);
    expect(find.byKey(UpdateSettingsPage.installButtonKey), findsOneWidget);
  });

  testWidgets('安装权限阶段提供授权引导与显式重试', (WidgetTester tester) async {
    controller.emit(
      snapshot(UpdatePhase.permissionRequired, release: fakeRelease()),
    );
    await pumpHost(tester);

    expect(find.text('需要允许 BB 安装应用'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.permissionButtonKey), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.installButtonKey));
    expect(controller.installCalls, 1);
  });

  testWidgets('跨进程恢复通知覆盖 idle，用户动作后恢复普通状态', (WidgetTester tester) async {
    const AndroidInstallRecovery installed = AndroidInstallRecovery(
      outcome: AndroidInstallRecoveryOutcome.installed,
      targetVersion: '0.1.0',
      installedVersion: '0.1.0',
      installedBuildNumber: 3,
    );
    await pumpHost(tester, recovery: installed);

    expect(find.byKey(UpdateSettingsPage.installedKey), findsOneWidget);
    expect(find.textContaining('0.1.0'), findsWidgets);

    // The notice offers an explicit re-check; that user action supersedes it.
    await tester.tap(find.byKey(UpdateSettingsPage.checkButtonKey));
    expect(controller.checkCalls, 1);
    controller.emit(snapshot(UpdatePhase.current));
    await tester.pump();
    expect(find.byKey(UpdateSettingsPage.upToDateKey), findsOneWidget);
  });

  testWidgets('恢复发现安装未完成时明确提示并允许重试检查', (WidgetTester tester) async {
    const AndroidInstallRecovery pending = AndroidInstallRecovery(
      outcome: AndroidInstallRecoveryOutcome.notInstalled,
      targetVersion: '0.1.0',
      installedVersion: '0.0.1',
      installedBuildNumber: 2,
    );
    await pumpHost(tester, recovery: pending);

    expect(find.byKey(UpdateSettingsPage.errorKey), findsOneWidget);
    expect(find.textContaining('未完成'), findsWidgets);
    await tester.tap(find.byKey(UpdateSettingsPage.retryButtonKey));
    expect(controller.checkCalls, 1);
  });

  testWidgets('Release 正文链接需要用户点击并确认后才显式打开', (WidgetTester tester) async {
    controller.emit(
      snapshot(
        UpdatePhase.available,
        release: fakeRelease(
          body: '详见 [发布说明](https://github.com/iiishop/BB/releases)。',
        ),
      ),
    );
    await pumpHost(tester);

    // A tap opens a confirmation dialog; nothing is launched before confirming.
    await tester.tap(find.textContaining('发布说明'));
    await tester.pumpAndSettle();
    expect(find.text('在浏览器中打开链接？'), findsOneWidget);
    expect(opener.opened, isEmpty);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(opener.opened, isEmpty);

    await tester.tap(find.textContaining('发布说明'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      opener.opened.single.toString(),
      'https://github.com/iiishop/BB/releases',
    );
  });

  testWidgets('不支持应用的平台只显示说明页，不构造更新器', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const UpdateSettingsHost.unsupported(),
      ),
    );
    expect(find.byKey(UpdateSettingsPage.unsupportedKey), findsOneWidget);

    // On this Linux test host, UpdateScope constructs no updater either.
    await tester.pumpWidget(
      UpdateScope(
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (BuildContext context) {
              final UpdateScopeData? data = UpdateScope.maybeOf(context);
              return Text('controller=${data?.controller == null}');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('controller=true'), findsOneWidget);
  });
}
