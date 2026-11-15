import 'package:flutter/material.dart';

import '../../app.dart';
import 'release_notes_view.dart';
import 'update_ui_state.dart';

/// Settings surface for client self-update.
///
/// Presentation only: every action is a callback supplied by the integration
/// layer that owns the shared update contract. No widget here starts a network
/// request, writes a file or launches the installer by itself, which keeps the
/// "one update at a time", checksum and draft/in-flight gates in one place.
class UpdateSettingsPage extends StatelessWidget {
  const UpdateSettingsPage({
    super.key,
    required this.state,
    this.onCheck,
    this.onDownloadAndInstall,
    this.onCancelDownload,
    this.onRetry,
    this.onOpenInstallPermissionSettings,
    this.onResumeSystemInstaller,
    this.onReviewPendingWork,
  });

  final UpdateUiState state;

  /// Start/retry a manual check. Also used by the idle and up-to-date phases.
  final VoidCallback? onCheck;

  /// Download the fixed target release asset, verify it, then install.
  final VoidCallback? onDownloadAndInstall;
  final VoidCallback? onCancelDownload;

  /// Retry the failed step (check, download or install) after a visible error.
  final VoidCallback? onRetry;

  /// Open the Android "install unknown apps" screen for this app.
  final VoidCallback? onOpenInstallPermissionSettings;

  /// Re-open the system installer when the previous window was dismissed
  /// without a decision.
  final VoidCallback? onResumeSystemInstaller;

  /// Send the user to the draft / in-flight send surface when an install is
  /// paused. Optional: the notice is still complete without it.
  final VoidCallback? onReviewPendingWork;

  static const Key checkButtonKey = Key('update-check');
  static const Key downloadButtonKey = Key('update-download');
  static const Key cancelButtonKey = Key('update-cancel');
  static const Key retryButtonKey = Key('update-retry');
  static const Key permissionButtonKey = Key('update-permission');
  static const Key resumeInstallerButtonKey = Key('update-resume-installer');
  static const Key reviewPendingButtonKey = Key('update-review-pending');
  static const Key progressKey = Key('update-progress');
  static const Key currentVersionKey = Key('update-current-version');
  static const Key latestVersionKey = Key('update-latest-version');
  static const Key errorKey = Key('update-error');
  static const Key blockedKey = Key('update-blocked');
  static const Key upToDateKey = Key('update-up-to-date');
  static const Key installedKey = Key('update-installed');
  static const Key unsupportedKey = Key('update-unsupported');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: AppBar(
        backgroundColor: AppColors.paper,
        surfaceTintColor: Colors.transparent,
        title: Text('设置', style: text.titleMedium),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xl,
              ),
              children: <Widget>[
                Text(
                  '软件更新',
                  style: text.labelSmall?.copyWith(
                    color: AppColors.accentDeep,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text('BB 客户端', key: currentVersionKey, style: text.titleLarge),
                const SizedBox(height: AppSpacing.xs),
                Text('当前版本 ${state.currentVersion}', style: text.bodySmall),
                const SizedBox(height: AppSpacing.md),
                _body(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return switch (state.phase) {
      UpdateUiPhase.idle => _Idle(
        onCheck: onCheck,
        onDownloadAndInstall: onDownloadAndInstall,
      ),
      UpdateUiPhase.checking => _Checking(),
      UpdateUiPhase.upToDate => _UpToDate(onCheck: onCheck),
      UpdateUiPhase.available => _Available(
        state: state,
        onDownloadAndInstall: onDownloadAndInstall,
      ),
      UpdateUiPhase.downloading => _Downloading(
        state: state,
        onCancelDownload: onCancelDownload,
      ),
      UpdateUiPhase.verifying => _Verifying(state: state),
      UpdateUiPhase.permissionRequired => _PermissionRequired(
        onOpenInstallPermissionSettings: onOpenInstallPermissionSettings,
      ),
      UpdateUiPhase.installing => _Installing(
        state: state,
        onResumeSystemInstaller: onResumeSystemInstaller,
      ),
      UpdateUiPhase.installed => _Installed(state: state),
      UpdateUiPhase.failed => _Failed(state: state, onRetry: onRetry),
      UpdateUiPhase.blocked => _Blocked(
        state: state,
        onReviewPendingWork: onReviewPendingWork,
      ),
      UpdateUiPhase.unsupported => const _Unsupported(),
    };
  }
}

class _Idle extends StatelessWidget {
  const _Idle({this.onCheck, this.onDownloadAndInstall});

  final VoidCallback? onCheck;
  final VoidCallback? onDownloadAndInstall;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        Text(
          '每次启动会在后台检查一次更新；有新版本时这里会显示版本号和原始更新说明。'
          '手动检查不会中断聊天，也不会自动下载或退出应用。',
          style: text.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          key: UpdateSettingsPage.checkButtonKey,
          onPressed: onCheck,
          child: const Text('检查更新'),
        ),
        if (onDownloadAndInstall != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            key: UpdateSettingsPage.downloadButtonKey,
            onPressed: onDownloadAndInstall,
            child: const Text('下载并安装更新'),
          ),
        ],
      ],
    );
  }
}

