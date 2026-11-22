import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'download_lane_preference.dart';
import 'release_client.dart';
import 'release_policy.dart';
import 'update_contract.dart';

class ReleaseUpdateController extends UpdateController {
  ReleaseUpdateController({
    required this.installer,
    required this.cacheDirectory,
    InstallSafetyGate? safetyGate,
    this.lanePreference,
    this.httpFactory,
  }) : safetyGate = safetyGate ?? InstallSafetyGate.instance;
  final UpdateInstaller installer;
  final Directory cacheDirectory;
  @override
  final InstallSafetyGate safetyGate;
  @override
  final DownloadLanePreference? lanePreference;
  final HttpClient Function()? httpFactory;
  @override
  UpdateSnapshot get snapshot => _snapshot;
  UpdateSnapshot _snapshot = const UpdateSnapshot();
  bool _started = false;
  bool _working = false;
  ({bool installed, String? message})? _platformCompletion;
  bool _disposed = false;
  bool _cancelled = false;
  ReleaseClient? _client;
  DateTime? _retryAt;
  VerifiedUpdate? _verified;
  Directory? _staging;

  void _emit(
    UpdatePhase phase, {
    UpdateRelease? release,
    String? message,
    int? received,
    String? installed,
  }) {
    if (_disposed) return;
    _snapshot = UpdateSnapshot(
      phase: phase,
      release: release ?? snapshot.release,
      receivedBytes: received ?? snapshot.receivedBytes,
      totalBytes: (release ?? snapshot.release)?.asset.size ?? 0,
      installedVersion: installed ?? snapshot.installedVersion,
      message: message,
    );
    notifyListeners();
  }

  @override
  Future<void> checkOnce() async {
    if (_started) return;
    _started = true;
    await check();
  }

  @override
  Future<void> check() async {
    if (_working || safetyGate.installing || snapshot.busy || _disposed) return;
    if (_waitingForRetry()) return;
    _working = true;
    _cancelled = false;
    _verified = null;
    _snapshot = UpdateSnapshot(installedVersion: snapshot.installedVersion);
    _emit(UpdatePhase.checking);
    try {
      await _cleanStage();
      final info = await installer.platformInfo();
      assetName('0.0.0', info); // Reject unsupported platforms before network.
      _emit(
        UpdatePhase.checking,
        installed: '${info.version}+${info.buildNumber}',
      );
      if (_cancelled || _disposed) return;
      final client = _client = ReleaseClient(httpFactory: httpFactory);
      final release = selectRelease(await client.releases(), info);
      if (_cancelled || _disposed) return;
      _emit(
        release == null ? UpdatePhase.current : UpdatePhase.available,
        release: release,
      );
    } catch (error) {
      _failure(error);
    } finally {
      _working = false;
      _finishClient();
    }
  }

  @override
  Future<void> download() async {
    final release = snapshot.release;
    if (_working ||
        safetyGate.installing ||
        snapshot.busy ||
        release == null ||
        _disposed) {
      return;
    }
    if (_waitingForRetry()) return;
    _working = true;
    _cancelled = false;
    _verified = null;
    final lanes = lanePreference?.lanes ?? maxDownloadConcurrency;
    _emit(UpdatePhase.downloading, received: 0);
    try {
      await _cleanStage();
      await cacheDirectory.create(recursive: true);
      final staging = _staging = await cacheDirectory.createTemp('update-');
      if (_cancelled || _disposed) return;
      final client = _client = ReleaseClient(
        httpFactory: httpFactory,
        downloadConcurrency: lanes,
      );
      final expected = checksumFor(
        await client.checksums(release.checksums),
        release.asset.name,
      );
      if (_cancelled || _disposed) return;
      final file = File(
        '${staging.path}${Platform.pathSeparator}${release.asset.name}',
      );
      await client.download(release.asset, file, (received) {
        if (!_cancelled) _emit(UpdatePhase.downloading, received: received);
      });
      if (_cancelled || _disposed) return;
      _emit(UpdatePhase.verifying);
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (_cancelled || _disposed) return;
      if (actual != expected) throw StateError('安装包 SHA-256 校验失败，不能安装，请重试。');
      _verified = VerifiedUpdate(
        release: release,
        file: file,
        sha256: expected,
      );
      _emit(UpdatePhase.ready);
    } catch (error) {
      _failure(error);
    } finally {
      try {
        if (_verified == null) await _cleanStage();
      } finally {
        _working = false;
        _finishClient();
      }
    }
  }

