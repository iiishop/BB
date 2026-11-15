import 'package:bb_client/app.dart';
import 'package:bb_client/ui/updates/update_settings_page.dart';
import 'package:bb_client/ui/updates/update_ui_state.dart';
import 'package:bb_client/updates/android_update_installer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester,
    UpdateUiState state, {
    VoidCallback? onCheck,
    VoidCallback? onDownload,
    VoidCallback? onCancelDownload,
    VoidCallback? onRetry,
    VoidCallback? onOpenInstallPermissionSettings,
    VoidCallback? onResumeSystemInstaller,
    VoidCallback? onReviewPendingWork,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: UpdateSettingsPage(
          state: state,
          onCheck: onCheck,
          onDownload: onDownload,
          onCancelDownload: onCancelDownload,
          onRetry: onRetry,
          onOpenInstallPermissionSettings: onOpenInstallPermissionSettings,
          onResumeSystemInstaller: onResumeSystemInstaller,
          onReviewPendingWork: onReviewPendingWork,
        ),
      ),
    );
  }

  testWidgets('空闲态提供手动检查，点击触发回调', (WidgetTester tester) async {
    int checks = 0;
    await pumpPage(
      tester,
      const UpdateUiState(currentVersion: '0.0.1+2'),
      onCheck: () => checks += 1,
    );

    expect(find.textContaining('0.0.1+2'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.checkButtonKey));
    expect(checks, 1);
  });

  testWidgets('检查中不显示可重复点击的检查按钮', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.checking,
      ),
      onCheck: () {},
    );

    expect(find.text('正在检查更新…'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.checkButtonKey), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('已是最新版本不提供下载按钮', (WidgetTester tester) async {
    int checks = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.upToDate,
      ),
      onCheck: () => checks += 1,
    );

    expect(find.byKey(UpdateSettingsPage.upToDateKey), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.downloadButtonKey), findsNothing);
    await tester.tap(find.byKey(UpdateSettingsPage.checkButtonKey));
    expect(checks, 1);
  });

  testWidgets('有新版本时显示版本号、原始正文和下载安装按钮', (WidgetTester tester) async {
    int downloads = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.available,
        latestVersion: '0.1.0+3',
        releaseNotes: '## 更新内容\n- 新增自更新\n',
      ),
      onDownload: () => downloads += 1,
    );

    expect(find.byKey(UpdateSettingsPage.latestVersionKey), findsOneWidget);
    expect(find.textContaining('0.1.0+3'), findsOneWidget);
    expect(find.text('更新内容'), findsOneWidget);
    expect(find.textContaining('新增自更新'), findsWidgets);
    await tester.tap(find.byKey(UpdateSettingsPage.downloadButtonKey));
    expect(downloads, 1);
  });

  testWidgets('空 Release 正文显示占位而不是空白卡片', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.available,
        latestVersion: '0.1.0+3',
        releaseNotes: '',
      ),
      onDownload: () {},
    );

    expect(find.text('此版本未提供更新说明'), findsOneWidget);
  });

  testWidgets('下载中显示进度、字节数与取消入口', (WidgetTester tester) async {
    int cancels = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.downloading,
        latestVersion: '0.1.0+3',
        receivedBytes: 1024 * 1024,
        totalBytes: 4 * 1024 * 1024,
      ),
      onCancelDownload: () => cancels += 1,
    );

    final LinearProgressIndicator progress = tester.widget(
      find.byKey(UpdateSettingsPage.progressKey),
    );
    expect(progress.value, closeTo(0.25, 0.0001));
    expect(find.textContaining('1.0 MB / 4.0 MB'), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.cancelButtonKey));
    expect(cancels, 1);
    // One update at a time: a second download cannot be started here.
    expect(find.byKey(UpdateSettingsPage.downloadButtonKey), findsNothing);
  });

  testWidgets('总大小未知时显示不确定进度但不显示假百分比', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.downloading,
        latestVersion: '0.1.0+3',
        receivedBytes: 2048,
      ),
      onCancelDownload: () {},
    );

    final LinearProgressIndicator progress = tester.widget(
      find.byKey(UpdateSettingsPage.progressKey),
    );
    expect(progress.value, isNull);
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  testWidgets('校验阶段不提前打开安装界面', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.verifying,
        latestVersion: '0.1.0+3',
      ),
      onDownload: () {},
    );

    expect(find.text('正在校验下载完整性…'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.downloadButtonKey), findsNothing);
    expect(find.byKey(UpdateSettingsPage.permissionButtonKey), findsNothing);
  });

  testWidgets('Android 缺少安装未知应用权限时给出授权引导', (WidgetTester tester) async {
    int opened = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.permissionRequired,
        latestVersion: '0.1.0+3',
      ),
      onOpenInstallPermissionSettings: () => opened += 1,
    );

    expect(find.textContaining('安装未知应用'), findsWidgets);
    await tester.tap(find.byKey(UpdateSettingsPage.permissionButtonKey));
    expect(opened, 1);
  });

  testWidgets('等待系统安装时可重新打开安装界面，且不承诺静默安装', (WidgetTester tester) async {
    int resumed = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.installing,
        latestVersion: '0.1.0+3',
      ),
      onResumeSystemInstaller: () => resumed += 1,
    );

    expect(find.text('等待系统安装确认'), findsOneWidget);
    expect(find.textContaining('不会静默安装'), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.resumeInstallerButtonKey));
    expect(resumed, 1);
  });

  testWidgets('安装完成展示新版本', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.installed,
        latestVersion: '0.1.0+3',
      ),
    );

    expect(find.byKey(UpdateSettingsPage.installedKey), findsOneWidget);
    expect(find.textContaining('0.1.0+3'), findsOneWidget);
  });

  testWidgets('失败时显示原因并可重试；不可重试时不显示按钮', (WidgetTester tester) async {
    int retries = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.failed,
        errorMessage: '校验和不匹配，已停止安装。',
      ),
      onRetry: () => retries += 1,
    );
    expect(find.byKey(UpdateSettingsPage.errorKey), findsOneWidget);
    expect(find.text('校验和不匹配，已停止安装。'), findsOneWidget);
    await tester.tap(find.byKey(UpdateSettingsPage.retryButtonKey));
    expect(retries, 1);

    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.failed,
        errorMessage: '当前平台不支持。',
        canRetry: false,
      ),
    );
    expect(find.byKey(UpdateSettingsPage.retryButtonKey), findsNothing);
  });

  testWidgets('草稿/在途操作未处理时阻止安装并给出处理入口', (WidgetTester tester) async {
    int reviewed = 0;
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.blocked,
        latestVersion: '0.1.0+3',
        blockedReason: '有 1 条消息正在发送、1 份上传未完成。',
      ),
      onReviewPendingWork: () => reviewed += 1,
    );

    expect(find.byKey(UpdateSettingsPage.blockedKey), findsOneWidget);
    expect(find.text('有 1 条消息正在发送、1 份上传未完成。'), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.downloadButtonKey), findsNothing);
    expect(find.byKey(UpdateSettingsPage.permissionButtonKey), findsNothing);
    await tester.tap(find.byKey(UpdateSettingsPage.reviewPendingButtonKey));
    expect(reviewed, 1);
  });

  testWidgets('非首批平台明确说明不支持应用内更新', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.unsupported,
      ),
    );

    expect(find.byKey(UpdateSettingsPage.unsupportedKey), findsOneWidget);
    expect(find.byKey(UpdateSettingsPage.downloadButtonKey), findsNothing);
  });

  testWidgets('桌面宽度下页面内容保持可读的最大宽度', (WidgetTester tester) async {
    await pumpPage(
      tester,
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.available,
        latestVersion: '0.1.0+3',
        releaseNotes: '## 更新内容\n- 新增自更新\n',
      ),
      onDownload: () {},
      size: const Size(1440, 900),
    );

    expect(tester.takeException(), isNull);
    final double width = tester.getSize(find.byType(ListView)).width;
    expect(width, lessThanOrEqualTo(680));
  });

  testWidgets('每个安装拒绝原因都有针对性的用户文案', (WidgetTester tester) async {
    final Set<String> messages = <String>{};
    for (final ApkInstallRejection rejection in ApkInstallRejection.values) {
      final String message = apkInstallRejectionMessage(rejection);
      expect(message, isNotEmpty, reason: rejection.code);
      messages.add(message);
    }
    expect(
      messages.length,
      ApkInstallRejection.values.length,
      reason: '不同拒绝原因不应共用同一句模糊文案',
    );
  });
}
