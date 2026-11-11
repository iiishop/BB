import 'dart:async';
import 'dart:typed_data';
import 'dart:ui'
    show DisplayFeature, DisplayFeatureState, DisplayFeatureType, ImageFilter;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/auth_models.dart';
import '../../models/profile_models.dart';
import '../../services/profile_service.dart';
import '../../validation/profile_rules.dart';
import '../widgets/profile_avatar.dart';

/// Which of the three Profile presentations applies.
enum ProfilePanelMode {
  /// Narrow phone: full-screen sheet sliding in from the left.
  mobile,

  /// Unfolded foldable/tablet: left half, blurred right half.
  folded,

  /// Wide desktop: floating card without a dark backdrop.
  desktop,
}

/// Resolves the presentation exactly as the STEP-2 spec orders it:
/// a flat fold/hinge wins over the width breakpoint; only then does a narrow
/// width mean phone and a wide width mean desktop.
ProfilePanelMode resolveProfilePanelMode(BuildContext context) {
  final List<DisplayFeature> features = MediaQuery.displayFeaturesOf(context);
  final bool folded = features.any(_isFlatFold);
  if (folded) {
    return ProfilePanelMode.folded;
  }
  return MediaQuery.sizeOf(context).width < 600
      ? ProfilePanelMode.mobile
      : ProfilePanelMode.desktop;
}

bool _isFlatFold(DisplayFeature feature) {
  return (feature.type == DisplayFeatureType.fold ||
          feature.type == DisplayFeatureType.hinge) &&
      feature.state == DisplayFeatureState.postureFlat;
}

/// The left-half width for the folded presentation, taken from the display
/// feature's own bounds. The 600dp breakpoint is never used as a fold judgement.
double foldedPanelWidth(BuildContext context) {
  final Size size = MediaQuery.sizeOf(context);
  for (final DisplayFeature feature in MediaQuery.displayFeaturesOf(context)) {
    if (!_isFlatFold(feature)) {
      continue;
    }
    final Rect bounds = feature.bounds;
    if (bounds.height >= bounds.width && bounds.left > 0) {
      return bounds.left.clamp(280.0, size.width - 1);
    }
  }
  return size.width / 2;
}

/// What happened inside a Profile panel.
class ProfilePanelResult {
  const ProfilePanelResult({
    this.changed = false,
    this.signedOut = false,
    this.logout,
  });

  final bool changed;
  final bool signedOut;
  final LogoutResult? logout;
}

/// Opens the Profile panel in the right presentation for this viewport.
Future<ProfilePanelResult?> openProfilePanel(
  BuildContext context, {
  required ProfileGateway gateway,
  required AuthUser user,
  Profile? initialProfile,
  Uint8List? initialAvatar,
  required Future<LogoutResult> Function() onLogout,
}) {
  final ProfilePanelMode mode = resolveProfilePanelMode(context);
  final double foldedWidth = foldedPanelWidth(context);
  final bool desktop = mode == ProfilePanelMode.desktop;

  return showGeneralDialog<ProfilePanelResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '个人资料',
    // Desktop must not dim the whole app; the other two presentations are
    // covered by the panel/blur itself.
    barrierColor: Colors.transparent,
    transitionDuration: Duration(milliseconds: desktop ? 200 : 320),
    pageBuilder:
        (BuildContext context, Animation<double> a1, Animation<double> a2) {
          final Widget panel = ProfilePanel(
            mode: mode,
            gateway: gateway,
            user: user,
            initialProfile: initialProfile,
            initialAvatar: initialAvatar,
            onLogout: onLogout,
          );
          if (mode == ProfilePanelMode.mobile) {
            return Material(
              color: AppColors.paper,
              child: SafeArea(child: panel),
            );
          }
          if (mode == ProfilePanelMode.folded) {
            return _FoldedFrame(width: foldedWidth, child: panel);
          }
          return _DesktopFrame(child: panel);
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondary,
          Widget child,
        ) {
          final CurvedAnimation curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          if (desktop) {
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                child: child,
              ),
            );
          }
          // Slides in from the left and back out to the left, as specified for
          // both narrow and folded layouts.
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-1, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
  );
}

