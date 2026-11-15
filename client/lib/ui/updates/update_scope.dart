import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../updates/android_update_installer.dart';
import '../../updates/release_update_controller.dart';
import '../../updates/update_contract.dart';
import '../../updates/windows_update_installer.dart';
import 'update_link_opener.dart';
import 'update_settings_host.dart';

/// The process-scoped update stack: one controller per process, created outside
/// the authentication/server-address services so a login switch or server edit
/// cannot create a second check or discard an in-flight download.
///
/// Unsupported hosts (Linux/macOS today) do not construct an updater at all;
/// their settings screen explains that in-app updates are not part of the first
/// batch. On Android the pending-install marker is resolved before the first
/// check, so an install that outlived the previous process is reported instead
/// of silently repeated.
class UpdateScope extends StatefulWidget {
  const UpdateScope({
    super.key,
    required this.child,
    this.controller,
    this.androidInstaller,
    this.recovery,
  });

  final Widget child;

  /// Injection seams for tests; production leaves them null.
  final UpdateController? controller;
  final AndroidUpdateInstaller? androidInstaller;
  final AndroidInstallRecovery? recovery;

  @override
  State<UpdateScope> createState() => _UpdateScopeState();

  static UpdateScopeData? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_UpdateScopeInherited>()
        ?.data;
  }
}

class UpdateScopeData {
  const UpdateScopeData({
    required this.controller,
    required this.androidInstaller,
    required this.recovery,
    required this.linkOpener,
  });

  final UpdateController? controller;
  final AndroidUpdateInstaller? androidInstaller;
  final AndroidInstallRecovery? recovery;
  final ExternalLinkOpener linkOpener;

  /// Builds the settings route for this process. Unsupported hosts get the
  /// explanatory page instead of a dead or duplicated updater.
  Widget buildSettingsPage() {
    final UpdateController? controller = this.controller;
    if (controller == null) {
      return const UpdateSettingsHost.unsupported();
    }
    return UpdateSettingsHost(
      controller: controller,
      androidInstaller: androidInstaller,
      recovery: recovery,
      linkOpener: linkOpener,
    );
  }
}

class _UpdateScopeState extends State<UpdateScope> {
  UpdateController? _controller;
  AndroidUpdateInstaller? _androidInstaller;
  AndroidInstallRecovery? _recovery;
  final ExternalLinkOpener _linkOpener = const PlatformExternalLinkOpener();

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    if (widget.controller != null) {
      _controller = widget.controller;
      _androidInstaller = widget.androidInstaller;
      _recovery = widget.recovery;
    } else if (Platform.isAndroid || Platform.isWindows) {
      try {
        final Directory cache = await getApplicationCacheDirectory();
        final Directory directory = Directory(
          '${cache.path}${Platform.pathSeparator}dea479-updates',
        );
        if (Platform.isAndroid) {
          final AndroidUpdateInstaller installer = AndroidUpdateInstaller(
            cacheDirectory: directory,
          );
          _androidInstaller = installer;
          try {
            _recovery = await installer.recoverPendingInstall();
          } catch (_) {
            _recovery = null;
          }
          _controller = ReleaseUpdateController(
            installer: installer,
            cacheDirectory: directory,
          );
        } else {
          _controller = ReleaseUpdateController(
            installer: WindowsUpdateInstaller(),
            cacheDirectory: directory,
          );
        }
      } catch (_) {
        // Reading the cache directory failed: no updater rather than a partial
        // one. The settings screen stays informative.
        _controller = null;
      }
    }
    if (!mounted) {
      _controller?.dispose();
      return;
    }
    setState(() {});
    final UpdateController? controller = _controller;
    if (controller != null) {
      // Startup check runs once per process and is not awaited: it must never
      // block login restore, the first frame or a message.
      unawaited(controller.checkOnce());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _androidInstaller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _UpdateScopeInherited(
      data: UpdateScopeData(
        controller: _controller,
        androidInstaller: _androidInstaller,
        recovery: _recovery,
        linkOpener: _linkOpener,
      ),
      child: widget.child,
    );
  }
}

class _UpdateScopeInherited extends InheritedWidget {
  const _UpdateScopeInherited({required this.data, required super.child});

  final UpdateScopeData data;

  @override
  bool updateShouldNotify(_UpdateScopeInherited oldWidget) {
    return oldWidget.data.controller != data.controller ||
        oldWidget.data.recovery != data.recovery ||
        oldWidget.data.androidInstaller != data.androidInstaller;
  }
}
