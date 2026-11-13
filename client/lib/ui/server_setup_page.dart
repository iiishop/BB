import 'package:flutter/material.dart';

import '../app.dart';
import '../config/client_config.dart';
import 'auth_shell.dart';
import 'widgets/auth_widgets.dart';

/// First-launch (and later, from settings) server address entry.
///
/// Shown when neither a saved address nor a compiled `BB_API_BASE_URL` exists,
/// so an installed build is usable without rebuilding it for every host.
class ServerSetupPage extends StatefulWidget {
  const ServerSetupPage({
    super.key,
    required this.onSubmit,
    this.initialAddress,
    this.changing = false,
    this.notice,
    this.onCancel,
  });

  /// Persists the address and rebuilds the client against it. A thrown error is
  /// surfaced to the user instead of silently leaving the screen.
  final Future<void> Function(Uri address) onSubmit;

  final Uri? initialAddress;

  /// True when the user is replacing a working address rather than choosing the
  /// first one; only affects the copy.
  final bool changing;

  /// Optional explanation shown above the field (for example, why the previous
  /// server could not be reached).
  final String? notice;

  /// Present only while an address is already configured: the user can back out
  /// of replacing it.
  final VoidCallback? onCancel;

  static const Key addressFieldKey = Key('server-address');
  static const Key submitButtonKey = Key('server-submit');
  static const Key errorBannerKey = Key('server-error');
  static const Key noticeKey = Key('server-notice');
  static const Key cancelButtonKey = Key('server-cancel');

  @override
  State<ServerSetupPage> createState() => _ServerSetupPageState();
}

class _ServerSetupPageState extends State<ServerSetupPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialAddress?.toString() ?? '',
  );
  final FocusNode _focus = FocusNode();

  bool _busy = false;
  bool _submitted = false;
  String? _formError;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  static String? _validateAddress(String? value) {
    try {
      normalizeServerAddress(value ?? '');
      return null;
    } on ArgumentError catch (error) {
      return error.message as String?;
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _submitted = true;
      _formError = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final Uri address = normalizeServerAddress(_controller.text);
    setState(() => _busy = true);
    try {
      await widget.onSubmit(address);
      // The bootstrap normally replaces this screen on success; resetting keeps
      // the button usable when the caller keeps it mounted (for example a
      // no-op resubmit of the same address).
      if (mounted) {
        setState(() => _busy = false);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _formError = '保存服务器地址失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Widget form = Form(
      key: _formKey,
      autovalidateMode: _submitted
          ? AutovalidateMode.onUserInteraction
          : AutovalidateMode.disabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.notice != null) ...<Widget>[
            AuthNotice(key: ServerSetupPage.noticeKey, message: widget.notice!),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_formError != null) ...<Widget>[
            AuthErrorBanner(
              key: ServerSetupPage.errorBannerKey,
              message: _formError!,
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          AuthTextField(
            key: ServerSetupPage.addressFieldKey,
            controller: _controller,
            focusNode: _focus,
            label: '服务器地址',
            hint: 'bb.example.com 或 192.168.0.104:18980',
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_formError != null) {
                setState(() => _formError = null);
              }
            },
            onSubmitted: _submit,
            validator: _validateAddress,
            prefixIcon: const Icon(Icons.dns_outlined, size: 20),
          ),
          const SizedBox(height: AppSpacing.lg),
          AuthPrimaryButton(
            key: ServerSetupPage.submitButtonKey,
            label: widget.changing ? '保存并重新连接' : '连接',
            busy: _busy,
            onPressed: _submit,
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          Text(
            '只填域名时会自动使用 HTTPS；局域网地址保持 HTTP。'
            '${widget.changing ? '切换服务器会清除本机已保存的登录状态。' : ''}',
            style: text.bodySmall,
          ),
        ],
      ),
    );

    final Widget? cancel = widget.onCancel == null
        ? null
        : TextButton(
            key: ServerSetupPage.cancelButtonKey,
            onPressed: widget.onCancel,
            child: const Text('取消'),
          );

    return AuthShell(
      eyebrow: '连接 · 服务器',
      title: widget.changing ? '更换服务器' : '连接到服务器',
      subtitle: '填写 BB 服务端的地址，之后可以在设置里再改。',
      card: form,
      footer: cancel == null ? null : Center(child: cancel),
    );
  }
}
