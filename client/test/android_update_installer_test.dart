import 'package:bb_client/updates/android_update_installer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    AndroidUpdateInstaller.channelName,
  );
  final List<MethodCall> calls = <MethodCall>[];

  void mock(Future<Object?> Function(MethodCall call) handler) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('非 Android 平台不会调用原生通道，直接报告不支持', () async {
    mock((MethodCall call) async => null);
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.windows,
    );

    final AndroidInstallAvailability availability = await installer
        .availability();
    final AndroidInstallLaunch launch = await installer.install('/tmp/bb.apk');
    final bool opened = await installer.openInstallPermissionSettings();

    expect(availability.status, ApkInstallAvailability.unsupported);
    expect(launch.status, ApkInstallLaunchStatus.unsupported);
    expect(opened, isFalse);
    expect(calls, isEmpty);

    await installer.dispose();
  });

  test('availability 解析就绪环境，带版本与 ABI', () async {
    mock(
      (MethodCall call) async => <String, Object?>{
        'status': 'ready',
        'package_name': 'ai.bb.bb_mobile',
        'version_code': 12,
        'version_name': '0.0.1',
        'supported_abis': <String>['arm64-v8a', 'armeabi-v7a'],
      },
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    final AndroidInstallAvailability availability = await installer
        .availability();

    expect(calls.single.method, 'availability');
    expect(availability.status, ApkInstallAvailability.ready);
    expect(availability.packageName, 'ai.bb.bb_mobile');
    expect(availability.versionCode, 12);
    expect(availability.versionName, '0.0.1');
    expect(availability.supportedAbis, <String>['arm64-v8a', 'armeabi-v7a']);

    await installer.dispose();
  });

  test('availability 将未知/异常响应归为 unknown，绝不冒充就绪', () async {
    mock((MethodCall call) async => 'not a map');
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    expect(
      (await installer.availability()).status,
      ApkInstallAvailability.unknown,
    );

    mock((MethodCall call) async => <String, Object?>{'status': 'weird'});
    expect(
      (await installer.availability()).status,
      ApkInstallAvailability.unknown,
    );

    await installer.dispose();
  });

  test('原生通道抛 PlatformException 时返回 unknown，不向界面抛异常', () async {
    mock(
      (MethodCall call) async =>
          throw PlatformException(code: 'update_install_error'),
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    final AndroidInstallAvailability availability = await installer
        .availability();
    expect(availability.status, ApkInstallAvailability.unknown);
    expect(availability.reason, 'update_install_error');
    await installer.dispose();
  });

  test('installApk 传递路径并解析 launched 结果', () async {
    mock(
      (MethodCall call) async => <String, Object?>{
        'status': 'launched',
        'version_code': 13,
        'version_name': '0.1.0',
      },
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    final AndroidInstallLaunch launch = await installer.install(
      '/data/user/0/ai.bb.bb_mobile/cache/updates/bb.apk',
    );

    expect(calls.single.method, 'installApk');
    expect(
      (calls.single.arguments as Map<Object?, Object?>)['path'],
      '/data/user/0/ai.bb.bb_mobile/cache/updates/bb.apk',
    );
    expect(launch.status, ApkInstallLaunchStatus.launched);
    expect(launch.versionCode, 13);

    await installer.dispose();
  });

  test('需要安装未知应用权限时不启动安装意图', () async {
    mock(
      (MethodCall call) async => <String, Object?>{
        'status': 'permissionRequired',
        'reason': 'unknown_sources_disabled',
      },
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    final AndroidInstallLaunch launch = await installer.install('/tmp/bb.apk');
    expect(launch.status, ApkInstallLaunchStatus.permissionRequired);
    expect(launch.reason, 'unknown_sources_disabled');
    await installer.dispose();
  });

  test('安装前校验失败的原因映射为稳定枚举', () async {
    final Map<String, ApkInstallRejection> expected =
        <String, ApkInstallRejection>{
          'missing_file': ApkInstallRejection.missingFile,
          'not_apk': ApkInstallRejection.notApk,
          'outside_app_storage': ApkInstallRejection.outsideAppStorage,
          'empty_file': ApkInstallRejection.emptyFile,
          'unreadable_apk': ApkInstallRejection.unreadableApk,
          'package_mismatch': ApkInstallRejection.packageMismatch,
          'version_not_newer': ApkInstallRejection.versionNotNewer,
          'signer_unavailable': ApkInstallRejection.signerUnavailable,
          'signer_mismatch': ApkInstallRejection.signerMismatch,
          'abi_unsupported': ApkInstallRejection.abiUnsupported,
        };
    for (final MapEntry<String, ApkInstallRejection> entry
        in expected.entries) {
      mock(
        (MethodCall call) async => <String, Object?>{
          'status': 'rejected',
          'reason': entry.key,
        },
      );
      final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
        channel: channel,
        platform: TargetPlatform.android,
      );
      final AndroidInstallLaunch launch = await installer.install(
        '/tmp/bb.apk',
      );
      expect(launch.status, ApkInstallLaunchStatus.rejected, reason: entry.key);
      expect(launch.rejection, entry.value, reason: entry.key);
      await installer.dispose();
    }

    // Unknown reason strings must not be guessed as something more specific.
    mock(
      (MethodCall call) async => <String, Object?>{
        'status': 'rejected',
        'reason': 'something_new',
      },
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );
    expect(
      (await installer.install('/tmp/bb.apk')).rejection,
      ApkInstallRejection.unknown,
    );
    await installer.dispose();
  });

  test('系统安装结果通过事件流回传，并可按需取回缓存结果', () async {
    mock((MethodCall call) async => null);
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    // Attaching the handler happens on first native call.
    await installer.availability();

    final Future<AndroidInstallEvent> next = installer.events.first;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AndroidUpdateInstaller.channelName,
          channel.codec.encodeMethodCall(
            const MethodCall(
              AndroidUpdateInstaller.eventMethod,
              <String, Object?>{
                'type': 'installResult',
                'status': 'installed',
                'version_code': 13,
                'expected_version_code': 13,
              },
            ),
          ),
          (ByteData? data) {},
        );

    final AndroidInstallEvent event = await next;
    expect(event.type, ApkInstallEventType.installResult);
    expect(event.outcome, ApkInstallOutcome.installed);
    expect(event.versionCode, 13);
    expect(event.expectedVersionCode, 13);

    await installer.dispose();
  });

  test('安装被取消/未确认时不会报告成功', () async {
    mock(
      (MethodCall call) async => <String, Object?>{
        'type': 'installResult',
        'status': 'cancelled',
      },
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );

    final AndroidInstallEvent? event = await installer.takeLastEvent();
    expect(event?.outcome, ApkInstallOutcome.cancelled);
    expect(calls.single.method, 'takeLastEvent');
    await installer.dispose();
  });

  test('权限页返回后事件区分已被拒绝与已授权', () async {
    mock(
      (MethodCall call) async => <String, Object?>{
        'type': 'permissionResult',
        'granted': false,
      },
    );
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );
    expect(
      (await installer.takeLastEvent())?.outcome,
      ApkInstallOutcome.denied,
    );

    mock(
      (MethodCall call) async => <String, Object?>{
        'type': 'permissionResult',
        'granted': true,
      },
    );
    expect(
      (await installer.takeLastEvent())?.outcome,
      ApkInstallOutcome.granted,
    );
    await installer.dispose();
  });

  test('takeLastEvent 在无结果或错误响应时返回 null', () async {
    mock((MethodCall call) async => null);
    final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
      channel: channel,
      platform: TargetPlatform.android,
    );
    expect(await installer.takeLastEvent(), isNull);

    mock(
      (MethodCall call) async =>
          throw PlatformException(code: 'update_install_error'),
    );
    expect(await installer.takeLastEvent(), isNull);
    await installer.dispose();
  });
}
