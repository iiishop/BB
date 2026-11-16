import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'release_policy.dart';
import 'update_contract.dart';

/// Android hand-off to the system package installer (DEA-479).
///
/// This file owns only the platform bridge. Version selection, asset matching,
/// checksum verification, the download queue and the "one update at a time"
/// rule stay in the shared update contract (`update_contract.dart`, maintained
/// by Forge); this bridge answers two questions:
///
///  * may this app launch the system installer right now
///    ([availability], including the "install unknown apps" grant), and
///  * is a staged APK acceptable before the installer UI is shown
///    ([install]), plus the installer's own result once the user returns.
///
/// It never silently installs, never uninstalls the current app and never
/// bypasses an Android permission: the downloaded file is validated, then
/// served through the app's FileProvider to the system installer, which still
/// asks the user to confirm.
///
/// It is also the contract's [UpdateInstaller]: [platformInfo] reports the
/// actually installed version/ABI, [install] rehashes the verified file before
/// handing it to the system installer, and [recoverPendingInstall] resolves an
/// install that outlived this process (the Flutter isolate is replaced when the
/// APK is upgraded) instead of trusting a lost in-memory result.
class AndroidUpdateInstaller implements UpdateInstaller {
  AndroidUpdateInstaller({
    MethodChannel? channel,
    TargetPlatform? platform,
    Directory? cacheDirectory,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platform = platform ?? defaultTargetPlatform {
    _cacheDirectory = cacheDirectory;
  }

  static const String channelName = 'bb/update_install';

  /// Records one in-flight install so the next process can tell whether the
  /// upgrade actually happened.
  static const String markerFileName = 'dea479-pending-install.json';

  /// ABI names that the release pipeline publishes APKs for.
  static const List<String> releaseAbis = <String>[
    'arm64-v8a',
    'armeabi-v7a',
    'x86_64',
  ];

  /// Native -> Dart method carrying installer/permission results.
  static const String eventMethod = 'updateEvent';

  final MethodChannel _channel;
  final TargetPlatform _platform;

  /// Process-scoped cache directory holding the controller's staging files and
  /// the pending-install marker. Required for [install] on a real device.
  late final Directory? _cacheDirectory;
  final StreamController<AndroidInstallEvent> _events =
      StreamController<AndroidInstallEvent>.broadcast();
  bool _handlerAttached = false;

  /// Results the system installer and the permission screen report after the
  /// user comes back. Broadcast so a freshly opened surface can wait for the
  /// same event the previous one missed.
  Stream<AndroidInstallEvent> get events => _events.stream;

  bool get isSupported => _platform == TargetPlatform.android;

  void _attachHandler() {
    if (!isSupported || _handlerAttached) {
      return;
    }
    _handlerAttached = true;
    _channel.setMethodCallHandler(_onNativeEvent);
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (call.method != eventMethod) {
      return;
    }
    final Object? arguments = call.arguments;
    if (arguments is! Map) {
      return;
    }
    final AndroidInstallEvent event = AndroidInstallEvent.fromChannel(
      arguments,
    );
    if (event.type == ApkInstallEventType.installResult &&
        (event.outcome == ApkInstallOutcome.cancelled ||
            event.outcome == ApkInstallOutcome.unverified)) {
      // The user backed out of the system dialog (or the installer did not
      // complete). Nothing was upgraded, so no pending transaction may survive
      // into the next process.
      // Completion unlocks install admission. Finish removing this transaction
      // before listeners may retry and write the next marker.
      await _clearMarker();
    }
    _events.add(event);
  }

  /// Whether the system installer can be reached right now.
  Future<AndroidInstallAvailability> availability() async {
    if (!isSupported) {
      return const AndroidInstallAvailability(
        status: ApkInstallAvailability.unsupported,
        reason: 'platform_not_android',
      );
    }
    _attachHandler();
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('availability');
      if (raw is! Map) {
        return const AndroidInstallAvailability(
          status: ApkInstallAvailability.unknown,
          reason: 'bad_native_response',
        );
      }
      return AndroidInstallAvailability.fromChannel(raw);
    } on PlatformException catch (failure) {
      return AndroidInstallAvailability(
        status: ApkInstallAvailability.unknown,
        reason: failure.code,
      );
    } on MissingPluginException {
      return const AndroidInstallAvailability(
        status: ApkInstallAvailability.unsupported,
        reason: 'bridge_missing',
      );
    }
  }

  /// Hands [stagedApkPath] to the system installer.
  ///
  /// The path must already be inside this app's own cache/files directory; the
  /// native side rejects anything else. A `launched` result means the installer
  /// UI is open and the user has not decided yet — the outcome arrives on
  /// [events] (or through [takeLastEvent] while the process lives).
  Future<AndroidInstallLaunch> launchInstaller(String stagedApkPath) async {
    if (!isSupported) {
      return const AndroidInstallLaunch(
        status: ApkInstallLaunchStatus.unsupported,
        reason: 'platform_not_android',
      );
    }
    _attachHandler();
    try {
      final Object? raw = await _channel.invokeMethod<Object?>(
        'installApk',
        <String, Object?>{'path': stagedApkPath},
      );
      if (raw is! Map) {
        return const AndroidInstallLaunch(
          status: ApkInstallLaunchStatus.error,
          reason: 'bad_native_response',
        );
      }
      return AndroidInstallLaunch.fromChannel(raw);
    } on PlatformException catch (failure) {
      return AndroidInstallLaunch(
        status: ApkInstallLaunchStatus.error,
        reason: failure.code,
        message: failure.message,
      );
    } on MissingPluginException {
      return const AndroidInstallLaunch(
        status: ApkInstallLaunchStatus.unsupported,
        reason: 'bridge_missing',
      );
    }
  }

  /// Opens this app's "install unknown apps" screen. The grant result arrives on
  /// [events] as a [ApkInstallEventType.permissionResult] event.
  Future<bool> openInstallPermissionSettings() async {
    if (!isSupported) {
      return false;
    }
    _attachHandler();
    try {
      return await _channel.invokeMethod<bool>(
            'openInstallPermissionSettings',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Retrieves a result the app may have missed while the installer covered the
  /// Flutter surface (for example a recreated route). Returns `null` when
  /// nothing is pending; native memory does not survive process death, so after
  /// a real restart the installed version is read from [availability] instead.
  Future<AndroidInstallEvent?> takeLastEvent() async {
    if (!isSupported) {
      return null;
    }
    _attachHandler();
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('takeLastEvent');
      if (raw is! Map) {
        return null;
      }
      return AndroidInstallEvent.fromChannel(raw);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Contract entry: the actually installed version/build and precise ABI.
  @override
  Future<UpdatePlatformInfo> platformInfo() async {
    if (!isSupported) {
      throw StateError('此更新安装器仅支持 Android。');
    }
    final AndroidInstallAvailability info = await availability();
    if (info.status != ApkInstallAvailability.ready &&
        info.status != ApkInstallAvailability.permissionRequired) {
      throw StateError('无法读取当前安装版本，请稍后重试。');
    }
    final String? version = info.versionName;
    final int? build = info.versionCode;
    if (version == null || build == null) {
      throw StateError('系统未返回应用版本信息，无法检查更新。');
    }
    final String? abi = releaseAbis
        .where(info.supportedAbis.contains)
        .firstOrNull;
    if (abi == null) {
      throw StateError('此设备的 CPU 架构暂不支持自动更新，请按发布页手动安装。');
    }
    return UpdatePlatformInfo(
      os: 'android',
      architecture: abi,
      version: version,
      buildNumber: build,
    );
  }

  /// Contract entry: revalidate the verified APK, record the transaction, then
  /// hand it to the system installer.
  ///
  /// Only `launched` counts as a handoff. A permission prompt is reported so the
  /// controller can ask the user to grant it and retry explicitly; a refused or
  /// unreadable APK throws a readable error and never opens the installer.
  @override
  Future<UpdateInstallResult> install(VerifiedUpdate update) async {
    if (!isSupported) {
      throw StateError('此更新安装器仅支持 Android。');
    }
    final Directory? directory = _cacheDirectory;
    if (directory == null) {
      throw StateError('未配置更新缓存目录，无法安装。');
    }
    final File file = update.file;
    if (!await file.exists()) {
      throw StateError('安装包已不存在，请重新下载。');
    }
    if (await file.length() != update.release.asset.size) {
      throw StateError('安装包长度与 Release 不一致，请重新下载。');
    }
    final String digest = (await sha256.bind(file.openRead()).first).toString();
    if (digest != update.sha256) {
      throw StateError('安装包校验失败，请重新下载。');
    }
    final File marker = await _writeMarker(directory, update);
    final AndroidInstallLaunch launch = await launchInstaller(file.path);
    switch (launch.status) {
      case ApkInstallLaunchStatus.launched:
        return UpdateInstallResult.installerOpened;
      case ApkInstallLaunchStatus.permissionRequired:
        // Nothing was handed to the installer yet: do not leave a transaction
        // that the next process would report as an unfinished upgrade.
        await _deleteQuietly(marker);
        return UpdateInstallResult.permissionRequired;
      default:
        await _deleteQuietly(marker);
        throw StateError(_launchFailure(launch));
    }
  }

  /// Opens an https link in the user's browser. Only called after the user
  /// confirmed the exact target in the update surface.
  Future<bool> openExternalUrl(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (!isSupported ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'openExternalUrl',
            <String, Object?>{'url': uri.toString()},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Resolves an install that was handed to the system installer before this
  /// process was replaced.
  ///
  /// Returns `null` when no transaction is recorded or the installed version
  /// cannot be read yet (the marker is kept for the next launch). Otherwise the
  /// marker and the staged APK are removed and the outcome is final: either the
  /// installed build reached the target, or the upgrade did not happen.
  Future<AndroidInstallRecovery?> recoverPendingInstall() async {
    final Directory? directory = _cacheDirectory;
    if (!isSupported || directory == null) {
      return null;
    }
    final File marker = File(_markerPath(directory));
    if (!await marker.exists()) {
      return null;
    }
    Map<String, dynamic> data;
    try {
      final Object? decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map<String, dynamic>) {
        await _deleteQuietly(marker);
        return null;
      }
      data = decoded;
    } on FormatException {
      await _deleteQuietly(marker);
      return null;
    }
    final String? targetVersion = data['target_version'] as String?;
    if (targetVersion == null) {
      await _deleteQuietly(marker);
      return null;
    }
    AndroidInstallAvailability installed;
    try {
      installed = await availability();
    } catch (_) {
      return null;
    }
    final int? build = installed.versionCode;
    final String? version = installed.versionName;
    if (build == null || version == null) {
      return null;
    }
    final AndroidInstallRecovery recovery = AndroidInstallRecovery(
      outcome: _reachedVersion(version, targetVersion)
          ? AndroidInstallRecoveryOutcome.installed
          : AndroidInstallRecoveryOutcome.notInstalled,
      targetVersion: targetVersion,
      installedVersion: version,
      installedBuildNumber: build,
    );
    await _deleteQuietly(marker);
    await _deleteStagedFile(data['file'] as String?);
    return recovery;
  }

  File _markerPathFile(Directory directory) =>
      File('${directory.path}${Platform.pathSeparator}$markerFileName');

  String _markerPath(Directory directory) => _markerPathFile(directory).path;

  Future<File> _writeMarker(Directory directory, VerifiedUpdate update) async {
    try {
      await directory.create(recursive: true);
      final File marker = _markerPathFile(directory);
      await marker.writeAsString(
        jsonEncode(<String, Object?>{
          'target_version': update.release.version,
          'asset_name': update.release.asset.name,
          'file': update.file.path,
          'sha256': update.sha256,
          'started_at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      return marker;
    } on FileSystemException {
      throw StateError('无法记录安装事务，已停止安装。');
    }
  }

  /// True when the running version reached the version the previous process
  /// handed to the installer. Release tags are SemVer, so a plain equality is
  /// the common case; a newer installed version also proves the handoff
  /// completed.
  bool _reachedVersion(String installed, String target) {
    if (installed == target) {
      return true;
    }
    try {
      return ReleaseVersion.parse(installed)
              .compareTo(ReleaseVersion.parse(target)) >=
          0;
    } on FormatException {
      return false;
    }
  }

  Future<void> _clearMarker() async {
    final Directory? directory = _cacheDirectory;
    if (directory == null) {
      return;
    }
    await _deleteQuietly(File(_markerPath(directory)));
  }

  Future<void> _deleteStagedFile(String? path) async {
    if (path == null || path.isEmpty) {
      return;
    }
    final Directory? directory = _cacheDirectory;
    if (directory == null) return;
    final File file = File(path);
    try {
      // A recovery marker is data, not ownership authority. Resolve both the
      // file and parent to reject traversal and linked staging directories.
      if (!await file.exists()) return;
      final root = await directory.resolveSymbolicLinks();
      final resolved = await file.resolveSymbolicLinks();
      if (!resolved.startsWith('$root${Platform.pathSeparator}') ||
          !resolved.toLowerCase().endsWith('.apk')) {
        return;
      }
      final parent = file.parent;
      if (await parent.resolveSymbolicLinks() != parent.absolute.path) return;
      await file.delete();
      // Remove only an empty owned staging directory, never unrelated files.
      if (parent.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('update-') &&
          await parent.list().isEmpty) {
        await parent.delete();
      }
    } on FileSystemException {
      // Stale cache is not a reason to fail the recovery report.
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // ignore: best-effort cleanup
    }
  }

  String _launchFailure(AndroidInstallLaunch launch) {
    return switch (launch.status) {
      ApkInstallLaunchStatus.rejected => _rejectionMessage(launch.rejection),
      ApkInstallLaunchStatus.unsupported =>
        launch.reason == 'no_package_installer'
            ? '系统没有可用的安装器，无法安装更新。'
            : '当前设备不支持安装更新。',
      _ => launch.message ?? '安装器未能打开，请重试。',
    };
  }

  String _rejectionMessage(ApkInstallRejection rejection) {
    return switch (rejection) {
      ApkInstallRejection.missingFile => '安装包已不存在，请重新下载。',
      ApkInstallRejection.notApk => '下载的文件不是 APK 安装包。',
      ApkInstallRejection.outsideAppStorage => '安装包不在应用私有目录，已拒绝安装。',
      ApkInstallRejection.providerRejected => '系统拒绝了安装包的共享路径，已取消安装。',
      ApkInstallRejection.emptyFile => '安装包为空，请重新下载。',
      ApkInstallRejection.unreadableApk => '安装包已损坏，请重新下载。',
      ApkInstallRejection.packageMismatch => '该安装包不属于 BB，已拒绝安装。',
      ApkInstallRejection.versionNotNewer => '该安装包版本不高于当前版本，已拒绝安装。',
      ApkInstallRejection.signerUnavailable => '无法读取签名信息，已拒绝安装。',
      ApkInstallRejection.signerMismatch => '安装包签名与当前应用不一致，已拒绝安装。',
      ApkInstallRejection.abiUnsupported => '该安装包不适用于本机 CPU 架构，已拒绝安装。',
      ApkInstallRejection.unknown => '安装包未通过校验，已拒绝安装。',
    };
  }

  Future<void> dispose() async {
    _handlerAttached = false;
    if (isSupported) {
      _channel.setMethodCallHandler(null);
    }
    await _events.close();
  }
}

/// What happened to an install transaction recorded before this process.
enum AndroidInstallRecoveryOutcome { installed, notInstalled }

@immutable
class AndroidInstallRecovery {
  const AndroidInstallRecovery({
    required this.outcome,
    required this.targetVersion,
    required this.installedVersion,
    required this.installedBuildNumber,
  });

  final AndroidInstallRecoveryOutcome outcome;

  /// Version the previous process handed to the system installer.
  final String targetVersion;

  /// Version actually installed when this process started.
  final String installedVersion;
  final int installedBuildNumber;

  bool get installed => outcome == AndroidInstallRecoveryOutcome.installed;
}

/// Install environment as reported by the native side.
enum ApkInstallAvailability {
  /// The system installer can be launched (on API < 26 the global toggle is
  /// owned by the installer itself and is handled there).
  ready,

  /// The app misses the "install unknown apps" grant for this source.
  permissionRequired,

  /// No Android installer bridge in this build/platform.
  unsupported,

  /// The bridge answered something unusable; the UI must not claim readiness.
  unknown,
}

/// Result of asking the system installer to open.
@immutable
class AndroidInstallAvailability {
  const AndroidInstallAvailability({
    required this.status,
    this.reason,
    this.packageName,
    this.versionCode,
    this.versionName,
    this.supportedAbis = const <String>[],
  });

  final ApkInstallAvailability status;
  final String? reason;
  final String? packageName;
  final int? versionCode;
  final String? versionName;
  final List<String> supportedAbis;

  factory AndroidInstallAvailability.fromChannel(Map<Object?, Object?> raw) {
    final String? status = _readString(raw['status']);
    return AndroidInstallAvailability(
      status: switch (status) {
        'ready' => ApkInstallAvailability.ready,
        'permissionRequired' => ApkInstallAvailability.permissionRequired,
        'unsupported' => ApkInstallAvailability.unsupported,
        _ => ApkInstallAvailability.unknown,
      },
      reason: _readString(raw['reason']),
      packageName: _readString(raw['package_name']),
      versionCode: _readInt(raw['version_code']),
      versionName: _readString(raw['version_name']),
      supportedAbis: _readStringList(raw['supported_abis']),
    );
  }
}

/// What happened when the app asked for the installer.
enum ApkInstallLaunchStatus {
  /// System installer UI is open; the user has not confirmed yet.
  launched,

  /// The app lacks the "install unknown apps" grant.
  permissionRequired,

  /// The staged file was refused before reaching the installer.
  rejected,

  /// No Android package installer available on this device/build.
  unsupported,

  /// The bridge failed; nothing was launched.
  error,
}

/// Why a staged APK was refused. Mirrors the native reason codes; the UI maps
/// them to user wording so this layer carries no product copy.
enum ApkInstallRejection {
  missingFile('missing_file'),
  notApk('not_apk'),
  outsideAppStorage('outside_app_storage'),
  providerRejected('provider_rejected'),
  emptyFile('empty_file'),
  unreadableApk('unreadable_apk'),
  packageMismatch('package_mismatch'),
  versionNotNewer('version_not_newer'),
  signerUnavailable('signer_unavailable'),
  signerMismatch('signer_mismatch'),
  abiUnsupported('abi_unsupported'),
  unknown('unknown');

  const ApkInstallRejection(this.code);

  final String code;

  static ApkInstallRejection fromCode(String? code) {
    // A null path never reaches the file checks; both native spellings mean the
    // same thing to the user: the staged APK is gone.
    if (code == 'missing_path') {
      return ApkInstallRejection.missingFile;
    }
    for (final ApkInstallRejection value in ApkInstallRejection.values) {
      if (value.code == code) {
        return value;
      }
    }
    return ApkInstallRejection.unknown;
  }
}

/// Result of [AndroidUpdateInstaller.install].
@immutable
class AndroidInstallLaunch {
  const AndroidInstallLaunch({
    required this.status,
    this.reason,
    this.message,
    this.versionCode,
    this.versionName,
  });

  final ApkInstallLaunchStatus status;
  final String? reason;
  final String? message;
  final int? versionCode;
  final String? versionName;

  /// Only set when [status] is [ApkInstallLaunchStatus.rejected].
  ApkInstallRejection get rejection => status == ApkInstallLaunchStatus.rejected
      ? ApkInstallRejection.fromCode(reason)
      : ApkInstallRejection.unknown;

  factory AndroidInstallLaunch.fromChannel(Map<Object?, Object?> raw) {
    final String? status = _readString(raw['status']);
    return AndroidInstallLaunch(
      status: switch (status) {
        'launched' => ApkInstallLaunchStatus.launched,
        'permissionRequired' => ApkInstallLaunchStatus.permissionRequired,
        'rejected' => ApkInstallLaunchStatus.rejected,
        'unsupported' => ApkInstallLaunchStatus.unsupported,
        _ => ApkInstallLaunchStatus.error,
      },
      reason: _readString(raw['reason']),
      message: _readString(raw['message']),
      versionCode: _readInt(raw['version_code']),
      versionName: _readString(raw['version_name']),
    );
  }
}

enum ApkInstallEventType { installResult, permissionResult, unknown }

/// The system installer's answer (or the permission screen's answer).
enum ApkInstallOutcome {
  /// The installer reported success and the installed version code confirms it.
  installed,

  /// The user backed out, or the installer did not complete the install.
  cancelled,

  /// The installer reported success but the new version code could not be
  /// confirmed; the UI must not claim the app was updated.
  unverified,

  /// "Install unknown apps" was granted.
  granted,

  /// The permission screen returned without the grant.
  denied,

  unknown,
}

@immutable
class AndroidInstallEvent {
  const AndroidInstallEvent({
    required this.type,
    required this.outcome,
    this.versionCode,
    this.expectedVersionCode,
  });

  final ApkInstallEventType type;
  final ApkInstallOutcome outcome;
  final int? versionCode;
  final int? expectedVersionCode;

  factory AndroidInstallEvent.fromChannel(Map<Object?, Object?> raw) {
    final ApkInstallEventType type = switch (_readString(raw['type'])) {
      'installResult' => ApkInstallEventType.installResult,
      'permissionResult' => ApkInstallEventType.permissionResult,
      _ => ApkInstallEventType.unknown,
    };
    final String? status = _readString(raw['status']);
    if (type == ApkInstallEventType.permissionResult) {
      return AndroidInstallEvent(
        type: type,
        outcome: raw['granted'] == true
            ? ApkInstallOutcome.granted
            : ApkInstallOutcome.denied,
      );
    }
    return AndroidInstallEvent(
      type: type,
      outcome: switch (status) {
        'installed' => ApkInstallOutcome.installed,
        'cancelled' => ApkInstallOutcome.cancelled,
        'unverified' => ApkInstallOutcome.unverified,
        _ => ApkInstallOutcome.unknown,
      },
      versionCode: _readInt(raw['version_code']),
      expectedVersionCode: _readInt(raw['expected_version_code']),
    );
  }
}

String? _readString(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

int? _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

List<String> _readStringList(Object? value) {
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const <String>[];
}