class _FoldedFrame extends StatelessWidget {
  const _FoldedFrame({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: width,
            child: Material(
              color: AppColors.paper,
              elevation: 18,
              child: SafeArea(child: child),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: ColoredBox(
                  color: const Color(0x33161D1E),
                  child: Semantics(
                    label: '右侧内容已模糊',
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopFrame extends StatelessWidget {
  const _DesktopFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440, maxHeight: 700),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.paper,
                borderRadius: BorderRadius.circular(AppRadius.panel),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1F161D1E),
                    blurRadius: 40,
                    spreadRadius: 2,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Profile content shared by all three presentations.
class ProfilePanel extends StatefulWidget {
  const ProfilePanel({
    super.key,
    required this.mode,
    required this.gateway,
    required this.user,
    this.initialProfile,
    this.initialAvatar,
    required this.onLogout,
  });

  final ProfilePanelMode mode;
  final ProfileGateway gateway;
  final AuthUser user;
  final Profile? initialProfile;
  final Uint8List? initialAvatar;

  /// Server-side logout + local clear, supplied by the host so this panel stays
  /// independent of the auth implementation.
  final Future<LogoutResult> Function() onLogout;

  static const Key panelKey = Key('profile-panel');
  static const Key closeButtonKey = Key('profile-close');
  static const Key nicknameValueKey = Key('profile-nickname');
  static const Key accountValueKey = Key('profile-account');
  static const Key signatureValueKey = Key('profile-signature');
  static const Key editNicknameKey = Key('profile-edit-nickname');
  static const Key editSignatureKey = Key('profile-edit-signature');
  static const Key avatarButtonKey = Key('profile-avatar-button');
  static const Key removeAvatarKey = Key('profile-remove-avatar');
  static const Key logoutButtonKey = Key('profile-logout');
  static const Key otherProfileKey = Key('profile-other-account');
  static const Key errorKey = Key('profile-error');

  @override
  State<ProfilePanel> createState() => _ProfilePanelState();
}

class _ProfilePanelState extends State<ProfilePanel> {
  Profile? _profile;
  Uint8List? _avatar;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  bool _changed = false;

  bool get _isWide => widget.mode == ProfilePanelMode.desktop;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _avatar = widget.initialAvatar;
    unawaited(_load());
  }

  /// Always asks the server; avatar bytes are revalidated with the cached
  /// version, so opening the panel can never show a stale avatar.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Profile profile = await widget.gateway.loadProfile();
      final AvatarImage image = await widget.gateway.loadAvatar();
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _avatar = image.bytes;
        _loading = false;
      });
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '资料加载失败，请稍后重试';
      });
    }
  }

  Future<void> _reloadAvatar() async {
    try {
      final AvatarImage image = await widget.gateway.loadAvatar();
      if (!mounted) {
        return;
      }
      setState(() {
        _avatar = image.bytes;
        _changed = true;
      });
    } on AuthFailure catch (failure) {
      _showSnack(failure.message);
    }
  }

  Future<void> _editNickname() async {
    final Profile? profile = _profile;
    if (profile == null) {
      return;
    }
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _TextEditDialog(
        title: '修改昵称',
        initial: profile.username,
        minCodePoints: usernameMinCodePoints,
        maxCodePoints: usernameMaxCodePoints,
        helperText: '昵称同时就是用户名，3–24 个字符',
      ),
    );
    if (value == null || value == profile.username) {
      return;
    }
    await _save(
      ProfilePatch(setUsername: true, username: value),
      successMessage: '昵称已更新',
    );
  }

  Future<void> _editSignature() async {
    final Profile? profile = _profile;
    if (profile == null) {
      return;
    }
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _TextEditDialog(
        title: '修改签名',
        initial: profile.signature ?? '',
        minCodePoints: 0,
        maxCodePoints: signatureMaxCodePoints,
        allowEmpty: true,
        helperText: '最多 49 个字符，留空即清空签名',
      ),
    );
    if (value == null) {
      return;
    }
    final String? normalized = value.trim().isEmpty ? null : value;
    if (normalized == profile.signature) {
      return;
    }
    await _save(
      ProfilePatch(setSignature: true, signature: normalized),
      successMessage: '签名已更新',
    );
  }

  Future<void> _save(
    ProfilePatch patch, {
    required String successMessage,
  }) async {
    setState(() => _busy = true);
    try {
      final Profile profile = await widget.gateway.saveProfile(patch);
      if (!mounted) {
        return;
      }
      setState(() {
        _profile = profile;
        _changed = true;
        _busy = false;
      });
      _showSnack(successMessage);
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack('保存失败，请稍后重试');
    }
  }

  Future<void> _changeAvatar() async {
    final ({String source, String value})? source =
        await showDialog<({String source, String value})>(
          context: context,
          builder: (BuildContext context) => const _AvatarSourceDialog(),
        );
    if (source == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final AvatarInfo info;
      switch (source.source) {
        case 'path':
          info = await widget.gateway.updateAvatarFromPath(source.value);
        case 'url':
          info = await widget.gateway.updateAvatarFromUrl(source.value);
        default:
          info = await widget.gateway.updateAvatarFromBase64(source.value);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _changed = true;
        if (_profile != null) {
          _profile = Profile(
            account: _profile!.account,
            username: _profile!.username,
            signature: _profile!.signature,
            avatarUrl: info.avatarUrl,
            avatarVersion: info.avatarVersion,
          );
        }
      });
      // Fetch the server's re-encoded PNG instead of showing the upload bytes.
      await _reloadAvatar();
      _showSnack('头像已更新');
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack('头像更新失败，请稍后重试');
    }
  }

  Future<void> _removeAvatar() async {
    setState(() => _busy = true);
    try {
      await widget.gateway.removeAvatar();
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _changed = true;
      });
      await _reloadAvatar();
      _showSnack('已恢复默认头像');
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(_failureMessage(failure));
    }
  }

  Future<void> _viewOtherAccount() async {
    final String? account = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _AccountLookupDialog(),
    );
    if (account == null || !mounted) {
      return;
    }
    try {
      final Profile profile = await widget.gateway.loadProfile(
        account: account,
      );
      final AvatarImage image = await widget.gateway.loadAvatar(
        account: account,
      );
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _OtherProfileDialog(profile: profile, avatar: image.bytes),
      );
    } on AuthFailure catch (failure) {
      _showSnack(_failureMessage(failure));
    }
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      final LogoutResult result = await widget.onLogout();
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pop(ProfilePanelResult(changed: true, signedOut: true, logout: result));
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      _showSnack(failure.message);
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _failureMessage(AuthFailure failure) {
    if (failure.fields.isNotEmpty) {
      return failure.fields.first.message;
    }
    return failure.message;
  }

  void _close() {
    Navigator.of(context).pop(ProfilePanelResult(changed: _changed));
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Profile? profile = _profile;
    final String nickname = profile?.username ?? widget.user.username;
    final String account = profile?.account ?? widget.user.account;

    final Widget scrollable = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        _isWide ? AppSpacing.xl : AppSpacing.lg,
        AppSpacing.sm,
        _isWide ? AppSpacing.xl : AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: ProfileAvatar(
              key: ProfilePanel.avatarButtonKey,
              bytes: _avatar,
              size: _isWide ? 112 : 96,
              loading: _loading && _avatar == null,
              onTap: _busy ? null : _changeAvatar,
              semanticLabel: '更换头像',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            children: <Widget>[
              TextButton(
                onPressed: _busy ? null : _changeAvatar,
                child: const Text('更换头像'),
              ),
              TextButton(
                key: ProfilePanel.removeAvatarKey,
                onPressed: _busy ? null : _removeAvatar,
                child: const Text('移除'),
              ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _error!,
              key: ProfilePanel.errorKey,
              style: text.bodySmall?.copyWith(color: AppColors.danger),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _InfoRow(
            label: '昵称',
            value: nickname,
            valueKey: ProfilePanel.nicknameValueKey,
            onEdit: _busy ? null : _editNickname,
            editKey: ProfilePanel.editNicknameKey,
          ),
          const Divider(height: AppSpacing.xl, color: AppColors.border),
          _InfoRow(
            label: '账号',
            value: account,
            valueKey: ProfilePanel.accountValueKey,
            monospace: true,
            trailing: Text(
              '只读',
              style: text.labelSmall?.copyWith(
                color: AppColors.inkMuted,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const Divider(height: AppSpacing.xl, color: AppColors.border),
          _InfoRow(
            label: '签名',
            value: (profile?.signature?.isNotEmpty ?? false)
                ? profile!.signature!
                : '还没有签名',
            valueKey: ProfilePanel.signatureValueKey,
            muted: !(profile?.signature?.isNotEmpty ?? false),
            onEdit: _busy ? null : _editSignature,
            editKey: ProfilePanel.editSignatureKey,
          ),
          const SizedBox(height: AppSpacing.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ProfilePanel.otherProfileKey,
              onPressed: _busy ? null : _viewOtherAccount,
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('查看其他账号资料'),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            key: ProfilePanel.logoutButtonKey,
            onPressed: _busy ? null : _logout,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.danger,
              side: const BorderSide(color: AppColors.dangerBorder),
            ),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('退出登录'),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '退出登录会删除服务端该会话，并清除本机凭据。',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );

    return Column(
      key: ProfilePanel.panelKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: _isWide ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                key: ProfilePanel.closeButtonKey,
                onPressed: _close,
                tooltip: widget.mode == ProfilePanelMode.desktop ? '关闭' : '返回',
                icon: Icon(
                  widget.mode == ProfilePanelMode.desktop
                      ? Icons.close_rounded
                      : Icons.arrow_back_rounded,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  '个人资料',
                  style: text.titleMedium?.copyWith(
                    fontSize: _isWide ? 17 : 18,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.sm),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_isWide)
          Flexible(child: scrollable)
        else
          Expanded(child: scrollable),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.valueKey,
    this.onEdit,
    this.editKey,
    this.monospace = false,
    this.muted = false,
    this.trailing,
  });

  final String label;
  final String value;
  final Key valueKey;
  final VoidCallback? onEdit;
  final Key? editKey;
  final bool monospace;
  final bool muted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(label, style: text.bodySmall),
          ),
        ),
        Expanded(
          child: Text(
            value,
            key: valueKey,
            style: text.bodyMedium?.copyWith(
              fontSize: 15,
              height: 1.45,
              color: muted ? AppColors.inkMuted : AppColors.ink,
              fontStyle: muted ? FontStyle.italic : null,
              letterSpacing: monospace ? 1.2 : null,
            ),
          ),
        ),
        ?trailing,
        if (onEdit != null)
          IconButton(
            key: editKey,
            onPressed: onEdit,
            tooltip: '编辑$label',
            icon: const Icon(Icons.edit_outlined, size: 18),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _TextEditDialog extends StatefulWidget {
  const _TextEditDialog({
    required this.title,
    required this.initial,
    required this.minCodePoints,
    required this.maxCodePoints,
    required this.helperText,
    this.allowEmpty = false,
  });

  final String title;
  final String initial;
  final int minCodePoints;
  final int maxCodePoints;
  final String helperText;
  final bool allowEmpty;

  static const Key fieldKey = Key('profile-edit-field');
  static const Key saveKey = Key('profile-edit-save');

  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _length => codePointLength(_controller.text.trim());

  bool get _valid =>
      _length >= widget.minCodePoints &&
      _length <= widget.maxCodePoints &&
      (widget.allowEmpty || _length > 0);

  void _submit() {
    if (!_valid) {
      setState(() {
        _error = _length > widget.maxCodePoints
            ? '最多 ${widget.maxCodePoints} 个字符'
            : '至少 ${widget.minCodePoints} 个字符';
      });
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text(widget.title, style: text.titleMedium),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: _TextEditDialog.fieldKey,
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(
              hintText: widget.helperText,
              counterText:
                  '${codePointLength(_controller.text)}/${widget.maxCodePoints}',
              errorText: _error,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(widget.helperText, style: text.bodySmall),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: _TextEditDialog.saveKey,
          onPressed: _valid ? _submit : null,
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

enum _AvatarSourceKind { path, url, base64 }

class _AvatarSourceDialog extends StatefulWidget {
  const _AvatarSourceDialog();

  static const Key fieldKey = Key('avatar-source-field');
  static const Key applyKey = Key('avatar-source-apply');

  @override
  State<_AvatarSourceDialog> createState() => _AvatarSourceDialogState();
}

class _AvatarSourceDialogState extends State<_AvatarSourceDialog> {
  _AvatarSourceKind _kind = _AvatarSourceKind.path;
  final TextEditingController _controller = TextEditingController();
  String? _error;

  static const Map<_AvatarSourceKind, String> _labels =
      <_AvatarSourceKind, String>{
        _AvatarSourceKind.path: '本机路径',
        _AvatarSourceKind.url: '图片链接',
        _AvatarSourceKind.base64: 'Base64',
      };

  static const Map<_AvatarSourceKind, String> _hints =
      <_AvatarSourceKind, String>{
        _AvatarSourceKind.path: '例如 /home/me/avatar.png（绝对路径，仅客户端读取）',
        _AvatarSourceKind.url: 'https://…（客户端下载，只接受 PNG/JPEG/WebP，≤5MB）',
        _AvatarSourceKind.base64: '原始 base64 或 data:image/png;base64,…',
      };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    final String value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '请填写内容');
      return;
    }
    Navigator.of(context).pop((source: _kind.name, value: value));
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text('更换头像', style: text.titleMedium),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SegmentedButton<_AvatarSourceKind>(
              segments: _AvatarSourceKind.values
                  .map(
                    (_AvatarSourceKind kind) =>
                        ButtonSegment<_AvatarSourceKind>(
                          value: kind,
                          label: Text(_labels[kind]!),
                        ),
                  )
                  .toList(growable: false),
              selected: <_AvatarSourceKind>{_kind},
              showSelectedIcon: false,
              onSelectionChanged: (Set<_AvatarSourceKind> selection) {
                setState(() {
                  _kind = selection.first;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: _AvatarSourceDialog.fieldKey,
              controller: _controller,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: _hints[_kind],
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(_hints[_kind]!, style: text.bodySmall),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: _AvatarSourceDialog.applyKey,
          onPressed: _apply,
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _AccountLookupDialog extends StatefulWidget {
  const _AccountLookupDialog();

  static const Key fieldKey = Key('account-lookup-field');
  static const Key submitKey = Key('account-lookup-submit');

  @override
  State<_AccountLookupDialog> createState() => _AccountLookupDialogState();
}

class _AccountLookupDialogState extends State<_AccountLookupDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    if (!RegExp(r'^[0-9]{8}$').hasMatch(value)) {
      setState(() => _error = '请输入 8 位数字账号');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('查看其他账号'),
      content: TextField(
        key: _AccountLookupDialog.fieldKey,
        controller: _controller,
        keyboardType: TextInputType.number,
        maxLength: 8,
        decoration: InputDecoration(hintText: '8 位账号', errorText: _error),
        onChanged: (_) => setState(() => _error = null),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: _AccountLookupDialog.submitKey,
          onPressed: _submit,
          style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
          child: const Text('查看'),
        ),
      ],
    );
  }
}

class _OtherProfileDialog extends StatelessWidget {
  const _OtherProfileDialog({required this.profile, required this.avatar});

  final Profile profile;
  final Uint8List avatar;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ProfileAvatar(bytes: avatar, size: 88, showBorder: false),
          const SizedBox(height: AppSpacing.md),
          Text(profile.username, style: text.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(profile.account, style: text.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          Text(
            profile.signature ?? '还没有签名',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
