import 'package:flutter/foundation.dart';

import '../../updates/android_update_installer.dart';

/// Presentation snapshot for the "软件更新" surface.
///
/// This is deliberately *not* the shared update state. The single source of
/// truth, the once-per-process check, the release selection, the download queue
/// and the install safety gate live in `lib/updates/update_contract.dart` (owned
/// by Forge); the integration layer maps that contract into this read-only
/// snapshot and routes the callbacks below. Keeping the mapping out of the
/// widgets means the UI can be built and tested before the contract lands
/// without a second copy of the mechanism.
enum UpdateUiPhase {
  /// Nothing checked yet; the manual check is offered.
  idle,

  /// A check is in flight (automatic or manual). Never shows a modal.
  checking,

  /// The current build is the newest stable release.
  upToDate,

  /// A newer release exists and its original body is shown.
  available,

  /// The APK/ZIP is downloading with visible progress and a cancel action.
  downloading,

  /// Bytes are complete; the checksum is being verified before install.
  verifying,

  /// Android requires the "install unknown apps" grant for this app.
  permissionRequired,

  /// The system installer is open and waiting for the user.
  installing,

  /// The installer confirmed a newer version is installed.
  installed,

  /// Check, download or install failed; retry may be offered.
  failed,

  /// Installing now would risk drafts or in-flight sends/uploads.
  blocked,

  /// This platform has no in-app update path in the first batch.
  unsupported,
}

@immutable
class UpdateUiState {
  const UpdateUiState({
    required this.currentVersion,
    this.phase = UpdateUiPhase.idle,
    this.latestVersion,
    this.releaseNotes = '',
    this.receivedBytes = 0,
    this.totalBytes,
    this.errorMessage,
    this.canRetry = true,
    this.blockedReason,
  });

  /// Version of the running build, e.g. `0.0.1+2`.
  final String currentVersion;
  final UpdateUiPhase phase;

  /// Target release version, only for phases that have one.
  final String? latestVersion;

  /// Raw GitHub release body; empty shows the explicit "no notes" text.
  final String releaseNotes;

  final int receivedBytes;
  final int? totalBytes;

  /// User-facing failure copy. The update surface never shows a raw exception.
  final String? errorMessage;

  /// Whether the current failure has a retry action.
  final bool canRetry;

  /// Why installing is paused: unsaved draft or in-flight send/upload.
  final String? blockedReason;

  double? get downloadProgress {
    final int? total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  UpdateUiState copyWith({
    UpdateUiPhase? phase,
    String? latestVersion,
    String? releaseNotes,
    int? receivedBytes,
    int? totalBytes,
    String? errorMessage,
    bool? canRetry,
    String? blockedReason,
  }) {
    return UpdateUiState(
      currentVersion: currentVersion,
      phase: phase ?? this.phase,
      latestVersion: latestVersion ?? this.latestVersion,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorMessage: errorMessage ?? this.errorMessage,
      canRetry: canRetry ?? this.canRetry,
      blockedReason: blockedReason ?? this.blockedReason,
    );
  }
}

/// User-facing wording for a refused APK. The native codes carry no product
/// copy so the same refusal reads consistently on every surface.
String apkInstallRejectionMessage(ApkInstallRejection rejection) {
  return switch (rejection) {
    ApkInstallRejection.missingFile => '安装包已不存在，请重新下载。',
    ApkInstallRejection.notApk => '下载的文件不是 APK 安装包。',
    ApkInstallRejection.outsideAppStorage => '安装包不在应用的私有目录中，已拒绝安装。',
    ApkInstallRejection.emptyFile => '安装包为空，请重新下载。',
    ApkInstallRejection.unreadableApk => '安装包已损坏或格式不正确，请重新下载。',
    ApkInstallRejection.packageMismatch => '该安装包不属于 BB，已拒绝安装。',
    ApkInstallRejection.versionNotNewer => '该安装包的版本不高于当前版本，已拒绝安装。',
    ApkInstallRejection.signerUnavailable => '无法读取安装包或当前应用的签名信息，已拒绝安装。',
    ApkInstallRejection.signerMismatch => '安装包签名与当前应用不一致，已拒绝安装。请从官方发布页下载。',
    ApkInstallRejection.abiUnsupported => '该安装包不适用于本机 CPU 架构，已拒绝安装。',
    ApkInstallRejection.unknown => '安装包未通过校验，已拒绝安装。',
  };
}
