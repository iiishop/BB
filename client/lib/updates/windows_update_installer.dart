import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'update_contract.dart';

class WindowsUpdateInstaller implements UpdateInstaller {
  WindowsUpdateInstaller({Directory? applicationDirectory})
    : applicationDirectory =
          applicationDirectory ?? File(Platform.resolvedExecutable).parent;
  final Directory applicationDirectory;

  @override
  Future<UpdatePlatformInfo> platformInfo() async {
    if (!Platform.isWindows) throw StateError('此更新安装器仅支持 Windows。');
    final json = jsonDecode(
      await File('${applicationDirectory.path}/bb-build.json').readAsString(),
    ) as Map<String, dynamic>;
    return UpdatePlatformInfo(
      os: 'windows',
      architecture: json['architecture'] as String,
      version: json['version'] as String,
      buildNumber: json['buildNumber'] as int,
    );
  }

  @override
  Future<UpdateInstallResult> install(VerifiedUpdate update) async {
    if (!Platform.isWindows) throw StateError('此更新安装器仅支持 Windows。');
    final root = applicationDirectory.absolute;
    if (!await File('${root.path}/bb-payload.sha256').exists()) {
      throw StateError('旧安装缺少载荷清单，请保留旧目录并手动解压完整包。');
    }
    // Keep the running helper outside both directories that it will rename.
    final helper = await File('${root.path}/bb_updater.exe')
        .copy('${update.file.parent.path}/bb_updater.exe');
    final process = await Process.start(
      helper.path,
      ['--apply', root.path, update.file.absolute.path, update.sha256, '$pid'],
      runInShell: false,
      workingDirectory: update.file.parent.path,
    );
    final error = StringBuffer();
    final stderrSubscription = process.stderr.transform(utf8.decoder).listen((
      chunk,
    ) {
      if (error.length < 8192) error.write(chunk);
    });
    final ready = Completer<bool>();
    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line == 'READY' && !ready.isCompleted) ready.complete(true);
          },
          onDone: () {
            if (!ready.isCompleted) ready.complete(false);
          },
        );
    try {
      if (!await ready.future.timeout(const Duration(minutes: 5))) {
        await process.exitCode;
        throw StateError('Windows 更新准备失败：${error.toString().trim()}');
      }
      // All admission checks remain locked until this point. The independent
      // updater holds this exact process handle and waits for its termination.
      exit(0);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      throw StateError('更新准备超时，旧程序仍在运行。请重试或检查恢复日志。');
    } finally {
      await stderrSubscription.cancel();
      await stdoutSubscription.cancel();
    }
  }
}
