import 'dart:io';
import 'dart:convert';

import 'package:bb_client/updates/android_update_installer.dart';
import 'package:bb_client/updates/update_contract.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    AndroidUpdateInstaller.channelName,
  );
  final List<MethodCall> calls = <MethodCall>[];
  late Directory cache;

  Map<String, Object?> availability({
    String version = '0.0.1',
    int build = 2,
    List<String> abis = const <String>['arm64-v8a', 'armeabi-v7a'],
    String status = 'ready',
  }) {
    return <String, Object?>{
      'status': status,
      'package_name': 'ai.bb.bb_mobile',
      'version_code': build,
      'version_name': version,
      'supported_abis': abis,
    };
  }

  void mock(Future<Object?> Function(MethodCall call) handler) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return handler(call);
        });
  }

  AndroidUpdateInstaller installer({
    TargetPlatform platform = TargetPlatform.android,
  }) {
    return AndroidUpdateInstaller(
      channel: channel,
      platform: platform,
      cacheDirectory: cache,
    );
  }

  Future<VerifiedUpdate> stagedUpdate({String content = 'apk-bytes'}) async {
    final File file = File('${cache.path}${Platform.pathSeparator}staged.apk');
    await file.writeAsString(content);
    final String digest = (await sha256.bind(file.openRead()).first).toString();
    final UpdateRelease base = UpdateRelease(
      id: 1,
      tag: 'v0.1.0',
      version: '0.1.0',
      body: 'notes',
      htmlUrl: Uri.parse('https://github.com/iiishop/BB/releases/tag/v0.1.0'),
      asset: UpdateAsset(
        id: 11,
        name: 'bb-0.1.0-android-arm64-v8a.apk',
        url: Uri.parse('https://github.com/iiishop/BB/releases/download/x.apk'),
        size: content.length,
      ),
      checksums: UpdateAsset(
        id: 12,
        name: 'SHA256SUMS',
        url: Uri.parse(
          'https://github.com/iiishop/BB/releases/download/SHA256SUMS',
        ),
        size: 10,
      ),
    );
    return VerifiedUpdate(release: base, file: file, sha256: digest);
  }

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('bb-update-adapter-');
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await cache.exists()) {
      await cache.delete(recursive: true);
    }
  });

  test('recovery never deletes files outside its staging directory', () async {
    final outside = await Directory.systemTemp.createTemp('bb-user-data-');
    addTearDown(() => outside.delete(recursive: true));
    final userFile = File('${outside.path}/session.json');
    await userFile.writeAsString('user data');
    await File('${cache.path}/${AndroidUpdateInstaller.markerFileName}')
        .writeAsString(
          jsonEncode({'target_version': '0.1.0', 'file': userFile.path}),
        );
    mock((call) async => availability(version: '0.1.0', build: 3));
    await installer().recoverPendingInstall();
    expect(await userFile.exists(), isTrue);
  });

  test('platformInfo 使用实际安装版本与首个受支持 ABI', () async {
    mock((MethodCall call) async => availability());
    final UpdatePlatformInfo info = await installer().platformInfo();

    expect(info.os, 'android');
    expect(info.version, '0.0.1');
    expect(info.buildNumber, 2);
    expect(info.architecture, 'arm64-v8a');
  });

  test('platformInfo 拒绝未知 ABI 与不可读版本，不伪造可更新', () async {
    mock((MethodCall call) async => availability(abis: <String>['mips']));
    await expectLater(
      installer().platformInfo(),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('CPU 架构'),
        ),
      ),
    );

    mock((MethodCall call) async => <String, Object?>{'status': 'unknown'});
    await expectLater(installer().platformInfo(), throwsA(isA<StateError>()));
  });

  test('install 在启动系统安装器前重算哈希，篡改后拒绝且不启动', () async {
    final VerifiedUpdate update = await stagedUpdate();
    mock((MethodCall call) async => <String, Object?>{'status': 'launched'});
    await update.file.writeAsString('apk-bytez');

    await expectLater(
      installer().install(update),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('校验'),
        ),
      ),
    );
    expect(calls, isEmpty);
  });

  test('install 记录事务并把 launched 映射为 installerOpened', () async {
    final VerifiedUpdate update = await stagedUpdate();
    mock((MethodCall call) async {
      if (call.method == 'installApk') {
        return <String, Object?>{'status': 'launched'};
      }
      return availability();
    });

    final UpdateInstallResult result = await installer().install(update);

    expect(result, UpdateInstallResult.installerOpened);
    expect(calls.single.method, 'installApk');
    final File marker = File(
      '${cache.path}${Platform.pathSeparator}'
      '${AndroidUpdateInstaller.markerFileName}',
    );
    expect(await marker.exists(), isTrue);
    expect(await marker.readAsString(), contains('0.1.0'));
  });

  test('缺少未知来源安装权限时返回 permissionRequired 且不留事务', () async {
    final VerifiedUpdate update = await stagedUpdate();
    mock(
      (MethodCall call) async => <String, Object?>{
        'status': 'permissionRequired',
        'reason': 'unknown_sources_disabled',
      },
    );

    final UpdateInstallResult result = await installer().install(update);

    expect(result, UpdateInstallResult.permissionRequired);
    expect(
      await File(
        '${cache.path}${Platform.pathSeparator}'
        '${AndroidUpdateInstaller.markerFileName}',
      ).exists(),
      isFalse,
    );
  });

  test('安装前校验被原生拒绝时抛出可读错误且不留事务', () async {
    final VerifiedUpdate update = await stagedUpdate();
    mock(
      (MethodCall call) async => <String, Object?>{
        'status': 'rejected',
        'reason': 'signer_mismatch',
      },
    );

    await expectLater(
      installer().install(update),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('签名'),
        ),
      ),
    );
    expect(
      await File(
        '${cache.path}${Platform.pathSeparator}'
        '${AndroidUpdateInstaller.markerFileName}',
      ).exists(),
      isFalse,
    );
  });

  test('跨进程恢复：安装后的版本满足目标时报 installed 并清理事务与暂存包', () async {
    final VerifiedUpdate update = await stagedUpdate();
    mock((MethodCall call) async => <String, Object?>{'status': 'launched'});
    await installer().install(update);
    final File staged = update.file;
    expect(await staged.exists(), isTrue);

    // New process: same cache directory, new installer instance, installed
    // version now equal to the target.
    mock((MethodCall call) async => availability(version: '0.1.0', build: 3));
    final AndroidInstallRecovery? recovery = await installer()
        .recoverPendingInstall();

    expect(recovery?.outcome, AndroidInstallRecoveryOutcome.installed);
    expect(recovery?.installedVersion, '0.1.0');
    expect(await staged.exists(), isFalse);
    expect(
      await File(
        '${cache.path}${Platform.pathSeparator}'
        '${AndroidUpdateInstaller.markerFileName}',
      ).exists(),
      isFalse,
    );
  });

  test('跨进程恢复：版本未变时报 notInstalled，不假装更新成功', () async {
    final VerifiedUpdate update = await stagedUpdate();
    mock((MethodCall call) async => <String, Object?>{'status': 'launched'});
    await installer().install(update);

    mock((MethodCall call) async => availability(version: '0.0.1', build: 2));
    final AndroidInstallRecovery? recovery = await installer()
        .recoverPendingInstall();

    expect(recovery?.outcome, AndroidInstallRecoveryOutcome.notInstalled);
    expect(recovery?.targetVersion, '0.1.0');
  });

  test('无事务时恢复返回 null；取消事件清除未完成事务', () async {
    mock((MethodCall call) async => availability());
    expect(await installer().recoverPendingInstall(), isNull);

    // A previously recorded transaction (simulated directly) is cleared when
    // the system installer reports a cancel while the process still lives.
    final Directory directory = cache;
    await directory.create(recursive: true);
    final File marker = File(
      '${cache.path}${Platform.pathSeparator}'
      '${AndroidUpdateInstaller.markerFileName}',
    );
    await marker.writeAsString('{"target_version":"0.1.0"}');

    final AndroidUpdateInstaller instance = installer();
    await instance.availability(); // attach native -> Dart handler
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AndroidUpdateInstaller.channelName,
          channel.codec.encodeMethodCall(
            const MethodCall(
              AndroidUpdateInstaller.eventMethod,
              <String, Object?>{'type': 'installResult', 'status': 'cancelled'},
            ),
          ),
          (ByteData? data) {},
        );
    await Future<void>.delayed(Duration.zero);
    expect(await marker.exists(), isFalse);
    await instance.dispose();
  });

  test('显式打开链接只接受 https，其他协议不触达原生', () async {
    mock((MethodCall call) async => true);
    final AndroidUpdateInstaller instance = installer();

    expect(
      await instance.openExternalUrl('https://github.com/iiishop/BB/releases'),
      isTrue,
    );
    expect(calls.single.method, 'openExternalUrl');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['url'],
      'https://github.com/iiishop/BB/releases',
    );

    calls.clear();
    expect(await instance.openExternalUrl('javascript:alert(1)'), isFalse);
    expect(await instance.openExternalUrl('http://example.com'), isFalse);
    expect(
      await instance.openExternalUrl('https://user:pw@example.com'),
      isFalse,
    );
    expect(calls, isEmpty);
    await instance.dispose();
  });
}
