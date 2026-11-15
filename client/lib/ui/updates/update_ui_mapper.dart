import 'package:flutter/foundation.dart';

import '../../updates/android_update_installer.dart';
import '../../updates/update_contract.dart';
import 'update_ui_state.dart';

/// Maps Forge's shared update contract into the read-only presentation state.
///
/// This is the only place that translates contract phases; widgets never know
/// about `UpdateSnapshot`, and the contract keeps the single source of truth for
/// selection, download and installation.
UpdateUiState mapUpdateSnapshot({
  required UpdateSnapshot snapshot,
  required InstallSafetyGate gate,
  AndroidInstallRecovery? recovery,
}) {
  final String currentVersion =
      snapshot.installedVersion ?? recovery?.installedVersion ?? '—';
  final String? latestVersion =
      recovery?.targetVersion ?? snapshot.release?.version;
  final String releaseNotes = snapshot.release?.body ?? '';

  UpdateUiPhase phase;
  String? message = snapshot.message;
  bool canRetry = true;

  // A transaction recorded before this process is a one-time notice until any
  // user action supersedes it. The contract itself has no cross-process state.
  if (recovery != null &&
      (snapshot.phase == UpdatePhase.idle ||
          snapshot.phase == UpdatePhase.current)) {
    if (recovery.installed) {
      phase = UpdateUiPhase.installed;
    } else {
      phase = UpdateUiPhase.failed;
      message =
          '上次安装（${recovery.targetVersion}）未完成，当前仍是 '
          '${recovery.installedVersion}。请重新检查更新后重试。';
    }
  } else {
    phase = switch (snapshot.phase) {
      UpdatePhase.idle => UpdateUiPhase.idle,
      UpdatePhase.checking => UpdateUiPhase.checking,
      UpdatePhase.current => UpdateUiPhase.upToDate,
      UpdatePhase.installed => UpdateUiPhase.installed,
      UpdatePhase.available => UpdateUiPhase.available,
      UpdatePhase.downloading => UpdateUiPhase.downloading,
      UpdatePhase.verifying => UpdateUiPhase.verifying,
      UpdatePhase.ready => UpdateUiPhase.ready,
      UpdatePhase.installing ||
      UpdatePhase.installerOpened => UpdateUiPhase.installing,
      UpdatePhase.permissionRequired => UpdateUiPhase.permissionRequired,
      UpdatePhase.cancelled || UpdatePhase.failed => UpdateUiPhase.failed,
      UpdatePhase.unsupported => UpdateUiPhase.unsupported,
    };
    if (snapshot.phase == UpdatePhase.cancelled) {
      message = snapshot.message ?? '已取消，可重试。';
    }
    if (snapshot.phase == UpdatePhase.unsupported) {
      canRetry = false;
    }
  }

  // Installation is the guarded action: a verified file plus any registered
  // draft / in-flight send must show the block instead of an install button.
  final List<String> blockers = gate.blockers;
  if (phase == UpdateUiPhase.ready && blockers.isNotEmpty) {
    phase = UpdateUiPhase.blocked;
  }

  return UpdateUiState(
    currentVersion: currentVersion,
    phase: phase,
    latestVersion: latestVersion,
    releaseNotes: releaseNotes,
    receivedBytes: snapshot.receivedBytes,
    totalBytes: snapshot.totalBytes > 0 ? snapshot.totalBytes : null,
    errorMessage: message,
    canRetry: phase == UpdateUiPhase.failed ? canRetry : false,
    blockedReason: phase == UpdateUiPhase.blocked ? blockers.join('\n') : null,
  );
}

/// The retry action for a failed step: a check failure has no selected release,
/// while a download/install failure keeps the pinned release and must not
/// re-check (which could silently pick a different release).
UpdateRetryAction retryActionFor(UpdateSnapshot snapshot) {
  return snapshot.release == null
      ? UpdateRetryAction.check
      : UpdateRetryAction.download;
}

enum UpdateRetryAction { check, download }

/// Test-only helper: maps a phase directly for widget tests that do not build a
/// contract controller.
@visibleForTesting
UpdateUiState mapPhaseForTest(
  UpdateUiPhase phase, {
  String currentVersion = '0.0.1+2',
  String? latestVersion,
  String releaseNotes = '',
  String? message,
  bool canRetry = false,
  String? blockedReason,
}) {
  return UpdateUiState(
    currentVersion: currentVersion,
    phase: phase,
    latestVersion: latestVersion,
    releaseNotes: releaseNotes,
    errorMessage: message,
    canRetry: canRetry,
    blockedReason: blockedReason,
  );
}