class _Checking extends StatelessWidget {
  const _Checking();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        const LinearProgressIndicator(minHeight: 3),
        const SizedBox(height: AppSpacing.sm),
        Text('正在检查更新…', style: text.bodyMedium),
        const SizedBox(height: AppSpacing.xs),
        Text('这不会阻塞登录、聊天或收发消息。', style: text.bodySmall),
      ],
    );
  }
}

class _UpToDate extends StatelessWidget {
  const _UpToDate({this.onCheck});

  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        Row(
          key: UpdateSettingsPage.upToDateKey,
          children: <Widget>[
            const Icon(
              Icons.check_circle_outline,
              color: AppColors.success,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text('已是最新版本', style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('同版本或更旧的版本不会提示，也不会降级。', style: text.bodySmall),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton(
          key: UpdateSettingsPage.checkButtonKey,
          onPressed: onCheck,
          child: const Text('重新检查'),
        ),
      ],
    );
  }
}

class _Available extends StatelessWidget {
  const _Available({required this.state, this.onDownloadAndInstall});

  final UpdateUiState state;
  final VoidCallback? onDownloadAndInstall;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String version = state.latestVersion ?? '';
    return _Panel(
      highlight: true,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.system_update_alt,
              color: AppColors.accent,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                version.isEmpty ? '发现新版本' : '发现新版本 $version',
                key: UpdateSettingsPage.latestVersionKey,
                style: text.titleMedium?.copyWith(
                  color: AppColors.accentDeep,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('更新说明来自该 Release 的原始正文，未经过改写。', style: text.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: ReleaseNotesView(body: state.releaseNotes),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          key: UpdateSettingsPage.downloadButtonKey,
          onPressed: onDownloadAndInstall,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('下载并安装'),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('下载完成并校验通过后才会打开系统安装界面；不会静默下载或自动退出。', style: text.bodySmall),
      ],
    );
  }
}

class _Downloading extends StatelessWidget {
  const _Downloading({required this.state, this.onCancelDownload});

  final UpdateUiState state;
  final VoidCallback? onCancelDownload;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final double? progress = state.downloadProgress;
    return _Panel(
      children: <Widget>[
        Text(
          state.latestVersion == null
              ? '正在下载更新…'
              : '正在下载 ${state.latestVersion}…',
          style: text.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        LinearProgressIndicator(
          key: UpdateSettingsPage.progressKey,
          value: progress,
          minHeight: 4,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          progress == null
              ? _formatBytes(state.receivedBytes)
              : '${_formatBytes(state.receivedBytes)} / '
                    '${_formatBytes(state.totalBytes ?? 0)}',
          style: text.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton(
          key: UpdateSettingsPage.cancelButtonKey,
          onPressed: onCancelDownload,
          child: const Text('取消下载'),
        ),
      ],
    );
  }
}

class _Verifying extends StatelessWidget {
  const _Verifying({required this.state});

  final UpdateUiState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        const LinearProgressIndicator(minHeight: 3),
        const SizedBox(height: AppSpacing.sm),
        Text('正在校验下载完整性…', style: text.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        Text('校验和缺失或不匹配时不会进入安装。', style: text.bodySmall),
      ],
    );
  }
}

