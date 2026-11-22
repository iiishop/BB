import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../updates/android_update_installer.dart';
import '../../updates/update_contract.dart';
import '../../updates/download_lane_preference.dart';
import 'update_link_opener.dart';
import 'update_settings_page.dart';
import 'update_ui_mapper.dart';
import 'update_ui_state.dart';

/// Binds the shared update contract to [UpdateSettingsPage].
///
/// It owns only presentation concerns: listening for snapshots/gate changes,
/// mapping them through [mapUpdateSnapshot], rendering the page and confirming
/// link targets. All mechanism (selection, download, checksum, install gate)
/// stays inside the controller.
class UpdateSettingsHost extends StatefulWidget {
  const UpdateSettingsHost({
    super.key,
    required UpdateController this.controller,
    this.androidInstaller,
    this.recovery,
    this.linkOpener,
  }) : unsupported = false;

  /// Explanatory page for hosts without an updater (Linux/macOS today).
  const UpdateSettingsHost.unsupported({super.key})
    : controller = null,
      androidInstaller = null,
      recovery = null,
      linkOpener = null,
      unsupported = true;

  final UpdateController? controller;
  final AndroidUpdateInstaller? androidInstaller;

  /// Install transaction recovered at process start; cleared by the first user
  /// action so it is a one-time notice.
  final AndroidInstallRecovery? recovery;
  final ExternalLinkOpener? linkOpener;
  final bool unsupported;

  @override
  State<UpdateSettingsHost> createState() => _UpdateSettingsHostState();
}

class _UpdateSettingsHostState extends State<UpdateSettingsHost> {
  AndroidInstallRecovery? _recovery;

  @override
  void initState() {
    super.initState();
    _recovery = widget.recovery;
    widget.controller?.addListener(_onChanged);
    _gate.addListener(_onChanged);
  }

  InstallSafetyGate get _gate =>
      widget.controller?.safetyGate ?? InstallSafetyGate.instance;

  @override
  void didUpdateWidget(covariant UpdateSettingsHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.removeListener(_onChanged);
      oldWidget.controller?.safetyGate.removeListener(_onChanged);
      widget.controller?.addListener(_onChanged);
      _gate.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onChanged);
    _gate.removeListener(_onChanged);
    super.dispose();
  }

  bool _rebuildScheduled = false;

  /// Gate updates can arrive while the widget tree is locked (for example a
  /// chat composer persisting its draft during route teardown). Rebuilding in
  /// place then is illegal, so only that phase defers to the next frame.
  void _onChanged() {
    if (!mounted) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_rebuildScheduled) {
        return;
      }
      _rebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rebuildScheduled = false;
        if (mounted) {
          setState(() {});
        }
      });
      return;
    }
    setState(() {});
  }

  void _consumeRecovery() {
    if (_recovery != null) {
      setState(() => _recovery = null);
    }
  }

  void _check() {
    _consumeRecovery();
    unawaited(widget.controller!.check());
  }

  void _download() {
    _consumeRecovery();
    unawaited(widget.controller!.download());
  }

  void _install() {
    _consumeRecovery();
    unawaited(widget.controller!.install());
  }

  void _retry() {
    _consumeRecovery();
    final UpdateController controller = widget.controller!;
    if (retryActionFor(controller.snapshot) == UpdateRetryAction.check) {
      unawaited(controller.check());
    } else {
      unawaited(controller.download());
    }
  }

  void _cancel() => widget.controller!.cancel();

  Future<void> _openPermissionSettings() async {
    final AndroidUpdateInstaller? installer = widget.androidInstaller;
    if (installer == null) {
      return;
    }
    final bool opened = await installer.openInstallPermissionSettings();
    if (!mounted || opened) {
      return;
    }
    _snack('无法打开安装权限设置，请到系统设置中允许 BB 安装应用。');
  }

  Future<void> _confirmAndOpenLink(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _snack('该链接不受支持，未打开。');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('在浏览器中打开链接？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('该链接来自 Release 正文，将在系统浏览器中打开：'),
            const SizedBox(height: 8),
            SelectableText(
              uri.toString(),
              style: const TextStyle(fontSize: 12.5),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final ExternalLinkOpener opener =
        widget.linkOpener ??
        (Platform.isAndroid && widget.androidInstaller != null
            ? _AndroidChannelLinkOpener(widget.androidInstaller!)
            : const PlatformExternalLinkOpener());
    final bool opened = await opener.open(uri);
    if (!mounted) {
      return;
    }
    if (!opened) {
      _snack('无法打开浏览器，请手动访问该链接。');
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.unsupported || widget.controller == null) {
      return const UpdateSettingsPage(
        state: UpdateUiState(
          currentVersion: '—',
          phase: UpdateUiPhase.unsupported,
        ),
      );
    }
    final UpdateController controller = widget.controller!;
    final UpdateUiState state = mapUpdateSnapshot(
      snapshot: controller.snapshot,
      gate: controller.safetyGate,
      recovery: _recovery,
    );
    final List<String> blockers = controller.safetyGate.blockers;
    return UpdateSettingsPage(
      state: state,
      laneSelector: switch (controller.lanePreference) {
        final preference? => ListenableBuilder(
          listenable: preference,
          builder: (context, _) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('最大下载路数'),
            subtitle: const Text('下次下载更新时生效'),
            trailing: DropdownButton<int>(
              value: preference.lanes,
              items: [
                for (final n in DownloadLanePreference.choices)
                  DropdownMenuItem(value: n, child: Text('$n 路')),
              ],
              onChanged: preference.saving
                  ? null
                  : (value) async {
                      if (value == null) return;
                      try {
                        await preference.select(value);
                      } on FileSystemException {
                        _snack('下载路数未保存，请重试。');
                      }
                    },
            ),
          ),
        ),
        null => null,
      },
      onCheck: _check,
      onDownload: _download,
      onInstall: _install,
      onCancelDownload: _cancel,
      onRetry: _retry,
      onOpenInstallPermissionSettings: widget.androidInstaller == null
          ? null
          : _openPermissionSettings,
      onResumeSystemInstaller: _install,
      onOpenLink: _confirmAndOpenLink,
      onReviewPendingWork: blockers.isEmpty
          ? null
          : () => Navigator.of(context).pop(),
    );
  }
}

class _AndroidChannelLinkOpener implements ExternalLinkOpener {
  const _AndroidChannelLinkOpener(this.installer);

  final AndroidUpdateInstaller installer;

  @override
  Future<bool> open(Uri uri) => installer.openExternalUrl(uri.toString());
}
