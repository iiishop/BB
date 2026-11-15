import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
class AndroidUpdateInstaller {
  AndroidUpdateInstaller({MethodChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? const MethodChannel(channelName),
      _platform = platform ?? defaultTargetPlatform;

  static const String channelName = 'bb/update_install';

  /// Native -> Dart method carrying installer/permission results.
  static const String eventMethod = 'updateEvent';

  final MethodChannel _channel;
  final TargetPlatform _platform;
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
    _events.add(AndroidInstallEvent.fromChannel(arguments));
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
  /// [events] (or through [takeLastEvent] after a restart).
  Future<AndroidInstallLaunch> install(String stagedApkPath) async {
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

  Future<void> dispose() async {
    _handlerAttached = false;
    if (isSupported) {
      _channel.setMethodCallHandler(null);
    }
    await _events.close();
  }
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
