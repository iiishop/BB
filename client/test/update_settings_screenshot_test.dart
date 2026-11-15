import 'dart:io';

import 'package:bb_client/app.dart';
import 'package:bb_client/ui/updates/update_settings_page.dart';
import 'package:bb_client/ui/updates/update_ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the DEA-479 update settings surface to PNG evidence.
///
/// Opt-in because it writes files:
/// `QA_UPDATE_SCREENSHOT_DIR=.qa-artifacts/update-ui \
///  QA_CJK_FONT=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
///  QA_ICON_FONT=$FLUTTER_ROOT/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
///  QA_MONO_FONT=/usr/share/fonts/noto/NotoSansMono-Regular.ttf \
///  flutter test test/update_settings_screenshot_test.dart --update-goldens`
///
/// These are widget-test renders on the Linux host, not Android/Windows device
/// screenshots; they do not prove device behaviour.
void main() {
  final String? outputDir = Platform.environment['QA_UPDATE_SCREENSHOT_DIR'];
  final String? fontPath = Platform.environment['QA_CJK_FONT'];
  final String? iconFontPath = Platform.environment['QA_ICON_FONT'];
  final String? monoFontPath = Platform.environment['QA_MONO_FONT'];
  final String? skipReason = outputDir == null
      ? 'QA_UPDATE_SCREENSHOT_DIR 未设置：本次未生成截图'
      : null;

  testWidgets('capture update settings states (opt-in evidence)', (
    WidgetTester tester,
  ) async {
    final Directory directory = Directory(outputDir!);
    directory.createSync(recursive: true);
    if (fontPath != null && File(fontPath).existsSync()) {
      final Uint8List bytes = File(fontPath).readAsBytesSync();
      await tester.runAsync(() async {
        for (final String family in <String>['Roboto', 'Ahem']) {
          await (FontLoader(family)
                ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer))))
              .load();
        }
      });
    }
    if (monoFontPath != null && File(monoFontPath).existsSync()) {
      final Uint8List bytes = File(monoFontPath).readAsBytesSync();
      await tester.runAsync(() async {
        await (FontLoader(
          'monospace',
        )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
      });
    }
    if (iconFontPath != null && File(iconFontPath).existsSync()) {
      final Uint8List bytes = File(iconFontPath).readAsBytesSync();
      await tester.runAsync(() async {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)))).load();
      });
    }

    const String releaseNotes =
        '## 本次更新\n'
        '- 启动后自动检查新版本，也可以手动检查\n'
        '- 下载完成后校验 SHA-256 再安装\n'
        '- 修复：**中文路径** 下的更新失败\n\n'
        '> 更新不会清除账号、服务器设置和聊天记录。\n\n'
        '详见 [发布说明](https://github.com/iiishop/BB/releases)。\n\n'
        '```text\n'
        'bb-0.1.0-android-arm64-v8a.apk\n'
        '```\n';

    Future<void> pump(
      UpdateUiState state,
      Size size, {
      VoidCallback? onCheck,
      VoidCallback? onDownloadAndInstall,
      VoidCallback? onCancelDownload,
      VoidCallback? onRetry,
      VoidCallback? onOpenInstallPermissionSettings,
      VoidCallback? onResumeSystemInstaller,
      VoidCallback? onReviewPendingWork,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(size: size, textScaler: TextScaler.noScaling),
            child: child!,
          ),
          home: UpdateSettingsPage(
            state: state,
            onCheck: onCheck,
            onDownloadAndInstall: onDownloadAndInstall,
            onCancelDownload: onCancelDownload,
            onRetry: onRetry,
            onOpenInstallPermissionSettings: onOpenInstallPermissionSettings,
            onResumeSystemInstaller: onResumeSystemInstaller,
            onReviewPendingWork: onReviewPendingWork,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
      await expectLater(
        find.byType(UpdateSettingsPage),
        matchesGoldenFile('../$outputDir/$name'),
      );
    }

    const Size phone = Size(390, 844);
    const Size wide = Size(1280, 800);

    await pump(
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.available,
        latestVersion: '0.1.0+3',
        releaseNotes: releaseNotes,
      ),
      phone,
      onCheck: () {},
      onDownloadAndInstall: () {},
    );
    await capture('update-available-phone.png');

    await pump(
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.downloading,
        latestVersion: '0.1.0+3',
        receivedBytes: 6 * 1024 * 1024,
        totalBytes: 21 * 1024 * 1024,
      ),
      phone,
      onCancelDownload: () {},
    );
    await capture('update-downloading-phone.png');

    await pump(
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.permissionRequired,
        latestVersion: '0.1.0+3',
      ),
      phone,
      onOpenInstallPermissionSettings: () {},
    );
    await capture('update-permission-phone.png');

    await pump(
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.failed,
        latestVersion: '0.1.0+3',
        errorMessage: '安装包签名与当前应用不一致，已停止安装。请从官方发布页重新下载。',
      ),
      phone,
      onRetry: () {},
    );
    await capture('update-failed-phone.png');

    await pump(
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.blocked,
        latestVersion: '0.1.0+3',
        blockedReason: '有 1 条消息正在发送、1 份图片上传未完成。',
      ),
      phone,
      onReviewPendingWork: () {},
    );
    await capture('update-blocked-phone.png');

    await pump(
      const UpdateUiState(
        currentVersion: '0.0.1+2',
        phase: UpdateUiPhase.available,
        latestVersion: '0.1.0+3',
        releaseNotes: releaseNotes,
      ),
      wide,
      onCheck: () {},
      onDownloadAndInstall: () {},
    );
    await capture('update-available-wide.png');
  }, skip: skipReason != null);
}