class _PermissionRequired extends StatelessWidget {
  const _PermissionRequired({this.onOpenInstallPermissionSettings});

  final VoidCallback? onOpenInstallPermissionSettings;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      warning: true,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.shield_outlined,
              color: AppColors.warning,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text('需要允许 BB 安装应用', style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Android 要求在此来源安装应用前由你授予“安装未知应用”权限。'
          '授权后回到这里即可继续；取消该授权不会安装任何东西。',
          style: text.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          key: UpdateSettingsPage.permissionButtonKey,
          onPressed: onOpenInstallPermissionSettings,
          child: const Text('打开安装权限设置'),
        ),
      ],
    );
  }
}

class _Installing extends StatelessWidget {
  const _Installing({required this.state, this.onResumeSystemInstaller});

  final UpdateUiState state;
  final VoidCallback? onResumeSystemInstaller;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        Text('等待系统安装确认', style: text.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '已在系统安装界面中打开 '
          '${state.latestVersion ?? '更新包'}。安装由系统完成，BB 不会静默安装，'
          '也不会卸载当前应用；取消安装时旧版本保持可用。',
          style: text.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton(
          key: UpdateSettingsPage.resumeInstallerButtonKey,
          onPressed: onResumeSystemInstaller,
          child: const Text('重新打开安装界面'),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('安装完成后重新打开应用即可使用新版本。', style: text.bodySmall),
      ],
    );
  }
}

class _Installed extends StatelessWidget {
  const _Installed({required this.state});

  final UpdateUiState state;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        Row(
          key: UpdateSettingsPage.installedKey,
          children: <Widget>[
            const Icon(
              Icons.verified_outlined,
              color: AppColors.success,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                state.latestVersion == null
                    ? '更新已安装'
                    : '已安装 ${state.latestVersion}',
                style: text.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('重新打开应用后运行的就是新版本。', style: text.bodySmall),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.state, this.onRetry});

  final UpdateUiState state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      danger: true,
      children: <Widget>[
        Text(
          '更新未完成',
          style: text.titleMedium?.copyWith(color: AppColors.danger),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          state.errorMessage ?? '发生了未知错误，请稍后重试。',
          key: UpdateSettingsPage.errorKey,
          style: text.bodyMedium,
        ),
        if (state.canRetry) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(
            key: UpdateSettingsPage.retryButtonKey,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ],
    );
  }
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.state, this.onReviewPendingWork});

  final UpdateUiState state;
  final VoidCallback? onReviewPendingWork;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      warning: true,
      children: <Widget>[
        Row(
          key: UpdateSettingsPage.blockedKey,
          children: <Widget>[
            const Icon(
              Icons.pause_circle_outline,
              color: AppColors.warning,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text('暂时不能安装更新', style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          state.blockedReason ??
              '还有未完成的草稿或正在进行的发送/上传。安装前需要先处理它们，'
                  '更新不会自行丢弃或替你取消这些操作。',
          style: text.bodyMedium,
        ),
        if (onReviewPendingWork != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(
            key: UpdateSettingsPage.reviewPendingButtonKey,
            onPressed: onReviewPendingWork,
            child: const Text('去处理未完成的操作'),
          ),
        ],
      ],
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return _Panel(
      children: <Widget>[
        Text(
          '当前平台暂不支持应用内更新',
          key: UpdateSettingsPage.unsupportedKey,
          style: text.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '首批仅支持 Windows 和 Android。其他平台请按发布页说明手动安装。',
          style: text.bodyMedium,
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.children,
    this.highlight = false,
    this.warning = false,
    this.danger = false,
  });

  final List<Widget> children;
  final bool highlight;
  final bool warning;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color background = danger
        ? AppColors.dangerSurface
        : warning
        ? AppColors.warningSurface
        : highlight
        ? AppColors.accentSoft
        : AppColors.surface;
    final Color border = danger
        ? AppColors.dangerBorder
        : warning
        ? AppColors.warningBorder
        : AppColors.border;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
