import 'dart:io';

import 'download_lane_preference.dart';

import 'package:flutter/foundation.dart';

import '../services/install_safety_gate.dart';
export '../services/install_safety_gate.dart';

/// Shared update protocol. Owned by Forge; UI and native adapters consume it.
enum UpdatePhase {
  idle,
  checking,
  current,
  available,
  downloading,
  verifying,
  ready,
  installing,
  permissionRequired,
  installerOpened,
  installed,
  cancelled,
  failed,
  unsupported,
}

class UpdatePlatformInfo {
  const UpdatePlatformInfo({
    required this.os,
    required this.architecture,
    required this.version,
    required this.buildNumber,
  });
  final String os; // windows / android; other platforms are unsupported.
  final String architecture; // x64 / arm64-v8a / armeabi-v7a / x86_64
  final String version; // Actual installed version, never a synthetic override.
  final int buildNumber;
}

class UpdateAsset {
  const UpdateAsset({
    required this.id,
    required this.name,
    required this.url,
    required this.size,
  });
  final int id;
  final String name;
  final Uri url;
  final int size;
}

class UpdateRelease {
  const UpdateRelease({
    required this.id,
    required this.tag,
    required this.version,
    required this.body,
    required this.htmlUrl,
    required this.asset,
    required this.checksums,
  });
  final int id;
  final String tag;
  final String version;
  final String body; // Original GitHub body; do not summarize or execute it.
  final Uri htmlUrl;
  final UpdateAsset asset;
  final UpdateAsset checksums;
}

class VerifiedUpdate {
  const VerifiedUpdate({
    required this.release,
    required this.file,
    required this.sha256,
  });
  final UpdateRelease release;
  final File file;
  final String sha256;
}

enum UpdateInstallResult { permissionRequired, installerOpened }

abstract interface class UpdateInstaller {
  Future<UpdatePlatformInfo> platformInfo();

  /// Only receives a verified file after the safety gate is acquired. Must
  /// revalidate file integrity before native handoff. May throw readable errors.
  /// Windows returns only on failure; successful handoff exits this process.
  /// Android returns permissionRequired after opening source-permission settings;
  /// retry install explicitly after returning. Never uninstall or silently retry.
  Future<UpdateInstallResult> install(VerifiedUpdate update);
}

class UpdateSnapshot {
  const UpdateSnapshot({
    this.phase = UpdatePhase.idle,
    this.release,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.message,
    this.installedVersion,
  });
  final UpdatePhase phase;
  final UpdateRelease? release;
  final int receivedBytes;
  final int totalBytes;
  final String? message;
  final String? installedVersion;
  double? get progress => totalBytes > 0 ? receivedBytes / totalBytes : null;
  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.verifying ||
      phase == UpdatePhase.installing;
}

abstract class UpdateController extends ChangeNotifier {
  DownloadLanePreference? get lanePreference => null;
  UpdateSnapshot get snapshot;
  InstallSafetyGate get safetyGate;

  /// Called by process root only; repeated calls are harmless.
  Future<void> checkOnce();
  Future<void> check();
  Future<void> download();

  /// Cancels checking/downloading only; never interrupts an install transaction.
  void cancel();
  Future<void> install();
}