  @override
  void cancel() {
    if (![
      UpdatePhase.checking,
      UpdatePhase.downloading,
      UpdatePhase.verifying,
    ].contains(snapshot.phase)) {
      return;
    }
    _cancelled = true;
    _client?.close();
    // Remain busy until outstanding file writes/cleanup finish: retry cannot
    // race deletion of a newer download's directory.
  }

  @override
  Future<void> install() async {
    final verified = _verified;
    if (_working ||
        safetyGate.installing ||
        snapshot.busy ||
        verified == null ||
        _disposed) {
      return;
    }
    _working = true;
    _platformCompletion = null;
    var acquired = false;
    try {
      safetyGate.acquire();
      acquired = true;
      _emit(UpdatePhase.installing);
      if (await verified.file.length() != verified.release.asset.size ||
          (await sha256.bind(verified.file.openRead()).first).toString() !=
              verified.sha256) {
        _verified = null;
        throw StateError('安装包在校验后发生变化，请重新下载。');
      }
      final result = await installer.install(verified);
      _emit(
        result == UpdateInstallResult.permissionRequired
            ? UpdatePhase.permissionRequired
            : UpdatePhase.installerOpened,
      );
      if (result == UpdateInstallResult.installerOpened) {
        // Android can replace the process while its system dialog is open.
        // Keep admission locked until a native terminal result or cold restart.
        acquired = false;
        final completion = _platformCompletion;
        if (completion != null) {
          finishPlatformInstall(
            installed: completion.installed,
            message: completion.message,
          );
        }
      }
    } catch (error) {
      _failure(error);
    } finally {
      if (acquired) safetyGate.release();
      _working = false;
    }
  }

  /// Native completion belongs to the process-scoped adapter, not a route.
  /// A result delivered during launch is applied once handoff is confirmed.
  void finishPlatformInstall({required bool installed, String? message}) {
    if (snapshot.phase == UpdatePhase.installing) {
      _platformCompletion = (installed: installed, message: message);
      return;
    }
    if (snapshot.phase != UpdatePhase.installerOpened) return;
    _emit(
      installed ? UpdatePhase.installed : UpdatePhase.failed,
      message: message ?? (installed ? '更新已安装。' : '安装未完成，旧应用已保留，可重试。'),
    );
    safetyGate.release();
  }

  void _failure(Object error) {
    if (error is ReleaseRateLimit) _retryAt = error.retryAt;
    if (_cancelled) return;
    final message = error is SocketException || error is TimeoutException
        ? '无法连接更新服务器，请检查网络后重试。'
        : error.toString().replaceFirst('Bad state: ', '');
    _emit(UpdatePhase.failed, message: message);
  }

  bool _waitingForRetry() {
    final retryAt = _retryAt;
    if (retryAt == null || !retryAt.isAfter(DateTime.now())) return false;
    _emit(UpdatePhase.failed, message: ReleaseRateLimit(retryAt).toString());
    return true;
  }

  void _finishClient() {
    _client?.close();
    _client = null;
    if (_cancelled) _emit(UpdatePhase.cancelled, message: '已取消，可手动重试。');
  }

  Future<void> _cleanStage() async {
    final staging = _staging;
    _staging = null;
    if (staging != null && await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    _client?.close();
    super.dispose();
  }
}
